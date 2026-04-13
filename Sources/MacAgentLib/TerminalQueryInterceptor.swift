import Foundation

/// Intercepts terminal capability queries in PTY output and generates
/// immediate local responses, eliminating network round-trip latency.
///
/// Without interception, queries travel: shell → Mac PTY → relay → iOS
/// (SwiftTerm responds) → relay → Mac PTY → shell. The round-trip delay
/// causes responses to arrive after the shell's timeout, and zsh/ZLE
/// processes the stale bytes as keyboard input, producing garbage text.
///
/// By responding locally on the Mac side, queries get zero-latency
/// responses and never reach the iOS terminal emulator.
///
/// Intercepted queries (zero-latency local response):
/// - DA1:        ESC [ c  or  ESC [ 0 c
/// - DA2:        ESC [ > c  or  ESC [ > 0 c
/// - DSR 5:      ESC [ 5 n  (device status — always "OK")
/// - OSC 10/11:  ESC ] 10 ; ? ST  (foreground/background color query)
/// - DECRPM:     ESC [ ? <mode> $ p
///
/// NOT intercepted (handled by iOS-side isTerminalResponse instead):
/// - CPR (ESC [ 6 n) — requires real cursor position only SwiftTerm
///   knows; returning a fake position is worse than letting the app
///   time out and use its built-in fallback.
/// - Window ops, DCS/DECRQSS, Kitty keyboard mode reports — the iOS
///   filter catches SwiftTerm's responses and drops them.
public enum TerminalQueryInterceptor {

    public struct Result {
        public let filteredOutput: Data
        public let responses: [Data]
    }

    // MARK: - Hardcoded responses (matching xterm-256color)

    private static let da1Response = Data("\u{1B}[?65;20;1c".utf8)
    private static let da2Response = Data("\u{1B}[>65;20;1c".utf8)
    private static let dsrOkResponse = Data("\u{1B}[0n".utf8)
    private static let osc10Response = Data("\u{1B}]10;rgb:ffff/ffff/ffff\u{1B}\\".utf8)
    private static let osc11Response = Data("\u{1B}]11;rgb:0000/0000/0000\u{1B}\\".utf8)

    /// Scan PTY output for terminal queries. Returns filtered output
    /// (queries stripped) and responses to write back to the PTY.
    public static func intercept(_ data: Data) -> Result {
        let bytes = Array(data)
        guard !bytes.isEmpty else { return Result(filteredOutput: data, responses: []) }

        var output = [UInt8]()
        output.reserveCapacity(bytes.count)
        var responses = [Data]()

        var i = 0
        while i < bytes.count {
            if bytes[i] == 0x1B, i + 1 < bytes.count {
                switch bytes[i + 1] {
                case 0x5B: // CSI: ESC [
                    if let (end, resp) = matchCSIQuery(bytes, from: i + 2) {
                        responses.append(resp)
                        i = end
                        continue
                    }
                case 0x5D: // OSC: ESC ]
                    if let (end, resp) = matchOSCQuery(bytes, from: i + 2) {
                        responses.append(resp)
                        i = end
                        continue
                    }
                default:
                    break
                }
            }
            output.append(bytes[i])
            i += 1
        }

        let filtered = responses.isEmpty ? data : Data(output)
        return Result(filteredOutput: filtered, responses: responses)
    }

    // MARK: - CSI query matching

    /// Match CSI queries starting after "ESC [".
    /// Returns (index past sequence, response data), or nil.
    private static func matchCSIQuery(_ bytes: [UInt8], from start: Int) -> (Int, Data)? {
        var i = start
        guard i < bytes.count else { return nil }

        // DA1: ESC [ c  or  ESC [ 0 c
        if bytes[i] == 0x63 { // 'c' — ESC [ c
            return (i + 1, da1Response)
        }
        if bytes[i] == 0x30 && i + 1 < bytes.count && bytes[i + 1] == 0x63 { // ESC [ 0 c
            return (i + 2, da1Response)
        }

        // DA2: ESC [ > c  or  ESC [ > 0 c
        if bytes[i] == 0x3E { // '>'
            let j = i + 1
            if j < bytes.count && bytes[j] == 0x63 { // ESC [ > c
                return (j + 1, da2Response)
            }
            if j + 1 < bytes.count && bytes[j] == 0x30 && bytes[j + 1] == 0x63 { // ESC [ > 0 c
                return (j + 2, da2Response)
            }
        }

        // DSR 5: ESC [ 5 n — device status query
        // (DSR 6 / CPR is NOT intercepted here — it requires the real cursor
        //  position which only SwiftTerm knows.  The iOS-side isTerminalResponse
        //  catches SwiftTerm's CPR response and drops it; the querying app
        //  times out and uses its built-in fallback, which is safer than
        //  returning a wrong position.)
        if bytes[i] == 0x35 && i + 1 < bytes.count && bytes[i + 1] == 0x6E { // ESC [ 5 n
            return (i + 2, dsrOkResponse)
        }

        // DECRPM: ESC [ ? <digits> $ p
        if bytes[i] == 0x3F { // '?'
            i += 1
            let digitStart = i
            while i < bytes.count && bytes[i] >= 0x30 && bytes[i] <= 0x39 {
                i += 1
            }
            if i > digitStart && i + 1 < bytes.count
                && bytes[i] == 0x24 && bytes[i + 1] == 0x70 { // $ p
                let modeStr = String(bytes: bytes[digitStart..<i], encoding: .ascii) ?? "0"
                let response = Data("\u{1B}[?\(modeStr);2$y".utf8)
                return (i + 2, response)
            }
        }

        return nil
    }

    // MARK: - OSC query matching

    /// Match OSC color queries starting after "ESC ]".
    /// Returns (index past sequence, response data), or nil.
    private static func matchOSCQuery(_ bytes: [UInt8], from start: Int) -> (Int, Data)? {
        var i = start
        guard i < bytes.count else { return nil }

        // Read OSC number
        var num = 0
        let numStart = i
        while i < bytes.count && bytes[i] >= 0x30 && bytes[i] <= 0x39 {
            num = num * 10 + Int(bytes[i] - 0x30)
            i += 1
        }
        guard i > numStart else { return nil }
        guard i < bytes.count && bytes[i] == 0x3B else { return nil } // ';'
        i += 1

        // Check for query: content must be just "?"
        guard i < bytes.count && bytes[i] == 0x3F else { return nil } // '?'
        i += 1

        // Find string terminator: BEL (0x07) or ST (ESC \)
        guard i < bytes.count else { return nil }
        if bytes[i] == 0x07 {
            i += 1
        } else if bytes[i] == 0x1B && i + 1 < bytes.count && bytes[i + 1] == 0x5C {
            i += 2
        } else {
            return nil
        }

        // Generate response based on OSC number
        switch num {
        case 10: return (i, osc10Response)
        case 11: return (i, osc11Response)
        default: return nil // unknown OSC query — pass through
        }
    }
}
