import Foundation

#if os(macOS)

/// Lightweight VT cursor position tracker.
///
/// Parses PTY output bytes to maintain (row, col) state so that
/// `AttachStatusBar` can use CUP-based cursor return instead of
/// DECSC/DECRC, avoiding the single-slot conflict with PTY applications.
///
/// This is NOT a full terminal emulator — it tracks only cursor position
/// and scroll region, which is sufficient for status bar cursor return.
public final class CursorTracker {

    // Current cursor position (0-indexed)
    public private(set) var row: Int = 0
    public private(set) var col: Int = 0

    // Terminal dimensions (PTY-visible size, NOT real terminal size)
    private var cols: Int
    private var rows: Int

    // Scroll region (0-indexed, set by DECSTBM)
    private var scrollTop: Int = 0
    private var scrollBottom: Int

    // Saved cursor position (DECSC/DECRC and SCP/RCP)
    private var savedRow: Int = 0
    private var savedCol: Int = 0

    // Pending wrap state (VT100 deferred wrap / autowrap pending)
    private var pendingWrap: Bool = false
    private var savedPendingWrap: Bool = false

    // Scroll region reset detection (for AttachStatusBar correction in fd-pass mode).
    // Set when DECSTBM is processed with a defaulted or oversized bottom param,
    // which would cause the Mac terminal to reset its scroll region wider than
    // the PTY's view.
    private var _scrollRegionWasReset: Bool = false

    // UTF-8 multi-byte collection state
    private var utf8Remaining: Int = 0
    private var utf8Codepoint: UInt32 = 0

    // MARK: - VT parser state

    private enum State {
        case ground
        case escape       // after ESC
        case csi          // inside CSI sequence
        case oscString    // OSC/DCS/SOS/PM/APC — skip until BEL or ST
        case skipNext     // skip one byte (charset designation)
    }
    private var state: State = .ground
    private var csiParams: [Int] = []
    private var currentParam: Int = 0
    private var hasCurrentParam: Bool = false
    private var csiHasPrefix: Bool = false  // tracks non-standard prefix/intermediate in CSI (? > < = ! etc.)

    // MARK: - Public API

    public init(cols: Int, rows: Int) {
        self.cols = cols
        self.rows = rows
        self.scrollBottom = rows - 1
    }

    /// Update terminal dimensions (call on SIGWINCH after PTY resize).
    public func resize(cols: Int, rows: Int) {
        self.cols = cols
        self.rows = rows
        self.scrollTop = 0
        self.scrollBottom = rows - 1
        row = min(row, max(0, rows - 1))
        col = min(col, max(0, cols - 1))
        pendingWrap = false
        _scrollRegionWasReset = false
    }

    /// Process raw PTY output bytes to update cursor position.
    public func process(_ ptr: UnsafePointer<UInt8>, count: Int) {
        for i in 0..<count {
            processByte(ptr[i])
        }
    }

    /// Convenience: process Data.
    public func process(_ data: Data) {
        data.withUnsafeBytes { rawBuf in
            guard let base = rawBuf.bindMemory(to: UInt8.self).baseAddress else { return }
            process(base, count: rawBuf.count)
        }
    }

    /// Returns true if a DECSTBM was processed that would cause the Mac terminal
    /// to reset its scroll region wider than the PTY's view (defaulted or oversized
    /// bottom param). Clears the flag on read.
    public func consumeScrollRegionReset() -> Bool {
        guard _scrollRegionWasReset else { return false }
        _scrollRegionWasReset = false
        return true
    }

    // MARK: - Byte processing

    private func processByte(_ byte: UInt8) {
        switch state {
        case .ground:    processGround(byte)
        case .escape:    processEscape(byte)
        case .csi:       processCSI(byte)
        case .oscString:
            if byte == 0x07 { state = .ground }       // BEL terminates
            else if byte == 0x1B { state = .escape }   // possible ST (ESC \)
        case .skipNext:
            state = .ground
        }
    }

    private func processGround(_ byte: UInt8) {
        // Abort any in-progress UTF-8 sequence if this isn't a continuation byte
        if byte < 0x80 || byte >= 0xC0 {
            utf8Remaining = 0
        }
        switch byte {
        case 0x1B:                 state = .escape
        case 0x08:                 pendingWrap = false; col = max(0, col - 1)              // BS
        case 0x09:                 pendingWrap = false; col = min(cols - 1, (col / 8 + 1) * 8) // HT
        case 0x0A, 0x0B, 0x0C:    pendingWrap = false; linefeed()                          // LF, VT, FF
        case 0x0D:                 pendingWrap = false; col = 0                             // CR
        case 0x20...0x7E:          advanceCol()                                             // ASCII printable (width 1)
        case 0x80...0xBF:          handleUTF8Continuation(byte)                             // UTF-8 continuation
        case 0xC0...0xDF:          utf8Remaining = 1; utf8Codepoint = UInt32(byte & 0x1F)   // 2-byte lead
        case 0xE0...0xEF:          utf8Remaining = 2; utf8Codepoint = UInt32(byte & 0x0F)   // 3-byte lead
        case 0xF0...0xF7:          utf8Remaining = 3; utf8Codepoint = UInt32(byte & 0x07)   // 4-byte lead
        default:                   break                                                     // 0xF8-0xFF invalid / control
        }
    }

    private func handleUTF8Continuation(_ byte: UInt8) {
        guard utf8Remaining > 0 else { return } // orphan continuation — ignore
        utf8Codepoint = (utf8Codepoint << 6) | UInt32(byte & 0x3F)
        utf8Remaining -= 1
        if utf8Remaining == 0 {
            if Self.isWide(utf8Codepoint) {
                advanceWideCol()
            } else {
                advanceCol()
            }
        }
    }

    private func processEscape(_ byte: UInt8) {
        switch byte {
        case 0x5B: // [  → CSI
            state = .csi
            csiParams = []
            currentParam = 0
            hasCurrentParam = false
            csiHasPrefix = false
        case 0x5D, 0x50, 0x58, 0x5E, 0x5F: // ] P X ^ _  → string sequences
            state = .oscString
        case 0x44: pendingWrap = false; linefeed();                      state = .ground  // D = IND
        case 0x45: pendingWrap = false; col = 0; linefeed();             state = .ground  // E = NEL
        case 0x4D: pendingWrap = false; reverseIndex();                  state = .ground  // M = RI
        case 0x37: savedRow = row; savedCol = col; savedPendingWrap = pendingWrap;  state = .ground  // 7 = DECSC
        case 0x38: row = savedRow; col = savedCol; pendingWrap = savedPendingWrap;  state = .ground  // 8 = DECRC
        case 0x63:                                                                      // c = RIS (Full Reset)
            pendingWrap = false
            row = 0; col = 0
            scrollTop = 0; scrollBottom = rows - 1
            savedRow = 0; savedCol = 0; savedPendingWrap = false
            _scrollRegionWasReset = true
            state = .ground
        case 0x5C:                                  state = .ground  // \ = ST
        case 0x23:                                  state = .skipNext // # = line attributes (DECDHL, DECALN, etc.)
        case 0x28, 0x29, 0x2A, 0x2B:                state = .skipNext // charset designation
        default:                                    state = .ground
        }
    }

    private func processCSI(_ byte: UInt8) {
        if byte >= 0x30 && byte <= 0x39 { // digit
            hasCurrentParam = true
            currentParam = currentParam &* 10 &+ Int(byte &- 0x30)
        } else if byte == 0x3B { // ;
            csiParams.append(hasCurrentParam ? currentParam : 0)
            currentParam = 0
            hasCurrentParam = false
        } else if byte >= 0x40 && byte <= 0x7E { // final byte
            if hasCurrentParam { csiParams.append(currentParam) }
            processCSIFinal(byte)
            state = .ground
        } else if byte >= 0x20 && byte <= 0x3F {
            // intermediate bytes (0x20-0x2F: space../) and private prefix (0x3C-0x3F: < = > ?)
            // Any of these marks the sequence as non-standard → processCSIFinal must skip.
            // Without this, e.g. ESC[<u (kitty keyboard pop) is misinterpreted as ESC[u (RCP).
            csiHasPrefix = true
        } else if byte == 0x1B {
            state = .escape // ESC aborts CSI and starts new escape sequence
        } else {
            state = .ground // invalid
        }
    }

    private func processCSIFinal(_ byte: UInt8) {
        // Skip ALL non-standard CSI sequences (with intermediate or private prefix bytes).
        // Without this guard, sequences like ESC[<u (kitty keyboard pop) would be
        // misinterpreted as ESC[u (RCP), causing cursor position desync.
        if csiHasPrefix {
            processPrivateMode(byte)
            return
        }

        let p1 = csiParams.first ?? 0
        let p2 = csiParams.count > 1 ? csiParams[1] : 0

        switch byte {
        case 0x41: pendingWrap = false; row = max(0, row - max(1, p1))                            // A = CUU
        case 0x42: pendingWrap = false; row = min(rows - 1, row + max(1, p1))                     // B = CUD
        case 0x43: pendingWrap = false; col = min(cols - 1, col + max(1, p1))                     // C = CUF
        case 0x44: pendingWrap = false; col = max(0, col - max(1, p1))                            // D = CUB
        case 0x45: pendingWrap = false; col = 0; row = min(rows - 1, row + max(1, p1))            // E = CNL
        case 0x46: pendingWrap = false; col = 0; row = max(0, row - max(1, p1))                   // F = CPL
        case 0x47: pendingWrap = false; col = max(0, min(cols - 1, max(1, p1) - 1))               // G = CHA
        case 0x48, 0x66:                                                                          // H = CUP, f = HVP
            pendingWrap = false
            row = max(0, min(rows - 1, max(1, p1) - 1))
            col = max(0, min(cols - 1, max(1, p2) - 1))
        case 0x64: pendingWrap = false; row = max(0, min(rows - 1, max(1, p1) - 1))               // d = VPA
        case 0x72:                                                                                 // r = DECSTBM
            pendingWrap = false
            let top = max(1, p1)
            let bottom = p2 > 0 ? p2 : rows
            scrollTop = max(0, top - 1)
            scrollBottom = min(rows - 1, bottom - 1)
            row = 0; col = 0 // DECSTBM homes cursor
            // Detect resets that would desync with a larger Mac terminal:
            // p2==0 means defaulted (ESC[r] or ESC[Nr]) → Mac terminal uses its own rows
            // p2>rows means the explicit param exceeds PTY size → Mac terminal clamps differently
            if p2 == 0 || p2 > rows {
                _scrollRegionWasReset = true
            }
        case 0x73: // s = SCP (save cursor, only when no params)
            if csiParams.isEmpty { savedRow = row; savedCol = col; savedPendingWrap = pendingWrap }
        case 0x75: // u = RCP (restore cursor, only when no params)
            if csiParams.isEmpty { row = savedRow; col = savedCol; pendingWrap = savedPendingWrap }
        default: break
        }
    }

    // MARK: - Private mode handling

    /// Handle CSI sequences with '?' prefix (private mode set/reset).
    /// Specifically detects alternate screen entry (ESC[?1049h, ESC[?47h, ESC[?1047h])
    /// which implicitly resets the scroll region on the Mac terminal.
    private func processPrivateMode(_ byte: UInt8) {
        guard byte == 0x68 else { return } // only 'h' (SM — Set Mode) matters
        let modes = csiParams.isEmpty && !hasCurrentParam ? [] : csiParams
        for mode in modes {
            switch mode {
            case 1049, 47, 1047: // alternate screen buffer
                // Entering alternate screen resets scroll region to full terminal
                // and homes the cursor. Flag for correctScrollRegion.
                pendingWrap = false
                row = 0; col = 0
                scrollTop = 0
                scrollBottom = rows - 1
                _scrollRegionWasReset = true
            default:
                break
            }
        }
    }

    // MARK: - Cursor movement helpers

    private func advanceCol() {
        if pendingWrap {
            pendingWrap = false
            col = 0
            linefeed()
        }
        col += 1
        if col >= cols {
            col = cols - 1
            pendingWrap = true
        }
    }

    private func advanceWideCol() {
        if pendingWrap {
            pendingWrap = false
            col = 0
            linefeed()
        }
        if col + 2 > cols {
            // Wide char doesn't fit on remaining line — wrap first
            col = 0
            linefeed()
        }
        col += 2
        if col >= cols {
            col = cols - 1
            pendingWrap = true
        }
    }

    // MARK: - East Asian Width lookup

    /// Returns true for Unicode codepoints with East Asian Width W (Wide) or F (Fullwidth).
    /// Based on Unicode 15.0 EastAsianWidth.txt. Emoji blocks use broad ranges
    /// (acceptable simplification — most terminals also treat them as width 2).
    private static func isWide(_ cp: UInt32) -> Bool {
        if cp < 0x1100 { return false } // fast path: below any wide range

        // Hangul Jamo
        if cp <= 0x115F { return true }

        // Scattered Wide symbols & emoji (0x2000-0x2E7F)
        switch cp {
        case 0x231A...0x231B,           // Watch, Hourglass
             0x2329...0x232A,           // CJK Angle Brackets
             0x23E9...0x23EC,           // Media controls
             0x23F0, 0x23F3,            // Alarm clock, Hourglass flowing
             0x25FD...0x25FE,           // Medium small squares
             0x2614...0x2615,           // Umbrella, Hot beverage
             0x2630...0x2637,           // Trigrams
             0x2648...0x2653,           // Zodiac
             0x267F,                    // Wheelchair
             0x268A...0x268F,           // Yijing Monogram/Digram
             0x2693,                    // Anchor
             0x26A1,                    // High voltage
             0x26AA...0x26AB,           // Circles
             0x26BD...0x26BE,           // Sports balls
             0x26C4...0x26C5,           // Snowman, Cloud
             0x26CE,                    // Ophiuchus
             0x26D4,                    // No entry
             0x26EA,                    // Church
             0x26F2...0x26F3,           // Fountain, Flag
             0x26F5,                    // Sailboat
             0x26FA,                    // Tent
             0x26FD,                    // Fuel pump
             0x2705,                    // Check mark
             0x270A...0x270B,           // Fist, Hand
             0x2728,                    // Sparkles
             0x274C, 0x274E,            // Cross marks
             0x2753...0x2755, 0x2757,   // Question/Exclamation marks
             0x2795...0x2797,           // Heavy plus/minus/division
             0x27B0, 0x27BF,            // Curly loops
             0x2B1B...0x2B1C,           // Large squares
             0x2B50,                    // Star
             0x2B55:                    // Heavy large circle
            return true
        default:
            break
        }

        // CJK Radicals, Kangxi, Ideographic Description, CJK Symbols & Punctuation
        if cp >= 0x2E80 && cp <= 0x303E { return true }
        // Hiragana through Yi Radicals (one contiguous Wide mega-block)
        // Covers: Hiragana, Katakana, Bopomofo, Hangul Compat Jamo, Kanbun,
        // Bopomofo Extended, CJK Strokes, Katakana Ext, CJK Enclosed Letters,
        // CJK Compat, CJK Ext A, Yijing Hexagrams, CJK Unified, Yi Syllables, Yi Radicals
        if cp >= 0x3041 && cp <= 0xA4CF { return true }
        // Hangul Jamo Extended-A
        if cp >= 0xA960 && cp <= 0xA97C { return true }
        // Hangul Syllables
        if cp >= 0xAC00 && cp <= 0xD7A3 { return true }
        // CJK Compatibility Ideographs
        if cp >= 0xF900 && cp <= 0xFAFF { return true }
        // Vertical Forms
        if cp >= 0xFE10 && cp <= 0xFE19 { return true }
        // CJK Compatibility Forms + Small Form Variants
        if cp >= 0xFE30 && cp <= 0xFE6B { return true }
        // Fullwidth ASCII variants
        if cp >= 0xFF01 && cp <= 0xFF60 { return true }
        // Fullwidth signs
        if cp >= 0xFFE0 && cp <= 0xFFE6 { return true }

        // === Supplementary Planes ===

        // Tangut, Khitan, Nushu and related
        if cp >= 0x16FE0 && cp <= 0x16FE3 { return true }
        if cp >= 0x16FF2 && cp <= 0x18DF2 { return true }
        // Kana Extended + Supplement
        if cp >= 0x1AFF0 && cp <= 0x1B2FB { return true }
        // Tai Xuan Jing Symbols
        if cp >= 0x1D300 && cp <= 0x1D376 { return true }
        // Emoji (broad range from Mahjong tiles through Symbols Extended-A)
        if cp >= 0x1F004 && cp <= 0x1FAFF { return true }
        // Supplementary CJK (Planes 2-3)
        if cp >= 0x20000 && cp <= 0x3FFFD { return true }

        return false
    }

    private func linefeed() {
        if row == scrollBottom {
            // At bottom of scroll region — content scrolls, cursor stays
        } else if row < rows - 1 {
            row += 1
        }
    }

    private func reverseIndex() {
        if row == scrollTop {
            // At top of scroll region — content scrolls, cursor stays
        } else if row > 0 {
            row -= 1
        }
    }
}

#endif
