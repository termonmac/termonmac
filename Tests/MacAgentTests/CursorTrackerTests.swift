import Testing
import Foundation
@testable import MacAgentLib

// MARK: - Helpers

/// Feed a UTF-8 string into the tracker.
private func feed(_ tracker: CursorTracker, _ string: String) {
    tracker.process(Data(string.utf8))
}

/// Build a string of `n` printable characters.
private func chars(_ n: Int, char: Character = "A") -> String {
    String(repeating: char, count: n)
}

// MARK: - Basic Cursor Movement

@Suite("CursorTracker — Basic Movement")
struct CursorTrackerBasicTests {

    @Test("initial position is (0,0)")
    func initialPosition() {
        let ct = CursorTracker(cols: 80, rows: 24)
        #expect(ct.row == 0)
        #expect(ct.col == 0)
    }

    @Test("printable character advances column")
    func printableChar() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "A")
        #expect(ct.row == 0)
        #expect(ct.col == 1)
    }

    @Test("multiple printable characters advance column")
    func multipleChars() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "Hello")
        #expect(ct.row == 0)
        #expect(ct.col == 5)
    }

    @Test("CR returns column to 0")
    func carriageReturn() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "Hello\r")
        #expect(ct.row == 0)
        #expect(ct.col == 0)
    }

    @Test("LF moves to next row")
    func linefeed() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "Hello\n")
        #expect(ct.row == 1)
        #expect(ct.col == 5) // LF does not reset column
    }

    @Test("CR+LF moves to beginning of next row")
    func crLf() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "Hello\r\n")
        #expect(ct.row == 1)
        #expect(ct.col == 0)
    }

    @Test("BS moves column back by one")
    func backspace() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "ABC\u{08}")
        #expect(ct.col == 2)
    }

    @Test("BS at column 0 stays at 0")
    func backspaceAtZero() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "\u{08}")
        #expect(ct.col == 0)
    }

    @Test("HT tab advances to next 8-column stop")
    func horizontalTab() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "AB\t") // col 2 → tab stop at 8
        #expect(ct.col == 8)
    }

    @Test("HT from col 0 advances to col 8")
    func tabFromZero() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "\t")
        #expect(ct.col == 8)
    }

    @Test("HT does not exceed cols-1")
    func tabClamp() {
        let ct = CursorTracker(cols: 10, rows: 24)
        feed(ct, "\t\t") // 0→8→9 (clamped)
        #expect(ct.col == 9)
    }

    @Test("VT and FF behave like LF")
    func vtAndFf() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "A\u{0B}") // VT
        #expect(ct.row == 1)
        #expect(ct.col == 1)

        let ct2 = CursorTracker(cols: 80, rows: 24)
        feed(ct2, "A\u{0C}") // FF
        #expect(ct2.row == 1)
        #expect(ct2.col == 1)
    }
}

// MARK: - Pending Wrap (Deferred Wrap) — Regression for 9f156f4

@Suite("CursorTracker — Pending Wrap (deferred wrap)")
struct CursorTrackerPendingWrapTests {

    @Test("filling exact line width: cursor stays at last column with pending wrap")
    func fillLineExact() {
        let ct = CursorTracker(cols: 5, rows: 24)
        feed(ct, "ABCDE") // 5 chars in 5-col terminal
        // Cursor should be at col 4 (last column) with pending wrap,
        // NOT wrapped to next line yet
        #expect(ct.row == 0)
        #expect(ct.col == 4)
    }

    @Test("pending wrap triggers on next printable character")
    func pendingWrapTrigger() {
        let ct = CursorTracker(cols: 5, rows: 24)
        feed(ct, "ABCDE") // fills line, pending wrap
        feed(ct, "F")      // this triggers the wrap THEN prints F
        #expect(ct.row == 1)
        #expect(ct.col == 1)
    }

    @Test("CR cancels pending wrap — stays on same row")
    func crCancelsPendingWrap() {
        // This is the exact zsh PROMPT_SP scenario from commit 9f156f4:
        // zsh fills line to terminal width then sends CR.
        // CR should cancel the pending wrap, NOT move to next row.
        let ct = CursorTracker(cols: 5, rows: 24)
        feed(ct, "ABCDE") // fills line, pending wrap
        feed(ct, "\r")     // CR should cancel pending wrap, col=0, same row
        #expect(ct.row == 0)
        #expect(ct.col == 0)
    }

    @Test("zsh PROMPT_SP scenario: fill line + CR + LF")
    func zshPromptSP() {
        // Real zsh PROMPT_SP behavior:
        // 1. Fill entire line with spaces (to terminal width)
        // 2. Send CR (return to col 0, same row)
        // 3. Send LF (move to next row)
        // Result: cursor at (1, 0) — NOT (2, 0)
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, chars(80, char: " ")) // fill 80 cols
        feed(ct, "\r")                  // CR cancels pending wrap
        feed(ct, "\n")                  // LF moves down
        #expect(ct.row == 1)
        #expect(ct.col == 0)
    }

    @Test("without pending wrap fix: fill + CR would cause off-by-one row")
    func pendingWrapRegression() {
        // This test documents the exact bug that 9f156f4 fixed.
        // OLD behavior (broken): filling cols causes immediate wrap → row 1.
        //   Then CR → (1, 0). Then LF → (2, 0). Off by one row!
        // NEW behavior (correct): filling cols → pending wrap → row 0.
        //   Then CR cancels pending → (0, 0). Then LF → (1, 0).
        let ct = CursorTracker(cols: 10, rows: 24)
        feed(ct, chars(10))  // fill 10-col line
        #expect(ct.row == 0, "Should NOT wrap yet — pending wrap")
        feed(ct, "\r")
        #expect(ct.row == 0, "CR should cancel pending wrap, stay on row 0")
        #expect(ct.col == 0)
    }

    @Test("BS cancels pending wrap")
    func bsCancelsPendingWrap() {
        let ct = CursorTracker(cols: 5, rows: 24)
        feed(ct, "ABCDE") // pending wrap at col 4
        feed(ct, "\u{08}") // BS cancels pending wrap, col 3
        #expect(ct.row == 0)
        #expect(ct.col == 3)
    }

    @Test("LF cancels pending wrap")
    func lfCancelsPendingWrap() {
        let ct = CursorTracker(cols: 5, rows: 24)
        feed(ct, "ABCDE") // pending wrap
        feed(ct, "\n")     // LF cancels pending wrap, moves down
        #expect(ct.row == 1)
        #expect(ct.col == 4) // col unchanged by LF
    }

    @Test("two consecutive full-line fills wrap correctly")
    func twoFullLines() {
        let ct = CursorTracker(cols: 3, rows: 24)
        feed(ct, "ABC") // row 0, col 2, pendingWrap
        feed(ct, "DEF")
        // Trace in 3-col terminal:
        //   A→(0,1) B→(0,2) C→col 3>=3→(0,2)+pendingWrap
        //   D: wrap fires→(1,0), advance→(1,1)
        //   E: advance→(1,2)
        //   F: col 3>=3→(1,2)+pendingWrap
        #expect(ct.row == 1)
        #expect(ct.col == 2)
        // Next char triggers second wrap
        feed(ct, "G")
        #expect(ct.row == 2)
        #expect(ct.col == 1)
    }
}

// MARK: - CSI Cursor Movement

@Suite("CursorTracker — CSI Sequences")
struct CursorTrackerCSITests {

    @Test("CUP (ESC[H) moves cursor to position")
    func cup() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "\u{1B}[5;10H") // row 5, col 10 (1-indexed)
        #expect(ct.row == 4)  // 0-indexed
        #expect(ct.col == 9)
    }

    @Test("CUP with no params homes cursor to (0,0)")
    func cupHome() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "Hello")
        feed(ct, "\u{1B}[H") // home
        #expect(ct.row == 0)
        #expect(ct.col == 0)
    }

    @Test("CUU (ESC[A) moves cursor up")
    func cuu() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "\u{1B}[10;1H") // row 10
        feed(ct, "\u{1B}[3A")    // up 3
        #expect(ct.row == 6)
    }

    @Test("CUU at row 0 clamps to 0")
    func cuuClamp() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "\u{1B}[100A")
        #expect(ct.row == 0)
    }

    @Test("CUD (ESC[B) moves cursor down")
    func cud() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "\u{1B}[3B")
        #expect(ct.row == 3)
    }

    @Test("CUD clamps to rows-1")
    func cudClamp() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "\u{1B}[100B")
        #expect(ct.row == 23)
    }

    @Test("CUF (ESC[C) moves cursor right")
    func cuf() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "\u{1B}[5C")
        #expect(ct.col == 5)
    }

    @Test("CUF clamps to cols-1")
    func cufClamp() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "\u{1B}[200C")
        #expect(ct.col == 79)
    }

    @Test("CUB (ESC[D) moves cursor left")
    func cub() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "Hello") // col 5
        feed(ct, "\u{1B}[2D") // left 2
        #expect(ct.col == 3)
    }

    @Test("CUB clamps to 0")
    func cubClamp() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "Hi")
        feed(ct, "\u{1B}[100D")
        #expect(ct.col == 0)
    }

    @Test("CNL (ESC[E) moves to beginning of next line")
    func cnl() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "Hello")
        feed(ct, "\u{1B}[2E")
        #expect(ct.row == 2)
        #expect(ct.col == 0)
    }

    @Test("CPL (ESC[F) moves to beginning of previous line")
    func cpl() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "\u{1B}[10;5H") // row 9, col 4
        feed(ct, "\u{1B}[3F")
        #expect(ct.row == 6)
        #expect(ct.col == 0)
    }

    @Test("CHA (ESC[G) sets column")
    func cha() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "\u{1B}[20G") // col 20 (1-indexed)
        #expect(ct.col == 19)
    }

    @Test("VPA (ESC[d) sets row")
    func vpa() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "\u{1B}[10d") // row 10 (1-indexed)
        #expect(ct.row == 9)
    }

    @Test("HVP (ESC[f) works like CUP")
    func hvp() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "\u{1B}[5;10f") // same as CUP
        #expect(ct.row == 4)
        #expect(ct.col == 9)
    }

    @Test("CSI with default params (no params = 1)")
    func csiDefaults() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "\u{1B}[5;1H") // row 5
        feed(ct, "\u{1B}[A")    // up 1 (default)
        #expect(ct.row == 3)
        feed(ct, "\u{1B}[B")    // down 1
        #expect(ct.row == 4)
    }

    @Test("CUP clamps to terminal bounds")
    func cupClamp() {
        let ct = CursorTracker(cols: 10, rows: 5)
        feed(ct, "\u{1B}[100;100H")
        #expect(ct.row == 4)
        #expect(ct.col == 9)
    }

    @Test("CSI sequences cancel pending wrap")
    func csiCancelsPendingWrap() {
        let ct = CursorTracker(cols: 5, rows: 24)
        feed(ct, "ABCDE") // pending wrap
        feed(ct, "\u{1B}[A") // CUU should cancel pending wrap
        #expect(ct.row == 0) // would be -1 if wrap had fired, clamped to 0
        #expect(ct.col == 4)
    }
}

// MARK: - Save/Restore Cursor

@Suite("CursorTracker — Save/Restore Cursor")
struct CursorTrackerSaveRestoreTests {

    @Test("DECSC/DECRC saves and restores cursor (ESC 7 / ESC 8)")
    func decscDecrc() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "\u{1B}[5;10H") // row 4, col 9
        feed(ct, "\u{1B}7")       // DECSC — save
        feed(ct, "\u{1B}[1;1H")   // move to home
        #expect(ct.row == 0)
        feed(ct, "\u{1B}8")       // DECRC — restore
        #expect(ct.row == 4)
        #expect(ct.col == 9)
    }

    @Test("SCP/RCP saves and restores cursor (ESC[s / ESC[u)")
    func scpRcp() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "\u{1B}[5;10H") // row 4, col 9
        feed(ct, "\u{1B}[s")      // SCP — save
        feed(ct, "\u{1B}[1;1H")   // move to home
        feed(ct, "\u{1B}[u")      // RCP — restore
        #expect(ct.row == 4)
        #expect(ct.col == 9)
    }

    @Test("DECSC saves pending wrap state")
    func decscSavesPendingWrap() {
        let ct = CursorTracker(cols: 5, rows: 24)
        feed(ct, "ABCDE") // pending wrap at (0, 4)
        feed(ct, "\u{1B}7")  // save (including pendingWrap)
        feed(ct, "\r")        // CR cancels pending wrap
        #expect(ct.col == 0)
        feed(ct, "\u{1B}8")  // restore — pendingWrap should be restored
        #expect(ct.row == 0)
        #expect(ct.col == 4)
        // Now the next printable should trigger wrap
        feed(ct, "X")
        #expect(ct.row == 1)
        #expect(ct.col == 1)
    }

    @Test("SCP with params is ignored (DECSLRM)")
    func scpWithParams() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "\u{1B}[5;10H") // row 4, col 9
        feed(ct, "\u{1B}[10s")    // CSI with param → NOT SCP, ignored
        feed(ct, "\u{1B}[1;1H")   // move to home
        feed(ct, "\u{1B}[u")      // RCP restores initial saved (0,0)
        #expect(ct.row == 0)
        #expect(ct.col == 0)
    }
}

// MARK: - Escape Sequences (non-CSI)

@Suite("CursorTracker — Escape Sequences")
struct CursorTrackerEscapeTests {

    @Test("IND (ESC D) does linefeed")
    func ind() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "\u{1B}D")
        #expect(ct.row == 1)
    }

    @Test("NEL (ESC E) does CR + linefeed")
    func nel() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "Hello\u{1B}E")
        #expect(ct.row == 1)
        #expect(ct.col == 0)
    }

    @Test("RI (ESC M) does reverse index")
    func ri() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "\u{1B}[5;1H") // row 4
        feed(ct, "\u{1B}M")      // reverse index
        #expect(ct.row == 3)
    }

    @Test("RI at row 0 stays at 0 (scroll region top)")
    func riAtTop() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "\u{1B}M")
        #expect(ct.row == 0)
    }
}

// MARK: - Scroll Region (DECSTBM)

@Suite("CursorTracker — Scroll Region")
struct CursorTrackerScrollTests {

    @Test("DECSTBM (ESC[r) sets scroll region and homes cursor")
    func decstbm() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "Hello") // col 5
        feed(ct, "\u{1B}[5;20r") // scroll region rows 5-20
        // DECSTBM homes cursor
        #expect(ct.row == 0)
        #expect(ct.col == 0)
    }

    @Test("linefeed at scroll bottom stays on same row")
    func lfAtScrollBottom() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "\u{1B}[1;5r") // scroll region rows 1-5 (0-indexed: 0-4)
        feed(ct, "\u{1B}[5;1H") // move to row 5 (0-indexed: 4 = scrollBottom)
        let rowBefore = ct.row
        feed(ct, "\n") // LF at scroll bottom
        #expect(ct.row == rowBefore) // stays, content scrolls
    }

    @Test("RI at scroll top stays on same row")
    func riAtScrollTop() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "\u{1B}[5;20r") // scroll region 5-20
        feed(ct, "\u{1B}[5;1H")  // row 5 (0-indexed: 4 = scrollTop)
        feed(ct, "\u{1B}M")       // reverse index
        #expect(ct.row == 4) // stays at scroll top
    }

    @Test("linefeed inside scroll region moves down")
    func lfInsideRegion() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "\u{1B}[5;20r") // scroll region
        feed(ct, "\u{1B}[6;1H")  // row 6 (0-indexed: 5, inside region)
        feed(ct, "\n")
        #expect(ct.row == 6) // moved down
    }

    @Test("DECSTBM with no params resets to full screen")
    func decstbmReset() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "\u{1B}[5;10r") // set region
        feed(ct, "\u{1B}[r")      // reset (no params)
        // Now linefeed at row 23 should stay (full screen scroll)
        feed(ct, "\u{1B}[24;1H") // row 24 (0-indexed: 23)
        feed(ct, "\n")
        #expect(ct.row == 23) // stays at bottom (scroll region is full screen)
    }
}

// MARK: - OSC/DCS Passthrough

@Suite("CursorTracker — Passthrough sequences")
struct CursorTrackerPassthroughTests {

    @Test("OSC sequence does not affect cursor position")
    func oscPassthrough() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "AB")
        feed(ct, "\u{1B}]0;window title\u{07}") // OSC set title, BEL terminated
        #expect(ct.row == 0)
        #expect(ct.col == 2) // unchanged
    }

    @Test("OSC with ST terminator does not affect cursor")
    func oscST() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "AB")
        feed(ct, "\u{1B}]0;title\u{1B}\\") // ST = ESC backslash
        #expect(ct.col == 2)
    }

    @Test("DCS sequence does not affect cursor")
    func dcsPassthrough() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "AB")
        feed(ct, "\u{1B}Psomething\u{1B}\\") // DCS ... ST
        #expect(ct.col == 2)
    }

    @Test("SGR color codes do not affect cursor")
    func sgrPassthrough() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "\u{1B}[31m")  // red
        feed(ct, "Hi")
        feed(ct, "\u{1B}[0m")   // reset
        #expect(ct.col == 2)
    }

    @Test("charset designation (ESC ( B) skips one byte, no cursor effect")
    func charsetDesignation() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "AB")
        feed(ct, "\u{1B}(B") // G0 charset = ASCII
        #expect(ct.col == 2)
    }
}

// MARK: - UTF-8 & Wide Character Width

@Suite("CursorTracker — UTF-8 & Character Width")
struct CursorTrackerUTF8Tests {

    // -- Narrow characters (width 1) --

    @Test("2-byte UTF-8 narrow char (é) advances 1 col")
    func utf8Narrow2Byte() {
        let ct = CursorTracker(cols: 80, rows: 24)
        // "é" = 0xC3 0xA9 → U+00E9 (narrow)
        ct.process(Data([0xC3, 0xA9]))
        #expect(ct.col == 1)
    }

    @Test("3-byte UTF-8 narrow char (Thai) advances 1 col")
    func utf8Narrow3Byte() {
        let ct = CursorTracker(cols: 80, rows: 24)
        // "ก" = 0xE0 0xB8 0x81 → U+0E01 (Thai, narrow)
        ct.process(Data([0xE0, 0xB8, 0x81]))
        #expect(ct.col == 1)
    }

    // -- Wide characters (width 2) --

    @Test("CJK character (中) advances 2 cols")
    func cjkWide() {
        let ct = CursorTracker(cols: 80, rows: 24)
        // "中" = 0xE4 0xB8 0xAD → U+4E2D (CJK Unified, wide)
        ct.process(Data([0xE4, 0xB8, 0xAD]))
        #expect(ct.col == 2)
    }

    @Test("Hiragana (あ) advances 2 cols")
    func hiraganaWide() {
        let ct = CursorTracker(cols: 80, rows: 24)
        // "あ" = 0xE3 0x81 0x82 → U+3042 (Hiragana, wide)
        ct.process(Data([0xE3, 0x81, 0x82]))
        #expect(ct.col == 2)
    }

    @Test("Hangul syllable (한) advances 2 cols")
    func hangulWide() {
        let ct = CursorTracker(cols: 80, rows: 24)
        // "한" = 0xED 0x95 0x9C → U+D55C (Hangul Syllables, wide)
        ct.process(Data([0xED, 0x95, 0x9C]))
        #expect(ct.col == 2)
    }

    @Test("Fullwidth ASCII (Ａ) advances 2 cols")
    func fullwidthAscii() {
        let ct = CursorTracker(cols: 80, rows: 24)
        // "Ａ" = 0xEF 0xBC 0xA1 → U+FF21 (Fullwidth Latin A, wide)
        ct.process(Data([0xEF, 0xBC, 0xA1]))
        #expect(ct.col == 2)
    }

    @Test("emoji (😀) advances 2 cols")
    func emojiWide() {
        let ct = CursorTracker(cols: 80, rows: 24)
        // "😀" = 0xF0 0x9F 0x98 0x80 → U+1F600 (emoji, wide)
        ct.process(Data([0xF0, 0x9F, 0x98, 0x80]))
        #expect(ct.col == 2)
    }

    @Test("CJK Extension B (𠀀) advances 2 cols")
    func cjkExtensionB() {
        let ct = CursorTracker(cols: 80, rows: 24)
        // "𠀀" = 0xF0 0xA0 0x80 0x80 → U+20000 (Supplementary CJK, wide)
        ct.process(Data([0xF0, 0xA0, 0x80, 0x80]))
        #expect(ct.col == 2)
    }

    // -- Mixed narrow + wide --

    @Test("mixed ASCII and CJK: 'Hi中文ok'")
    func mixedWidth() {
        let ct = CursorTracker(cols: 80, rows: 24)
        // "Hi" = 2 cols, "中" = 2 cols, "文" = 2 cols, "ok" = 2 cols → total 8
        let hi = Data("Hi".utf8)
        let zhong = Data([0xE4, 0xB8, 0xAD]) // 中
        let wen = Data([0xE6, 0x96, 0x87])   // 文
        let ok = Data("ok".utf8)
        ct.process(hi + zhong + wen + ok)
        #expect(ct.col == 8)
    }

    // -- Wide char line boundary --

    @Test("wide char at second-to-last column: fits, sets pendingWrap")
    func wideCharFitsAtEnd() {
        let ct = CursorTracker(cols: 10, rows: 24)
        feed(ct, chars(8)) // col=8
        ct.process(Data([0xE4, 0xB8, 0xAD])) // 中 (wide) at col 8 → col 9, pendingWrap
        #expect(ct.row == 0)
        #expect(ct.col == 9)
    }

    @Test("wide char at last column: doesn't fit, wraps to next line")
    func wideCharWrapsAtEnd() {
        let ct = CursorTracker(cols: 10, rows: 24)
        feed(ct, chars(9)) // col=9 (last column)
        ct.process(Data([0xE4, 0xB8, 0xAD])) // 中 (wide) — only 1 cell left, wrap
        #expect(ct.row == 1)
        #expect(ct.col == 2)
    }

    @Test("wide char with pendingWrap: fires wrap then prints")
    func wideCharWithPendingWrap() {
        let ct = CursorTracker(cols: 10, rows: 24)
        feed(ct, chars(10)) // pendingWrap at col 9
        ct.process(Data([0xE4, 0xB8, 0xAD])) // 中 — wrap fires, then wide at next line
        #expect(ct.row == 1)
        #expect(ct.col == 2)
    }

    @Test("consecutive wide chars fill and wrap correctly")
    func consecutiveWideChars() {
        let ct = CursorTracker(cols: 6, rows: 24)
        // 3 wide chars = 6 cols → fills line exactly, pendingWrap
        ct.process(Data([0xE4, 0xB8, 0xAD])) // 中 → col 2
        ct.process(Data([0xE6, 0x96, 0x87])) // 文 → col 4
        ct.process(Data([0xE5, 0xAD, 0x97])) // 字 → col 5, pendingWrap
        #expect(ct.row == 0)
        #expect(ct.col == 5)
        // 4th wide char triggers wrap
        ct.process(Data([0xE4, 0xB8, 0xAD])) // 中 → wrap, next line col 2
        #expect(ct.row == 1)
        #expect(ct.col == 2)
    }

    // -- UTF-8 edge cases --

    @Test("interrupted UTF-8: lead + partial then ESC")
    func interruptedUTF8() {
        let ct = CursorTracker(cols: 80, rows: 24)
        // E4 B8 (incomplete 中) then ESC[5;10H
        ct.process(Data([0xE4, 0xB8])) // 2 of 3 bytes, no col advance yet
        #expect(ct.col == 0)
        feed(ct, "\u{1B}[5;10H") // ESC resets utf8, CUP takes effect
        #expect(ct.row == 4)
        #expect(ct.col == 9)
    }

    @Test("orphan continuation bytes still ignored")
    func orphanContinuation() {
        let ct = CursorTracker(cols: 80, rows: 24)
        ct.process(Data([0x80, 0x90, 0xA0, 0xBF]))
        #expect(ct.col == 0)
    }

    @Test("lead byte followed by another lead byte: first sequence abandoned")
    func leadFollowedByLead() {
        let ct = CursorTracker(cols: 80, rows: 24)
        // E4 (3-byte lead for 中) then C3 A9 (é, 2-byte) — first abandoned
        ct.process(Data([0xE4, 0xC3, 0xA9]))
        #expect(ct.col == 1) // only é was completed (narrow)
    }

    @Test("ASCII after incomplete UTF-8 resets collection")
    func asciiAfterIncompleteUTF8() {
        let ct = CursorTracker(cols: 80, rows: 24)
        ct.process(Data([0xE4, 0xB8])) // incomplete 中
        #expect(ct.col == 0) // no advance yet
        feed(ct, "AB")
        #expect(ct.col == 2) // A + B, incomplete sequence dropped
    }

    @Test("wide char in 2-col terminal")
    func wideCharIn2ColTerminal() {
        let ct = CursorTracker(cols: 2, rows: 24)
        ct.process(Data([0xE4, 0xB8, 0xAD])) // 中 — fits exactly in 2-col
        #expect(ct.row == 0)
        #expect(ct.col == 1) // col=1, pendingWrap
        ct.process(Data([0xE6, 0x96, 0x87])) // 文 — wrap, then fits on next line
        #expect(ct.row == 1)
        #expect(ct.col == 1)
    }
}

// MARK: - Resize

@Suite("CursorTracker — Resize")
struct CursorTrackerResizeTests {

    @Test("resize clamps cursor to new dimensions")
    func resizeClamps() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "\u{1B}[20;70H") // row 19, col 69
        ct.resize(cols: 40, rows: 10)
        #expect(ct.row == 9)  // clamped to rows-1
        #expect(ct.col == 39) // clamped to cols-1
    }

    @Test("resize resets scroll region")
    func resizeResetsScrollRegion() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "\u{1B}[5;10r") // set scroll region
        ct.resize(cols: 80, rows: 30)
        // After resize, scroll region should be full screen (0..29)
        // Go to last row and LF should not advance (at new bottom)
        feed(ct, "\u{1B}[30;1H")
        feed(ct, "\n")
        #expect(ct.row == 29) // stays at bottom of new full-screen region
    }

    @Test("resize clears pending wrap")
    func resizeClearsPendingWrap() {
        let ct = CursorTracker(cols: 5, rows: 24)
        feed(ct, "ABCDE") // pending wrap
        ct.resize(cols: 10, rows: 24) // resize clears pending wrap
        feed(ct, "X") // should NOT trigger wrap, just advance
        #expect(ct.row == 0)
        #expect(ct.col == 5) // was 4, then X advances to 5
    }
}

// MARK: - Real-World Scenarios

@Suite("CursorTracker — Real-World Scenarios")
struct CursorTrackerRealWorldTests {

    @Test("bash prompt: user types command and presses enter")
    func bashPrompt() {
        let ct = CursorTracker(cols: 80, rows: 24)
        // Simulate: "$ ls\r\n" + output + new prompt
        feed(ct, "$ ls\r\n")
        #expect(ct.row == 1)
        #expect(ct.col == 0)
        feed(ct, "file1  file2  file3\r\n")
        #expect(ct.row == 2)
        feed(ct, "$ ")
        #expect(ct.row == 2)
        #expect(ct.col == 2)
    }

    @Test("status bar CUP-based cursor return pattern")
    func statusBarPattern() {
        // This is the pattern AttachStatusBar uses:
        // 1. Save position with CursorTracker (read row/col)
        // 2. Draw bar at bottom row
        // 3. Return cursor with CUP using saved row/col
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "$ ")
        let savedRow = ct.row
        let savedCol = ct.col
        // Simulate drawing bar at row 24 (last line)
        feed(ct, "\u{1B}[24;1H") // move to bottom
        feed(ct, "status: connected") // draw bar
        // Return cursor
        feed(ct, "\u{1B}[\(savedRow + 1);\(savedCol + 1)H")
        #expect(ct.row == savedRow)
        #expect(ct.col == savedCol)
    }

    @Test("vim-like application: alt screen + cursor movement")
    func vimLikeCursorMovement() {
        let ct = CursorTracker(cols: 80, rows: 24)
        // Home cursor
        feed(ct, "\u{1B}[H")
        // Clear screen
        feed(ct, "\u{1B}[2J")
        // Move to line 10
        feed(ct, "\u{1B}[10;1H")
        #expect(ct.row == 9)
        #expect(ct.col == 0)
        // Type some text
        feed(ct, "Hello, World!")
        #expect(ct.col == 13)
        // Move up 3 lines
        feed(ct, "\u{1B}[3A")
        #expect(ct.row == 6)
    }

    @Test("long output filling multiple lines with wrapping")
    func longOutputWrapping() {
        let ct = CursorTracker(cols: 10, rows: 5)
        // 25 characters = 2 full wraps + 5 chars on third line
        feed(ct, chars(25))
        // Line 0: 10 chars → pending wrap
        // Char 11: wrap to line 1, print at col 1
        // Line 1: chars 11-20 → pending wrap
        // Char 21: wrap to line 2, print at col 1
        // Chars 22-25: col 2,3,4,5
        #expect(ct.row == 2)
        #expect(ct.col == 5)
    }

    @Test("mixed escape sequences and text")
    func mixedSequences() {
        let ct = CursorTracker(cols: 80, rows: 24)
        // Colored prompt: ESC[32m$ESC[0m + space + text
        feed(ct, "\u{1B}[32m$\u{1B}[0m ls")
        #expect(ct.col == 4) // "$ ls" = 4 visible chars
    }
}

// MARK: - Edge Cases

@Suite("CursorTracker — Edge Cases")
struct CursorTrackerEdgeCaseTests {

    @Test("empty data does nothing")
    func emptyData() {
        let ct = CursorTracker(cols: 80, rows: 24)
        ct.process(Data())
        #expect(ct.row == 0)
        #expect(ct.col == 0)
    }

    @Test("lone ESC does not crash")
    func loneEsc() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "\u{1B}")
        // Should be in escape state but not crashed
        #expect(ct.row == 0)
    }

    @Test("incomplete CSI does not crash")
    func incompleteCSI() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "\u{1B}[12") // incomplete CSI
        // Feed more data — the CSI should resolve
        feed(ct, ";5H")
        #expect(ct.row == 11)
        #expect(ct.col == 4)
    }

    @Test("1-column terminal")
    func oneColTerminal() {
        let ct = CursorTracker(cols: 1, rows: 24)
        feed(ct, "A") // fills single col, pending wrap
        #expect(ct.row == 0)
        #expect(ct.col == 0)
        feed(ct, "B") // triggers wrap
        #expect(ct.row == 1)
        #expect(ct.col == 0)
    }

    @Test("1-row terminal LF stays at row 0")
    func oneRowTerminal() {
        let ct = CursorTracker(cols: 80, rows: 1)
        feed(ct, "\n")
        #expect(ct.row == 0) // can't go below, content scrolls
    }

    @Test("split byte sequences across process calls")
    func splitProcessing() {
        let ct = CursorTracker(cols: 80, rows: 24)
        // Split "ESC[5;10H" across two process() calls
        feed(ct, "\u{1B}[5;")
        feed(ct, "10H")
        #expect(ct.row == 4)
        #expect(ct.col == 9)
    }

    @Test("many control chars in sequence")
    func manyControlChars() {
        let ct = CursorTracker(cols: 80, rows: 24)
        // NUL, SOH, STX, etc. should be ignored
        ct.process(Data([0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06]))
        #expect(ct.row == 0)
        #expect(ct.col == 0)
    }

    @Test("BEL (0x07) is ignored")
    func bel() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "AB\u{07}CD")
        #expect(ct.col == 4)
    }

    @Test("SO/SI and other C0 controls (0x0E-0x1F except ESC) are ignored")
    func otherC0Controls() {
        let ct = CursorTracker(cols: 80, rows: 24)
        // SO=0x0E, SI=0x0F, DLE=0x10, ... SUB=0x1A, FS=0x1C, GS=0x1D, RS=0x1E, US=0x1F
        ct.process(Data([0x0E, 0x0F, 0x10, 0x11, 0x12, 0x13, 0x14,
                         0x15, 0x16, 0x17, 0x18, 0x19, 0x1A,
                         0x1C, 0x1D, 0x1E, 0x1F]))
        #expect(ct.col == 0)
        #expect(ct.row == 0)
    }

    @Test("DEL (0x7F) is ignored")
    func del() {
        let ct = CursorTracker(cols: 80, rows: 24)
        // 0x7F is outside 0x20-0x7E so falls into default → ignored
        feed(ct, "AB")
        ct.process(Data([0x7F]))
        #expect(ct.col == 2)
    }

    @Test("UTF-8 continuation bytes (0x80-0xBF) are ignored")
    func utf8ContinuationOnly() {
        let ct = CursorTracker(cols: 80, rows: 24)
        // Orphan continuation bytes — no lead byte preceded them
        ct.process(Data([0x80, 0x90, 0xA0, 0xBF]))
        #expect(ct.col == 0) // all ignored
    }

    @Test("CSI parameter overflow uses wrapping arithmetic")
    func csiParamOverflow() {
        let ct = CursorTracker(cols: 80, rows: 24)
        // Very large param — should not crash, result is clamped
        feed(ct, "\u{1B}[99999999A")
        #expect(ct.row == 0) // clamped to 0 (can't go above)
    }

    @Test("ESC inside CSI aborts CSI and starts new escape sequence")
    func escInsideCSI() {
        let ct = CursorTracker(cols: 80, rows: 24)
        // ESC inside CSI should abort the in-progress CSI and re-enter
        // escape state, so the subsequent "[10;20H" becomes a new CUP.
        feed(ct, "\u{1B}[5") // incomplete CSI: digit 5
        feed(ct, "\u{1B}[10;20H") // ESC aborts CSI → new CSI → CUP(10,20)
        #expect(ct.row == 9)
        #expect(ct.col == 19)
    }

    @Test("0 rows / 0 cols does not crash")
    func zeroDimensions() {
        // Defensive: this shouldn't happen in practice
        let ct = CursorTracker(cols: 1, rows: 1)
        ct.resize(cols: 0, rows: 0)
        // Just verify no crash — col/row values don't matter at 0x0
        feed(ct, "A")
    }
}

// MARK: - Gap Coverage: String Sequence Passthrough

@Suite("CursorTracker — String Sequences (SOS/PM/APC)")
struct CursorTrackerStringSequenceTests {

    @Test("SOS (ESC X) does not affect cursor")
    func sosPassthrough() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "AB")
        feed(ct, "\u{1B}Xsome data\u{1B}\\") // SOS ... ST
        #expect(ct.col == 2)
    }

    @Test("PM (ESC ^) does not affect cursor")
    func pmPassthrough() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "AB")
        feed(ct, "\u{1B}^some data\u{1B}\\") // PM ... ST
        #expect(ct.col == 2)
    }

    @Test("APC (ESC _) does not affect cursor")
    func apcPassthrough() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "AB")
        feed(ct, "\u{1B}_some data\u{1B}\\") // APC ... ST
        #expect(ct.col == 2)
    }

    @Test("OSC/DCS/SOS/PM/APC all use same BEL termination")
    func stringSequenceBelTermination() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "A")
        feed(ct, "\u{1B}Xdata\u{07}") // SOS terminated by BEL
        feed(ct, "B")
        feed(ct, "\u{1B}^data\u{07}") // PM terminated by BEL
        feed(ct, "C")
        feed(ct, "\u{1B}_data\u{07}") // APC terminated by BEL
        feed(ct, "D")
        #expect(ct.col == 4) // only A, B, C, D counted
    }
}

// MARK: - Gap Coverage: Escape Sequence Completeness

@Suite("CursorTracker — Escape Edge Cases")
struct CursorTrackerEscapeEdgeTests {

    @Test("unknown ESC character returns to ground")
    func unknownEscChar() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "AB")
        feed(ct, "\u{1B}Z") // unknown escape — back to ground
        feed(ct, "CD")
        #expect(ct.col == 4) // A, B, C, D
    }

    @Test("charset ) designation skips next byte")
    func charsetRightParen() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "AB")
        feed(ct, "\u{1B})0") // G1 = DEC Special Graphics
        feed(ct, "CD")
        #expect(ct.col == 4) // 0 is skipped
    }

    @Test("charset * designation skips next byte")
    func charsetStar() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "AB")
        feed(ct, "\u{1B}*B") // G2 = ASCII
        feed(ct, "CD")
        #expect(ct.col == 4)
    }

    @Test("charset + designation skips next byte")
    func charsetPlus() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "AB")
        feed(ct, "\u{1B}+0") // G3 = DEC Special Graphics
        feed(ct, "CD")
        #expect(ct.col == 4)
    }

    @Test("IND (ESC D) cancels pending wrap")
    func indCancelsPendingWrap() {
        let ct = CursorTracker(cols: 5, rows: 24)
        feed(ct, "ABCDE") // pendingWrap
        feed(ct, "\u{1B}D") // IND: pendingWrap=false, linefeed
        #expect(ct.row == 1)
        #expect(ct.col == 4) // col unchanged by IND
    }

    @Test("NEL (ESC E) cancels pending wrap")
    func nelCancelsPendingWrap() {
        let ct = CursorTracker(cols: 5, rows: 24)
        feed(ct, "ABCDE") // pendingWrap
        feed(ct, "\u{1B}E") // NEL: pendingWrap=false, col=0, linefeed
        #expect(ct.row == 1)
        #expect(ct.col == 0)
    }

    @Test("RI (ESC M) cancels pending wrap")
    func riCancelsPendingWrap() {
        let ct = CursorTracker(cols: 5, rows: 24)
        feed(ct, "\u{1B}[3;1H") // row 2
        feed(ct, "ABCDE") // pendingWrap
        feed(ct, "\u{1B}M") // RI: pendingWrap=false, row-1
        #expect(ct.row == 1)
        #expect(ct.col == 4) // col unchanged by RI
    }
}

// MARK: - Gap Coverage: CSI Parsing Edge Cases

@Suite("CursorTracker — CSI Parsing Edge Cases")
struct CursorTrackerCSIParsingTests {

    @Test("CSI with private mode prefix ? is ignored")
    func csiPrivateMode() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "AB")
        feed(ct, "\u{1B}[?25h") // DECTCEM show cursor — ? is intermediate, h is final
        feed(ct, "CD")
        #expect(ct.col == 4) // ? prefix → processCSIFinal sees 'h' which is default→ignore
    }

    @Test("CSI with > prefix is ignored (DA2 response etc)")
    func csiGreaterPrefix() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "AB")
        feed(ct, "\u{1B}[>c") // DA2 query — > is intermediate
        feed(ct, "CD")
        #expect(ct.col == 4)
    }

    @Test("CSI with space intermediate (cursor shape) is ignored")
    func csiSpaceIntermediate() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "AB")
        feed(ct, "\u{1B}[2 q") // DECSCUSR steady block cursor — space is intermediate
        feed(ct, "CD")
        #expect(ct.col == 4)
    }

    @Test("CSI with ! intermediate (soft reset) is ignored")
    func csiExclamIntermediate() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "AB")
        feed(ct, "\u{1B}[!p") // DECSTR soft reset — ! is intermediate
        feed(ct, "CD")
        #expect(ct.col == 4)
    }

    @Test("unknown CSI final bytes are ignored (J, K, L, M, P, X, @)")
    func unknownCSIFinals() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "\u{1B}[5;10H") // row 4, col 9
        // All these are valid CSI commands but CursorTracker ignores them
        feed(ct, "\u{1B}[2J")  // ED — erase display
        feed(ct, "\u{1B}[K")   // EL — erase line
        feed(ct, "\u{1B}[2L")  // IL — insert lines
        feed(ct, "\u{1B}[M")   // DL — delete line
        feed(ct, "\u{1B}[P")   // DCH — delete char
        feed(ct, "\u{1B}[3X")  // ECH — erase chars
        feed(ct, "\u{1B}[@")   // ICH — insert chars
        // None should affect cursor position
        #expect(ct.row == 4)
        #expect(ct.col == 9)
    }

    @Test("CSI invalid byte terminates sequence")
    func csiInvalidByte() {
        let ct = CursorTracker(cols: 80, rows: 24)
        // Feed CSI with an invalid byte (< 0x20)
        feed(ct, "\u{1B}[5")
        ct.process(Data([0x01])) // SOH → invalid in CSI → back to ground
        feed(ct, "AB")
        #expect(ct.col == 2) // CSI was aborted, AB printed normally
    }

    @Test("CSI with multiple empty params (semicolons only)")
    func csiEmptyParams() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "\u{1B}[;;H") // ESC[;;H → p1=0, p2=0 → CUP(1,1) → (0,0)
        #expect(ct.row == 0)
        #expect(ct.col == 0)
    }

    @Test("HT cancels pending wrap")
    func htCancelsPendingWrap() {
        let ct = CursorTracker(cols: 10, rows: 24)
        feed(ct, chars(10)) // fill 10-col, pendingWrap
        feed(ct, "\t") // HT: pendingWrap=false, col = min(9, (9/8+1)*8) = min(9,16) = 9
        #expect(ct.row == 0) // did NOT wrap
        #expect(ct.col == 9) // stayed at last col
    }
}

// MARK: - Gap Coverage: CUP / DECSTBM Param Edge Cases

@Suite("CursorTracker — Param Edge Cases")
struct CursorTrackerParamEdgeTests {

    @Test("CUP with only row param (ESC[5H)")
    func cupRowOnly() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "\u{1B}[5H") // row=5, col defaults (p2=0 → max(1,0)=1 → col 0)
        #expect(ct.row == 4)
        #expect(ct.col == 0)
    }

    @Test("CUP with row 0 and col 0 (ESC[0;0H)")
    func cupZeroParams() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "\u{1B}[0;0H") // both 0 → treated as 1,1 → (0,0)
        #expect(ct.row == 0)
        #expect(ct.col == 0)
    }

    @Test("CUP with missing row (ESC[;10H)")
    func cupColOnly() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "\u{1B}[5;5H") // start at (4,4)
        feed(ct, "\u{1B}[;10H") // row=0 (missing)→max(1,0)=1→row 0; col=10→col 9
        #expect(ct.row == 0)
        #expect(ct.col == 9)
    }

    @Test("DECSTBM with only top param (ESC[5r)")
    func decstbmTopOnly() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "\u{1B}[5r") // top=5, bottom=rows(24)
        // homes cursor
        #expect(ct.row == 0)
        #expect(ct.col == 0)
        // Verify: LF at row 23 (scrollBottom) stays
        feed(ct, "\u{1B}[24;1H")
        feed(ct, "\n")
        #expect(ct.row == 23)
    }

    @Test("DECSTBM with p1=0 (ESC[0;10r)")
    func decstbmZeroTop() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "\u{1B}[0;10r") // top=max(1,0)=1→scrollTop=0, bottom=10→scrollBottom=9
        feed(ct, "\u{1B}[10;1H") // row 10 (0-indexed: 9 = scrollBottom)
        feed(ct, "\n")
        #expect(ct.row == 9) // stays at scrollBottom
    }

    @Test("SCP/RCP saves and restores pending wrap")
    func scpRcpPendingWrap() {
        let ct = CursorTracker(cols: 5, rows: 24)
        feed(ct, "ABCDE") // pending wrap at (0, 4)
        feed(ct, "\u{1B}[s")  // SCP: save (including pendingWrap)
        feed(ct, "\r")         // CR cancels pending wrap
        #expect(ct.col == 0)
        feed(ct, "\u{1B}[u")  // RCP: restore → pendingWrap = true
        #expect(ct.row == 0)
        #expect(ct.col == 4)
        // Next printable should trigger wrap
        feed(ct, "X")
        #expect(ct.row == 1)
        #expect(ct.col == 1)
    }

    @Test("DECSTBM: LF below scroll region advances normally")
    func lfBelowScrollRegion() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "\u{1B}[5;10r") // scrollTop=4, scrollBottom=9
        feed(ct, "\u{1B}[15;1H") // row 15 (0-indexed: 14, BELOW scroll region)
        feed(ct, "\n")
        // Cursor is below scroll region — LF advances normally toward screen bottom
        #expect(ct.row == 15)
    }

    @Test("DECSTBM: LF below scroll region clamps at screen bottom")
    func lfBelowScrollRegionAtScreenBottom() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "\u{1B}[5;10r") // scrollTop=4, scrollBottom=9
        feed(ct, "\u{1B}[24;1H") // row 24 (0-indexed: 23, screen bottom)
        feed(ct, "\n")
        #expect(ct.row == 23) // at screen bottom — stays
    }

    @Test("DECSTBM: RI above scroll region moves up normally")
    func riAboveScrollRegion() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "\u{1B}[10;20r") // scrollTop=9, scrollBottom=19
        feed(ct, "\u{1B}[3;1H")   // row 3 (0-indexed: 2, ABOVE scroll region)
        feed(ct, "\u{1B}M")        // RI
        // Cursor is above scroll region — RI moves up normally toward row 0
        #expect(ct.row == 1)
    }

    @Test("DECSTBM: RI above scroll region clamps at screen top")
    func riAboveScrollRegionAtScreenTop() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "\u{1B}[10;20r") // scrollTop=9, scrollBottom=19
        feed(ct, "\u{1B}[1;1H")   // row 1 (0-indexed: 0, screen top)
        feed(ct, "\u{1B}M")        // RI
        #expect(ct.row == 0) // at screen top — stays
    }
}

// MARK: - Scroll Region Reset Detection

@Suite("CursorTracker — Scroll Region Reset Detection")
struct CursorTrackerScrollResetDetectionTests {

    @Test("ESC[r] (no params) sets scrollRegionWasReset flag")
    func escrNoParamsSetsFlag() {
        let ct = CursorTracker(cols: 80, rows: 39)
        #expect(ct.consumeScrollRegionReset() == false)
        feed(ct, "\u{1B}[r")
        #expect(ct.consumeScrollRegionReset() == true)
        #expect(ct.consumeScrollRegionReset() == false) // consumed
    }

    @Test("ESC[5r] (top only, bottom defaults) sets flag")
    func escrTopOnlySetsFlag() {
        let ct = CursorTracker(cols: 80, rows: 39)
        feed(ct, "\u{1B}[5r")
        #expect(ct.consumeScrollRegionReset() == true)
    }

    @Test("ESC[1;39r] with rows=39 does NOT set flag (explicit, fits PTY)")
    func escrExplicitFittingDoesNotSetFlag() {
        let ct = CursorTracker(cols: 80, rows: 39)
        feed(ct, "\u{1B}[1;39r")
        #expect(ct.consumeScrollRegionReset() == false)
    }

    @Test("ESC[1;40r] with rows=39 sets flag (p2 > rows)")
    func escrOversizedSetsFlag() {
        let ct = CursorTracker(cols: 80, rows: 39)
        feed(ct, "\u{1B}[1;40r")
        #expect(ct.consumeScrollRegionReset() == true)
    }

    @Test("ESC[5;10r] (explicit small region) does NOT set flag")
    func escrExplicitSmallDoesNotSetFlag() {
        let ct = CursorTracker(cols: 80, rows: 39)
        feed(ct, "\u{1B}[5;10r")
        #expect(ct.consumeScrollRegionReset() == false)
    }

    @Test("flag persists across multiple process calls until consumed")
    func flagPersistsUntilConsumed() {
        let ct = CursorTracker(cols: 80, rows: 39)
        feed(ct, "\u{1B}[r")
        feed(ct, "\u{1B}[5;3H")
        feed(ct, "Hello")
        #expect(ct.consumeScrollRegionReset() == true)
    }

    @Test("resize clears the flag")
    func resizeClearsFlag() {
        let ct = CursorTracker(cols: 80, rows: 39)
        feed(ct, "\u{1B}[r")
        ct.resize(cols: 80, rows: 39)
        #expect(ct.consumeScrollRegionReset() == false)
    }

    @Test("multiple resets only need one consume")
    func multipleResets() {
        let ct = CursorTracker(cols: 80, rows: 39)
        feed(ct, "\u{1B}[r")
        feed(ct, "\u{1B}[r")
        #expect(ct.consumeScrollRegionReset() == true)
        #expect(ct.consumeScrollRegionReset() == false)
    }
}

// MARK: - TUI App Scroll Region Reset (AttachStatusBar integration scenario)

@Suite("CursorTracker — TUI App Reset Scenario")
struct CursorTrackerTUIResetTests {

    // Simulates: a full-screen TUI app (e.g. Claude Code) running inside a PTY
    // sized to contentRows (rows-1 for status bar). When the TUI receives a resize,
    // it sends ESC[r] to reset the scroll region, then redraws its full screen,
    // ending with a CUP to position the cursor at the input prompt.
    //
    // After the output burst settles (16ms quiet), refreshBar uses the tracker's
    // (row, col) for CUP cursor return. These tests verify the tracker provides
    // the correct position.

    @Test("TUI resize redraw: ESC[r] + full redraw + CUP gives correct position")
    func tuiResizeRedraw() {
        // PTY sized to contentRows=39 (physical terminal 40, status bar reserves 1)
        let ct = CursorTracker(cols: 120, rows: 39)

        // TUI app was positioned at its prompt
        feed(ct, "\u{1B}[35;3H") // cursor at row 35, col 3
        #expect(ct.row == 34)
        #expect(ct.col == 2)

        // TUI receives SIGWINCH and starts redraw:
        // 1) Reset scroll region (no params = full terminal from app's perspective)
        feed(ct, "\u{1B}[r")
        #expect(ct.row == 0) // DECSTBM homes cursor
        #expect(ct.col == 0)

        // 2) Clear screen and redraw content
        feed(ct, "\u{1B}[H")      // home
        feed(ct, "\u{1B}[2J")     // clear (tracker ignores ED)
        // 3) Draw header, content area, status bar...
        //    (simulated as cursor positioning through the screen)
        feed(ct, "\u{1B}[1;1H")   // header
        feed(ct, chars(120))       // fill header row
        feed(ct, "\u{1B}[39;1H")  // TUI's status bar at its perceived last row
        feed(ct, chars(30))        // "? for shortcuts" text

        // 4) Final cursor position: TUI places cursor at its input prompt
        feed(ct, "\u{1B}[6;3H")   // row 6, col 3 (the ">" prompt)

        // This is what refreshBar will use for cursor return
        #expect(ct.row == 5)  // 0-indexed
        #expect(ct.col == 2)
    }

    @Test("ESC[r] in output burst does not corrupt final position when followed by CUP")
    func escrDoesNotCorruptFinalPosition() {
        let ct = CursorTracker(cols: 80, rows: 24)

        // Feed entire burst as single chunk (as it would arrive from PTY read)
        // ESC[r] resets to (0,0), then CUP repositions
        feed(ct, "\u{1B}[r\u{1B}[20;40H")

        #expect(ct.row == 19) // 0-indexed row 20
        #expect(ct.col == 39) // 0-indexed col 40
    }

    @Test("multiple ESC[r] in single burst: last CUP wins")
    func multipleEscrInBurst() {
        let ct = CursorTracker(cols: 80, rows: 24)

        // Some TUI frameworks may send ESC[r] multiple times during a redraw
        feed(ct, "\u{1B}[r")       // reset 1 → (0,0)
        feed(ct, "\u{1B}[10;1H")   // intermediate position
        feed(ct, "\u{1B}[r")       // reset 2 → (0,0)
        feed(ct, "\u{1B}[15;25H")  // final position

        #expect(ct.row == 14) // 0-indexed
        #expect(ct.col == 24)
    }

    @Test("resize then ESC[r]: scroll region uses new dimensions")
    func resizeThenEscr() {
        // Start with contentRows=39
        let ct = CursorTracker(cols: 120, rows: 39)
        feed(ct, "\u{1B}[35;3H") // position cursor

        // Terminal resizes to contentRows=29
        ct.resize(cols: 100, rows: 29)
        #expect(ct.row == 28) // clamped from 34 to rows-1=28
        #expect(ct.col == 2)  // clamped from 2 (fits in 100 cols)

        // TUI redraws after resize: ESC[r] resets scroll region for new size
        feed(ct, "\u{1B}[r")
        #expect(ct.row == 0) // homed
        #expect(ct.col == 0)

        // Linefeed at row 28 (0-indexed) = scrollBottom should stay
        feed(ct, "\u{1B}[29;1H") // row 29 (0-indexed: 28 = rows-1 = scrollBottom)
        feed(ct, "\n")
        #expect(ct.row == 28) // at scroll bottom, stays

        // But linefeed at row 27 should advance
        feed(ct, "\u{1B}[28;1H") // row 28 (0-indexed: 27)
        feed(ct, "\n")
        #expect(ct.row == 28) // advanced to 28
    }
}

// MARK: - Non-standard CSI prefix immunity

@Suite("CursorTracker — Non-standard CSI Prefix Immunity")
struct CursorTrackerPrefixImmunityTests {

    /// Any CSI sequence with a non-standard prefix (< > = ? ! or intermediate bytes)
    /// must NOT change cursor position, scroll region, or saved cursor state.
    /// This is a property-based test that defends against the ESC[<u bug:
    /// ESC[<u (kitty keyboard pop) was misinterpreted as ESC[u (RCP), homing
    /// the cursor and causing a permanent 1-row offset.
    @Test("CSI with < > = prefixes never changes cursor position")
    func prefixedCSINeverMovesCursor() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "\u{1B}[10;20H") // position at (9,19)

        // Final bytes that would move cursor if treated as standard CSI:
        // A=CUU B=CUD C=CUF D=CUB E=CNL F=CPL G=CHA H=CUP d=VPA f=HVP r=DECSTBM s=SCP u=RCP
        let dangerousFinals = "ABCDEFGHdfrsul"
        let prefixes = ["<", ">", "="]

        for prefix in prefixes {
            for final in dangerousFinals {
                feed(ct, "\u{1B}[10;20H") // reset to known position
                let before = (ct.row, ct.col)

                // With params
                feed(ct, "\u{1B}[\(prefix)5;\(final)")
                #expect(ct.row == before.0 && ct.col == before.1,
                        "ESC[\\(\(prefix))5;\\(\(final)) must not change cursor (was \\(before), now (\\(ct.row),\\(ct.col)))")

                // Without params
                feed(ct, "\u{1B}[10;20H")
                feed(ct, "\u{1B}[\(prefix)\(final)")
                #expect(ct.row == before.0 && ct.col == before.1,
                        "ESC[\\(\(prefix))\\(\(final)) must not change cursor")
            }
        }
    }

    /// Intermediate bytes (0x20-0x2F: space ! " # $ % & ' ( ) * + , - . /)
    /// also mark a CSI as non-standard.
    @Test("CSI with intermediate bytes never changes cursor position")
    func intermediateCSINeverMovesCursor() {
        let ct = CursorTracker(cols: 80, rows: 24)
        let intermediates = [" ", "!", "\"", "#", "$"]
        let dangerousFinals = "AHdfrsul"

        for inter in intermediates {
            for final in dangerousFinals {
                feed(ct, "\u{1B}[10;20H")
                let before = (ct.row, ct.col)

                feed(ct, "\u{1B}[\(inter)5\(final)")
                #expect(ct.row == before.0 && ct.col == before.1,
                        "ESC[\\(\(inter))5\\(\(final)) must not change cursor")
            }
        }
    }

    /// ESC[?...h] for alternate screen (1049/47/1047) IS allowed to change state.
    /// This confirms the ? prefix exception works correctly.
    @Test("ESC[?1049h is the only prefixed CSI allowed to change cursor")
    func questionMarkExceptionForAltScreen() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "\u{1B}[10;20H")

        // ESC[?1049h should home cursor (alternate screen)
        feed(ct, "\u{1B}[?1049h")
        #expect(ct.row == 0 && ct.col == 0,
                "ESC[?1049h should home cursor")

        // But ESC[?25h (show cursor) should NOT move cursor
        feed(ct, "\u{1B}[10;20H")
        let before = (ct.row, ct.col)
        feed(ct, "\u{1B}[?25h")
        #expect(ct.row == before.0 && ct.col == before.1,
                "ESC[?25h should not move cursor")
    }

    /// Real-world regression: Claude Code sends ESC[<u on startup (kitty keyboard
    /// protocol pop). This must not be interpreted as ESC[u (RCP).
    @Test("ESC[<u (kitty keyboard pop) does not restore cursor — regression test")
    func kittyKeyboardPopRegression() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "\u{1B}[10;20H") // position at (9,19)

        // Simulate Claude Code startup sequence
        feed(ct, "\u{1B}[>4m")      // xterm: set key modifier options
        feed(ct, "\u{1B}[<u")       // kitty: pop keyboard mode
        feed(ct, "\u{1B}[?1004l")   // disable focus reporting
        feed(ct, "\u{1B}[?2004l")   // disable bracketed paste

        // Cursor must NOT have moved
        #expect(ct.row == 9, "ESC[<u must not home cursor (row)")
        #expect(ct.col == 19, "ESC[<u must not home cursor (col)")
    }
}

// MARK: - Category 1: C0 Control Characters (0x00-0x1F)

@Suite("CursorTracker — C0 Control Characters Exhaustive")
struct CursorTrackerC0ExhaustiveTests {

    /// Every C0 byte (0x00-0x1F) tested individually.
    /// Bytes that SHOULD move the cursor: BS(0x08), TAB(0x09), LF(0x0A), VT(0x0B), FF(0x0C), CR(0x0D).
    /// ESC(0x1B) enters escape state but does not move cursor by itself.
    /// All others must NOT change cursor position.
    @Test("C0 bytes that should NOT move cursor: 0x00-0x07, 0x0E-0x1A, 0x1C-0x1F")
    func c0NonMovingBytes() {
        // These C0 bytes should have NO effect on cursor position
        let nonMoving: [UInt8] = [
            0x00, // NUL
            0x01, // SOH
            0x02, // STX
            0x03, // ETX
            0x04, // EOT
            0x05, // ENQ
            0x06, // ACK
            0x07, // BEL
            // 0x08 = BS — moves cursor
            // 0x09 = HT — moves cursor
            // 0x0A = LF — moves cursor
            // 0x0B = VT — moves cursor
            // 0x0C = FF — moves cursor
            // 0x0D = CR — moves cursor
            0x0E, // SO
            0x0F, // SI
            0x10, // DLE
            0x11, // DC1
            0x12, // DC2
            0x13, // DC3
            0x14, // DC4
            0x15, // NAK
            0x16, // SYN
            0x17, // ETB
            0x18, // CAN
            0x19, // EM
            0x1A, // SUB
            // 0x1B = ESC — changes parser state
            0x1C, // FS
            0x1D, // GS
            0x1E, // RS
            0x1F, // US
        ]

        for byte in nonMoving {
            let ct = CursorTracker(cols: 80, rows: 24)
            feed(ct, "ABCDE") // col=5, row=0
            ct.process(Data([byte]))
            #expect(ct.row == 0, "C0 byte 0x\(String(byte, radix: 16, uppercase: true)) should not change row (got \(ct.row))")
            #expect(ct.col == 5, "C0 byte 0x\(String(byte, radix: 16, uppercase: true)) should not change col (got \(ct.col))")
        }
    }

    @Test("C0 bytes that SHOULD move cursor: BS, HT, LF, VT, FF, CR")
    func c0MovingBytes() {
        // BS (0x08): col decreases by 1
        let ctBS = CursorTracker(cols: 80, rows: 24)
        feed(ctBS, "ABCDE")
        ctBS.process(Data([0x08]))
        #expect(ctBS.col == 4, "BS should move col back")

        // HT (0x09): col advances to next tab stop
        let ctHT = CursorTracker(cols: 80, rows: 24)
        feed(ctHT, "AB") // col=2
        ctHT.process(Data([0x09]))
        #expect(ctHT.col == 8, "HT should advance to tab stop")

        // LF (0x0A): row increases by 1
        let ctLF = CursorTracker(cols: 80, rows: 24)
        feed(ctLF, "AB")
        ctLF.process(Data([0x0A]))
        #expect(ctLF.row == 1, "LF should advance row")
        #expect(ctLF.col == 2, "LF should not change col")

        // VT (0x0B): same as LF
        let ctVT = CursorTracker(cols: 80, rows: 24)
        feed(ctVT, "AB")
        ctVT.process(Data([0x0B]))
        #expect(ctVT.row == 1, "VT should advance row")

        // FF (0x0C): same as LF
        let ctFF = CursorTracker(cols: 80, rows: 24)
        feed(ctFF, "AB")
        ctFF.process(Data([0x0C]))
        #expect(ctFF.row == 1, "FF should advance row")

        // CR (0x0D): col resets to 0
        let ctCR = CursorTracker(cols: 80, rows: 24)
        feed(ctCR, "ABCDE")
        ctCR.process(Data([0x0D]))
        #expect(ctCR.col == 0, "CR should reset col to 0")
        #expect(ctCR.row == 0, "CR should not change row")
    }

    @Test("ESC (0x1B) enters escape state but does not move cursor")
    func escDoesNotMoveCursor() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "ABCDE") // col=5
        ct.process(Data([0x1B])) // lone ESC
        #expect(ct.row == 0)
        #expect(ct.col == 5) // cursor unchanged
        // Parser is now in escape state; feed a ground-returning char to reset
        ct.process(Data([0x5C])) // \ = ST, returns to ground
    }

    @Test("C0 bytes interleaved with printable text")
    func c0Interleaved() {
        let ct = CursorTracker(cols: 80, rows: 24)
        // NUL + A + SOH + B + STX + C = only A, B, C advance cursor
        ct.process(Data([0x00, 0x41, 0x01, 0x42, 0x02, 0x43]))
        #expect(ct.col == 3, "Only printable chars should advance cursor")
        #expect(ct.row == 0)
    }
}

// MARK: - Category 2: ESC Sequences Exhaustive

@Suite("CursorTracker — ESC Sequences Exhaustive")
struct CursorTrackerEscExhaustiveTests {

    // BUG DETECTED: ESC c (RIS = Reset Initial State) falls to default in processEscape,
    // returning to ground without resetting cursor or scroll region.
    // A real terminal would reset cursor to (0,0) and scroll region to full screen.
    // This test documents the CURRENT behavior (cursor NOT reset).
    @Test("ESC c (RIS) resets cursor to (0,0) and scroll region to default")
    func escC_RIS() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "\u{1B}[5;10r") // set scroll region 5-10
        feed(ct, "\u{1B}[15;30H") // cursor at (14, 29)
        feed(ct, "\u{1B}c") // RIS — full terminal reset
        #expect(ct.row == 0, "ESC c should reset row to 0")
        #expect(ct.col == 0, "ESC c should reset col to 0")
        // Verify scroll region was also reset (LF at row 23 should stay = scrollBottom)
        feed(ct, "\u{1B}[24;1H") // go to row 24 (0-indexed: 23 = rows-1)
        feed(ct, "\n")
        #expect(ct.row == 23, "After RIS, scroll region should be full terminal (row 23 is scrollBottom)")
    }

    @Test("ESC H (HTS = set tab stop) should NOT move cursor")
    func escH_HTS() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "ABCDE") // col=5
        feed(ct, "\u{1B}H") // HTS
        #expect(ct.row == 0, "ESC H should not change row")
        #expect(ct.col == 5, "ESC H should not change col")
    }

    @Test("ESC = (DECKPAM keypad application mode) should NOT move cursor")
    func escEquals_DECKPAM() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "ABCDE") // col=5
        feed(ct, "\u{1B}=")
        #expect(ct.row == 0)
        #expect(ct.col == 5)
    }

    @Test("ESC > (DECKPNM keypad numeric mode) should NOT move cursor")
    func escGreater_DECKPNM() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "ABCDE")
        feed(ct, "\u{1B}>")
        #expect(ct.row == 0)
        #expect(ct.col == 5)
    }

    @Test("ESC Z (DECID) should NOT move cursor")
    func escZ_DECID() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "ABCDE")
        feed(ct, "\u{1B}Z")
        #expect(ct.row == 0)
        #expect(ct.col == 5)
    }

    @Test("ESC # 3 (DECDHL top half) should not move cursor")
    func escHash3_DECDHL() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "ABCDE") // col=5
        feed(ct, "\u{1B}#3") // DECDHL top half — ESC # skips next byte
        #expect(ct.col == 5, "ESC # 3 should not change col")
    }

    @Test("ESC # 4 (DECDHL bottom half) should not move cursor")
    func escHash4_DECDHL() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "ABCDE")
        feed(ct, "\u{1B}#4")
        #expect(ct.col == 5)
    }

    @Test("ESC # 5 (DECSWL single width) should not move cursor")
    func escHash5_DECSWL() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "ABCDE")
        feed(ct, "\u{1B}#5")
        #expect(ct.col == 5)
    }

    @Test("ESC # 6 (DECDWL double width) should not move cursor")
    func escHash6_DECDWL() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "ABCDE")
        feed(ct, "\u{1B}#6")
        #expect(ct.col == 5)
    }

    @Test("ESC # 8 (DECALN alignment test) should not move cursor")
    func escHash8_DECALN() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "ABCDE")
        feed(ct, "\u{1B}#8")
        #expect(ct.col == 5)
    }

    @Test("ESC \\\\ (ST = String Terminator) returns to ground, no cursor change")
    func escBackslash_ST() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "ABCDE")
        feed(ct, "\u{1B}\\") // ST
        #expect(ct.row == 0)
        #expect(ct.col == 5)
    }

    /// Loop through all ESC + final bytes (0x40-0x7E) that are NOT already handled,
    /// confirming they don't change cursor position.
    @Test("all unhandled ESC final bytes (0x40-0x7E) should not move cursor")
    func unhandledEscFinalBytes() {
        // Handled bytes in processEscape:
        // 0x5B=[  0x5D=]  0x50=P  0x58=X  0x5E=^  0x5F=_  (string sequences)
        // 0x44=D  0x45=E  0x4D=M  (IND, NEL, RI — move cursor)
        // 0x37=7  0x38=8  (DECSC/DECRC — save/restore cursor)
        // 0x5C=\  (ST)
        // 0x28=(  0x29=)  0x2A=*  0x2B=+  (charset — but these are 0x28-0x2B, outside 0x40-0x7E)
        //
        // All others in 0x40-0x7E should fall to default → return to ground with no cursor change
        let handledMoving: Set<UInt8> = [
            0x44, // D = IND (moves cursor)
            0x45, // E = NEL (moves cursor)
            0x4D, // M = RI (moves cursor)
            0x63, // c = RIS (resets cursor to 0,0)
        ]
        let handledSaveRestore: Set<UInt8> = [
            0x37, // 7 = DECSC (saves cursor, but position stays)
            0x38, // 8 = DECRC (restores cursor, changes position)
        ]
        let handledStateChange: Set<UInt8> = [
            0x5B, // [ = CSI
            0x5D, // ] = OSC
            0x50, // P = DCS
            0x58, // X = SOS
            0x5E, // ^ = PM
            0x5F, // _ = APC
            0x5C, // \ = ST
            0x23, // # = line attributes (skipNext)
        ]
        let allHandled = handledMoving.union(handledSaveRestore).union(handledStateChange)

        for byte: UInt8 in 0x40...0x7E {
            if allHandled.contains(byte) { continue }

            let ct = CursorTracker(cols: 80, rows: 24)
            feed(ct, "\u{1B}[10;20H") // position at (9, 19)
            ct.process(Data([0x1B, byte])) // ESC + byte
            #expect(ct.row == 9, "ESC 0x\(String(byte, radix: 16, uppercase: true)) ('\(UnicodeScalar(byte))') should not change row (got \(ct.row))")
            #expect(ct.col == 19, "ESC 0x\(String(byte, radix: 16, uppercase: true)) ('\(UnicodeScalar(byte))') should not change col (got \(ct.col))")
        }
    }

    @Test("ESC followed by bytes < 0x28 returns to ground via default (no effect on cursor)")
    func escLowBytes() {
        // Bytes 0x20-0x27 are not handled explicitly in processEscape
        // (charset is 0x28-0x2B, digits are 0x30-0x39 which fall to default too)
        for byte: UInt8 in 0x20...0x27 {
            let ct = CursorTracker(cols: 80, rows: 24)
            feed(ct, "ABCDE") // col=5
            ct.process(Data([0x1B, byte]))
            #expect(ct.row == 0, "ESC 0x\(String(byte, radix: 16, uppercase: true)) should not change row")
            #expect(ct.col == 5, "ESC 0x\(String(byte, radix: 16, uppercase: true)) should not change col")
        }
    }
}

// MARK: - Category 3: CSI Standard Sequences That Should NOT Move Cursor

@Suite("CursorTracker — CSI Non-Moving Sequences")
struct CursorTrackerCSINonMovingTests {

    /// All CSI final bytes that are NOT cursor-moving should leave cursor unchanged.
    /// Cursor-moving finals: A(CUU) B(CUD) C(CUF) D(CUB) E(CNL) F(CPL) G(CHA)
    ///                       H(CUP) d(VPA) f(HVP) r(DECSTBM) s(SCP) u(RCP)
    @Test("ED (J) — Erase in Display — should NOT move cursor")
    func edJ() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "\u{1B}[10;20H")
        for param in ["", "0", "1", "2", "3"] {
            feed(ct, "\u{1B}[10;20H") // reset position
            feed(ct, "\u{1B}[\(param)J")
            #expect(ct.row == 9, "ESC[\(param)J should not change row")
            #expect(ct.col == 19, "ESC[\(param)J should not change col")
        }
    }

    @Test("EL (K) — Erase in Line — should NOT move cursor")
    func elK() {
        let ct = CursorTracker(cols: 80, rows: 24)
        for param in ["", "0", "1", "2"] {
            feed(ct, "\u{1B}[10;20H")
            feed(ct, "\u{1B}[\(param)K")
            #expect(ct.row == 9, "ESC[\(param)K should not change row")
            #expect(ct.col == 19, "ESC[\(param)K should not change col")
        }
    }

    @Test("SGR (m) — Select Graphic Rendition — should NOT move cursor")
    func sgrM() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "\u{1B}[10;20H")
        // Various SGR sequences
        let sgrCodes = ["0", "1", "4", "7", "31", "38;5;196", "48;2;255;128;0", "0"]
        for code in sgrCodes {
            feed(ct, "\u{1B}[\(code)m")
        }
        #expect(ct.row == 9, "SGR should not change row")
        #expect(ct.col == 19, "SGR should not change col")
    }

    @Test("SU (S) — Scroll Up — should NOT move cursor")
    func suS() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "\u{1B}[10;20H")
        feed(ct, "\u{1B}[3S") // scroll up 3 lines
        #expect(ct.row == 9)
        #expect(ct.col == 19)
    }

    @Test("SD (T) — Scroll Down — should NOT move cursor")
    func sdT() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "\u{1B}[10;20H")
        feed(ct, "\u{1B}[3T") // scroll down 3 lines
        #expect(ct.row == 9)
        #expect(ct.col == 19)
    }

    @Test("IL (L) — Insert Lines — should NOT move cursor")
    func ilL() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "\u{1B}[10;20H")
        feed(ct, "\u{1B}[5L")
        #expect(ct.row == 9)
        #expect(ct.col == 19)
    }

    @Test("DL (M) — Delete Lines — should NOT move cursor")
    func dlM() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "\u{1B}[10;20H")
        feed(ct, "\u{1B}[5M")
        #expect(ct.row == 9)
        #expect(ct.col == 19)
    }

    @Test("ICH (@) — Insert Characters — should NOT move cursor")
    func ichAt() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "\u{1B}[10;20H")
        feed(ct, "\u{1B}[3@")
        #expect(ct.row == 9)
        #expect(ct.col == 19)
    }

    @Test("DCH (P) — Delete Characters — should NOT move cursor")
    func dchP() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "\u{1B}[10;20H")
        feed(ct, "\u{1B}[3P")
        #expect(ct.row == 9)
        #expect(ct.col == 19)
    }

    @Test("ECH (X) — Erase Characters — should NOT move cursor")
    func echX() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "\u{1B}[10;20H")
        feed(ct, "\u{1B}[5X")
        #expect(ct.row == 9)
        #expect(ct.col == 19)
    }

    @Test("SM (h) — Set Mode — should NOT move cursor")
    func smH() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "\u{1B}[10;20H")
        feed(ct, "\u{1B}[4h") // insert mode
        #expect(ct.row == 9)
        #expect(ct.col == 19)
    }

    @Test("RM (l) — Reset Mode — should NOT move cursor")
    func rmL() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "\u{1B}[10;20H")
        feed(ct, "\u{1B}[4l") // replace mode
        #expect(ct.row == 9)
        #expect(ct.col == 19)
    }

    @Test("DSR (n) — Device Status Report — should NOT move cursor")
    func dsrN() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "\u{1B}[10;20H")
        feed(ct, "\u{1B}[6n") // request cursor position report
        #expect(ct.row == 9)
        #expect(ct.col == 19)
    }

    @Test("DA (c) — Device Attributes — should NOT move cursor")
    func daC() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "\u{1B}[10;20H")
        feed(ct, "\u{1B}[c") // primary DA
        #expect(ct.row == 9)
        #expect(ct.col == 19)
    }

    @Test("XTWINOPS (t) — window ops — should NOT move cursor")
    func xtwinopsT() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "\u{1B}[10;20H")
        feed(ct, "\u{1B}[18t") // report terminal size
        feed(ct, "\u{1B}[8;40;120t") // resize window
        #expect(ct.row == 9)
        #expect(ct.col == 19)
    }

    @Test("TBC (g) — Tab Clear — should NOT move cursor")
    func tbcG() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "\u{1B}[10;20H")
        feed(ct, "\u{1B}[0g") // clear tab stop at current position
        feed(ct, "\u{1B}[3g") // clear all tab stops
        #expect(ct.row == 9)
        #expect(ct.col == 19)
    }

    /// Comprehensive loop: all CSI final bytes (0x40-0x7E) that should NOT move cursor.
    @Test("all non-moving CSI final bytes in a loop")
    func allNonMovingCSIFinals() {
        // Finals that DO move cursor or change state:
        let movingFinals: Set<UInt8> = [
            0x41, // A = CUU
            0x42, // B = CUD
            0x43, // C = CUF
            0x44, // D = CUB
            0x45, // E = CNL
            0x46, // F = CPL
            0x47, // G = CHA
            0x48, // H = CUP
            0x64, // d = VPA
            0x66, // f = HVP
            0x72, // r = DECSTBM (homes cursor)
            0x73, // s = SCP (saves cursor, no move — but we skip to be safe)
            0x75, // u = RCP (restores cursor, may move)
        ]

        for byte: UInt8 in 0x40...0x7E {
            if movingFinals.contains(byte) { continue }

            let ct = CursorTracker(cols: 80, rows: 24)
            feed(ct, "\u{1B}[10;20H") // position at (9, 19)
            // Feed CSI with a param + this final byte
            ct.process(Data([0x1B, 0x5B, 0x33, byte])) // ESC [ 3 <final>
            #expect(ct.row == 9, "CSI 3 \\(UnicodeScalar(byte)) (0x\(String(byte, radix: 16, uppercase: true))) should not change row (got \(ct.row))")
            #expect(ct.col == 19, "CSI 3 \\(UnicodeScalar(byte)) (0x\(String(byte, radix: 16, uppercase: true))) should not change col (got \(ct.col))")
        }
    }

    @Test("SCP (s) with no params saves but does not move cursor")
    func scpNoParams() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "\u{1B}[10;20H")
        feed(ct, "\u{1B}[s") // SCP: saves position but cursor stays
        #expect(ct.row == 9)
        #expect(ct.col == 19)
    }
}

// MARK: - Category 4: String Sequence Isolation

@Suite("CursorTracker — String Sequence Isolation")
struct CursorTrackerStringIsolationTests {

    @Test("OSC containing cursor-moving letters r, u, H, A does not trigger handlers")
    func oscContainingCursorLetters() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "AB") // col=2
        // OSC that contains 'r', 'u', 'H', 'A' in its data portion
        feed(ct, "\u{1B}]0;test_r_u_H_A_data\u{07}")
        #expect(ct.row == 0, "OSC data with r/u/H/A should not trigger CSI handlers")
        #expect(ct.col == 2, "OSC data with r/u/H/A should not change col")
    }

    @Test("OSC containing ESC-like bytes in data does not trigger handlers")
    func oscContainingEscBytes() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "AB") // col=2
        // OSC data contains "[5;10H" which would be CUP if parsed as CSI
        feed(ct, "\u{1B}]0;title[5;10H\u{07}")
        #expect(ct.row == 0)
        #expect(ct.col == 2)
    }

    @Test("DCS containing cursor-moving letters does not trigger handlers")
    func dcsContainingCursorLetters() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "AB") // col=2
        // DCS with r, u, H, A in data
        feed(ct, "\u{1B}Ptest_r_u_H_A_data\u{1B}\\") // DCS ... ST
        #expect(ct.row == 0, "DCS data with r/u/H/A should not trigger CSI handlers")
        #expect(ct.col == 2)
    }

    @Test("SOS containing non-ESC cursor-letter data does not trigger handlers")
    func sosContainingCursorLetters() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "AB") // col=2
        // SOS with cursor-moving letters (r, u, H, A) but no ESC byte in data
        // Note: ESC inside a string sequence exits to escape state (per VT spec),
        // so we use BEL termination and avoid ESC in the data payload.
        feed(ct, "\u{1B}Xtest_r_u_H_A_data\u{07}") // SOS ... BEL
        #expect(ct.row == 0, "SOS data with r/u/H/A should not trigger CSI handlers")
        #expect(ct.col == 2, "SOS data should not change col")
    }

    @Test("ESC inside SOS exits string state — this is correct VT behavior")
    func escInsideSOSExitsStringState() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "AB") // col=2
        // ESC inside SOS transitions to escape state, [ starts CSI, 5;10H is CUP
        // This is NOT a bug — ESC always exits string sequences per VT spec.
        feed(ct, "\u{1B}Xsome_data\u{1B}[5;10H")
        #expect(ct.row == 4, "ESC inside SOS should exit to escape → CSI → CUP(5,10)")
        #expect(ct.col == 9)
    }

    @Test("PM containing cursor-moving sequences does not move cursor")
    func pmContainingCursorSequences() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "AB")
        feed(ct, "\u{1B}^r_u_H_A\u{1B}\\")
        #expect(ct.row == 0)
        #expect(ct.col == 2)
    }

    @Test("APC containing cursor-moving sequences does not move cursor")
    func apcContainingCursorSequences() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "AB")
        feed(ct, "\u{1B}_r_u_H_A\u{1B}\\")
        #expect(ct.row == 0)
        #expect(ct.col == 2)
    }

    @Test("OSC terminated by ST: printable text after ST is processed normally")
    func oscSTFollowedByText() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "\u{1B}]0;title\u{1B}\\Hello")
        // After ESC ] ... ESC \ → ground, then "Hello" = 5 chars
        #expect(ct.row == 0)
        #expect(ct.col == 5)
    }

    @Test("OSC terminated by BEL: printable text after BEL is processed normally")
    func oscBELFollowedByText() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "\u{1B}]0;title\u{07}Hello")
        #expect(ct.col == 5)
    }

    @Test("nested-looking string sequences: OSC containing ESC ] does not break parser")
    func nestedLookingOSC() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "AB") // col=2
        // Inside OSC, an ESC transitions to escape state, then ] starts a new OSC
        // This is a real edge case in terminal emulators
        feed(ct, "\u{1B}]0;test\u{1B}]1;nested\u{07}")
        // The first ESC inside OSC goes to escape state, ] starts new OSC,
        // then BEL terminates. Cursor should not have moved.
        #expect(ct.col == 2)
    }

    @Test("long OSC data (1000 bytes) does not corrupt cursor")
    func longOSCData() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "AB") // col=2
        let longData = String(repeating: "x", count: 1000)
        feed(ct, "\u{1B}]0;\(longData)\u{07}")
        #expect(ct.col == 2)
        #expect(ct.row == 0)
    }
}

// MARK: - Category 5: Kitty Key Events

@Suite("CursorTracker — Kitty Key Events")
struct CursorTrackerKittyKeyTests {

    @Test("ESC[97u (key 'a' press) should NOT move cursor — not RCP")
    func kittyKeyA() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "\u{1B}[10;20H") // position at (9, 19)
        feed(ct, "\u{1B}[97u") // kitty: key 'a' (codepoint 97)
        // Has params, so the `if csiParams.isEmpty` guard in `u` handler skips it
        #expect(ct.row == 9, "ESC[97u should not be interpreted as RCP")
        #expect(ct.col == 19)
    }

    @Test("ESC[97;5u (Ctrl+a) should NOT move cursor")
    func kittyCtrlA() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "\u{1B}[10;20H")
        feed(ct, "\u{1B}[97;5u") // kitty: key 'a' with Ctrl modifier
        #expect(ct.row == 9)
        #expect(ct.col == 19)
    }

    @Test("ESC[13u (Enter key) should NOT move cursor")
    func kittyEnter() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "\u{1B}[10;20H")
        feed(ct, "\u{1B}[13u") // kitty: Enter (codepoint 13)
        #expect(ct.row == 9)
        #expect(ct.col == 19)
    }

    @Test("ESC[27u (Escape key) should NOT move cursor")
    func kittyEscape() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "\u{1B}[10;20H")
        feed(ct, "\u{1B}[27u") // kitty: Escape key (codepoint 27)
        #expect(ct.row == 9)
        #expect(ct.col == 19)
    }

    @Test("ESC[9u (Tab key) should NOT move cursor")
    func kittyTab() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "\u{1B}[10;20H")
        feed(ct, "\u{1B}[9u") // kitty: Tab key
        #expect(ct.row == 9)
        #expect(ct.col == 19)
    }

    @Test("ESC[57358u (Caps Lock key) should NOT move cursor")
    func kittyCapsLock() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "\u{1B}[10;20H")
        feed(ct, "\u{1B}[57358u") // kitty: Caps Lock
        #expect(ct.row == 9)
        #expect(ct.col == 19)
    }

    @Test("ESC[u with NO params IS RCP (restore cursor) — distinguish from kitty")
    func rcpNoParams() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "\u{1B}[10;20H") // position at (9, 19)
        feed(ct, "\u{1B}[s")       // SCP: save position
        feed(ct, "\u{1B}[1;1H")    // move to home
        feed(ct, "\u{1B}[u")       // RCP with no params — should restore
        #expect(ct.row == 9, "ESC[u (no params) should restore row")
        #expect(ct.col == 19, "ESC[u (no params) should restore col")
    }

    @Test("ESC[1u should NOT restore cursor — has params")
    func kittyKey1() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "\u{1B}[10;20H")
        feed(ct, "\u{1B}[s") // save
        feed(ct, "\u{1B}[1;1H") // move to home
        feed(ct, "\u{1B}[1u") // kitty key '1' (codepoint 49... wait, 1 != 49)
        // Regardless, it has params so it should NOT restore
        #expect(ct.row == 0, "ESC[1u should not restore cursor")
        #expect(ct.col == 0)
    }

    @Test("ESC[<u (kitty keyboard pop) with prefix should NOT move cursor")
    func kittyPopWithPrefix() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "\u{1B}[10;20H")
        feed(ct, "\u{1B}[<u") // < is a prefix → csiHasPrefix=true → skipped
        #expect(ct.row == 9)
        #expect(ct.col == 19)
    }

    @Test("ESC[>1u (kitty keyboard push) with prefix should NOT move cursor")
    func kittyPushWithPrefix() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "\u{1B}[10;20H")
        feed(ct, "\u{1B}[>1u") // > is a prefix
        #expect(ct.row == 9)
        #expect(ct.col == 19)
    }
}

// MARK: - Category 6: Incomplete/Broken Sequences

@Suite("CursorTracker — Incomplete/Broken Sequences")
struct CursorTrackerIncompleteSequenceTests {

    @Test("incomplete UTF-8 followed by ESC[H — cursor moves to home correctly")
    func incompleteUTF8ThenCUP() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "ABCDE") // col=5
        // Incomplete 3-byte UTF-8 (E4 B8 = 2 of 3 bytes for 中)
        ct.process(Data([0xE4, 0xB8]))
        #expect(ct.col == 5, "Incomplete UTF-8 should not advance cursor")
        // Now feed ESC[H — should reset UTF-8 state and home cursor
        feed(ct, "\u{1B}[H")
        #expect(ct.row == 0)
        #expect(ct.col == 0)
    }

    @Test("incomplete UTF-8 followed by ESC[5;10H — CUP works correctly")
    func incompleteUTF8ThenCUPWithParams() {
        let ct = CursorTracker(cols: 80, rows: 24)
        // Start 4-byte sequence (F0 9F = 2 of 4 bytes for emoji)
        ct.process(Data([0xF0, 0x9F]))
        #expect(ct.col == 0)
        feed(ct, "\u{1B}[5;10H")
        #expect(ct.row == 4)
        #expect(ct.col == 9)
    }

    @Test("ESC alone at end of buffer — parser in escape state, next buffer continues")
    func escAloneAtEndOfBuffer() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "ABCDE") // col=5
        ct.process(Data([0x1B])) // lone ESC — parser enters escape state
        #expect(ct.col == 5, "ESC alone should not change position")
        // Next buffer completes the sequence
        feed(ct, "[10;20H") // completes ESC [ 10;20 H
        #expect(ct.row == 9)
        #expect(ct.col == 19)
    }

    @Test("ESC[ alone at end of buffer — parser in CSI state, next buffer continues")
    func escBracketAloneAtEnd() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "ABCDE") // col=5
        feed(ct, "\u{1B}[") // enter CSI state
        #expect(ct.col == 5, "ESC[ alone should not change position")
        // Next buffer provides the params and final byte
        feed(ct, "10;20H")
        #expect(ct.row == 9)
        #expect(ct.col == 19)
    }

    @Test("CSI params split across multiple buffers")
    func csiParamsSplitAcrossBuffers() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "\u{1B}[")   // CSI start
        feed(ct, "1")          // first digit of row
        feed(ct, "0")          // second digit
        feed(ct, ";")          // separator
        feed(ct, "2")          // first digit of col
        feed(ct, "0")          // second digit
        feed(ct, "H")          // final byte
        #expect(ct.row == 9)
        #expect(ct.col == 19)
    }

    @Test("incomplete CSI aborted by another ESC — new sequence takes over")
    func incompleteCSIAbortedByESC() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "\u{1B}[99;99") // incomplete CSI (no final byte)
        feed(ct, "\u{1B}[5;10H") // ESC aborts incomplete, starts new CUP
        #expect(ct.row == 4)
        #expect(ct.col == 9)
    }

    @Test("incomplete CSI aborted by invalid byte")
    func incompleteCSIAbortedByInvalidByte() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "AB") // col=2
        feed(ct, "\u{1B}[5")
        ct.process(Data([0x00])) // NUL → invalid in CSI → back to ground
        feed(ct, "CD")
        #expect(ct.col == 4, "After invalid CSI abort, text should print normally")
    }

    @Test("ESC in OSC string terminates it and starts new escape sequence")
    func escInOSCStartsNewEscape() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "AB") // col=2
        // Start OSC, then ESC inside it should transition to escape state
        feed(ct, "\u{1B}]0;title") // in OSC string state
        feed(ct, "\u{1B}[10;20H") // ESC aborts OSC, [ starts CSI, 10;20H is CUP
        #expect(ct.row == 9, "ESC in OSC should start new escape → CSI → CUP")
        #expect(ct.col == 19)
    }

    @Test("multiple incomplete sequences followed by valid one")
    func multipleIncompletesThenValid() {
        let ct = CursorTracker(cols: 80, rows: 24)
        feed(ct, "\u{1B}")       // lone ESC
        feed(ct, "\u{1B}")       // another lone ESC (first returns to escape, second stays)
        feed(ct, "\u{1B}")       // another
        feed(ct, "[5;10H")       // finally complete a CSI
        #expect(ct.row == 4)
        #expect(ct.col == 9)
    }

    @Test("UTF-8 lead byte then ESC — UTF-8 abandoned, ESC sequence works")
    func utf8LeadThenESC() {
        let ct = CursorTracker(cols: 80, rows: 24)
        ct.process(Data([0xE4])) // 3-byte UTF-8 lead
        #expect(ct.col == 0) // no advance from lead alone
        feed(ct, "\u{1B}[5;10H") // ESC resets utf8, CUP works
        #expect(ct.row == 4)
        #expect(ct.col == 9)
    }

    @Test("buffer boundary in middle of UTF-8 — completed in next buffer")
    func utf8SplitAcrossBuffers() {
        let ct = CursorTracker(cols: 80, rows: 24)
        // "中" = E4 B8 AD — split across two buffers
        ct.process(Data([0xE4, 0xB8])) // 2 of 3 bytes
        #expect(ct.col == 0, "Partial UTF-8 should not advance cursor")
        ct.process(Data([0xAD])) // final continuation byte
        #expect(ct.col == 2, "Completed wide char should advance 2 cols")
    }

    @Test("mixed incomplete sequences: partial UTF-8 + partial CSI + valid text")
    func mixedIncompleteSequences() {
        let ct = CursorTracker(cols: 80, rows: 24)
        ct.process(Data([0xE4, 0xB8])) // partial UTF-8 (2 of 3)
        #expect(ct.col == 0)
        // ESC resets UTF-8 state (byte >= 0xC0 check in processGround doesn't apply
        // because ESC=0x1B is < 0x80, so utf8Remaining is reset to 0)
        feed(ct, "\u{1B}[") // enter CSI, UTF-8 state abandoned
        // Now we're in CSI state, feed more partial data
        feed(ct, "5") // digit in CSI
        // Then just complete it
        feed(ct, ";10H")
        #expect(ct.row == 4)
        #expect(ct.col == 9)
    }
}
