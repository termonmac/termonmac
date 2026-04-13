import Foundation

#if os(macOS)

/// Handles tmux-style prefix key sequences during an attach session.
///
/// When the prefix byte is received, the handler enters "command mode" and waits
/// for the next byte to determine the action:
/// - `prefix + d` → detach
/// - `prefix + k` → kill session
/// - `prefix + prefix` → send a literal prefix byte to PTY
/// - `prefix + <other>` → silently consumed (no-op, tmux behavior)
///
/// Unlike SSH-style `~` escapes, the prefix works at **any position** in the
/// input stream — no newline prerequisite.
///
/// Usage: call `feed(_:count:)` with raw stdin bytes. It returns an `Action`
/// indicating what to do. The handler calls `writeToPTY` for all non-prefix bytes.
public struct AttachPrefixHandler {

    public enum Action {
        case none           // normal data forwarded to PTY
        case detach         // prefix + d detected
        case kill           // prefix + k detected
    }

    /// Closure that writes bytes to the PTY.
    public var writeToPTY: (UnsafePointer<UInt8>, Int) -> Void

    /// The prefix byte (default: 0x1D = Ctrl-]).
    public let prefixByte: UInt8

    private var prefixSeen: Bool

    public init(prefixByte: UInt8 = 0x1D,
         writeToPTY: @escaping (UnsafePointer<UInt8>, Int) -> Void) {
        self.prefixByte = prefixByte
        self.writeToPTY = writeToPTY
        self.prefixSeen = false
    }

    /// Feed raw stdin bytes. Returns the triggered action (if any).
    public mutating func feed(_ buf: UnsafePointer<UInt8>, count: Int) -> Action {
        var start = 0  // start of pending "normal" region to forward

        for i in 0..<count {
            let byte = buf[i]

            if prefixSeen {
                prefixSeen = false
                switch byte {
                case UInt8(ascii: "d"):
                    // prefix + d → detach. Flush any pending normal bytes first.
                    if start < i - 1 {
                        writeToPTY(buf.advanced(by: start), i - 1 - start)
                    }
                    return .detach
                case UInt8(ascii: "k"):
                    // prefix + k → kill. Flush any pending normal bytes first.
                    if start < i - 1 {
                        writeToPTY(buf.advanced(by: start), i - 1 - start)
                    }
                    return .kill
                case prefixByte:
                    // prefix + prefix → send a literal prefix byte to PTY.
                    // Flush everything before the first prefix.
                    if start < i - 1 {
                        writeToPTY(buf.advanced(by: start), i - 1 - start)
                    }
                    // The second prefix byte becomes a literal to forward.
                    start = i
                default:
                    // Unknown command — silently consumed (tmux behavior).
                    // Both the prefix and this byte are dropped.
                    start = i + 1
                }
                continue
            }

            if byte == prefixByte {
                // Flush everything before this prefix byte.
                if start < i {
                    writeToPTY(buf.advanced(by: start), i - start)
                }
                prefixSeen = true
                start = i + 1  // skip the prefix byte for now
                continue
            }
        }

        // Flush remaining normal bytes.
        if start < count {
            writeToPTY(buf.advanced(by: start), count - start)
        }
        // If prefixSeen is true, the prefix byte was the last byte in the buffer —
        // it stays pending until the next feed() call delivers the action byte.

        return .none
    }
}

#endif
