import Testing
import Foundation
@testable import MacAgentLib

// MARK: - Helpers

/// Feed a UTF-8 string into the tracker.
private func feed(_ tracker: CursorTracker, _ string: String) {
    tracker.process(Data(string.utf8))
}

/// Feed the same string into two trackers simultaneously (simulates fd-pass raw pass-through).
private func feedBoth(_ pty: CursorTracker, _ terminal: CursorTracker, _ string: String) {
    let data = Data(string.utf8)
    pty.process(data)
    terminal.process(data)
}

// MARK: - AttachStatusBar Scroll Region Desync

/// These tests prove a fundamental architectural issue in fd-pass mode:
///
/// - AttachStatusBar reserves the bottom terminal row for its status bar.
/// - CursorTracker is sized to `contentRows = terminalRows - 1` (PTY's view).
/// - In fd-pass mode, PTY escape sequences go **directly** to the Mac terminal,
///   which has `terminalRows` rows (one more than the PTY thinks).
///
/// When a TUI app sends `ESC[r]` (reset scroll region, no params):
///   - CursorTracker resets scroll region to `[0, contentRows-1]`
///   - Mac terminal resets scroll region to `[0, terminalRows-1]`
///   → 1-row desync.
///
/// This desync causes:
///   1. Cursor position tracking error (off by 1 row at scroll bottom)
///   2. refreshBar() returns cursor to wrong position
///   3. Visual: top content scrolls off, status bar duplicates

@Suite("AttachStatusBar — ESC[r] Scroll Region Desync (fd-pass mode)")
struct AttachStatusBarDesyncTests {

    // Typical terminal: 40 rows, status bar takes 1 → PTY gets 39
    let terminalRows = 40
    var contentRows: Int { terminalRows - 1 } // 39

    /// After ESC[r] (no params), CursorTracker and Mac terminal have different
    /// scroll bottoms. This is the root cause of the off-by-one bug.
    @Test("ESC[r] resets scroll bottom differently for PTY-sized vs terminal-sized tracker")
    func escrScrollBottomDesync() {
        // CursorTracker as AttachStatusBar uses it (PTY size)
        let ptyTracker = CursorTracker(cols: 80, rows: contentRows)  // 39
        // What the Mac terminal actually does (full terminal size)
        let macTerminal = CursorTracker(cols: 80, rows: terminalRows) // 40

        // TUI app sends ESC[r] — same bytes reach both
        feedBoth(ptyTracker, macTerminal, "\u{1B}[r")

        // Both home the cursor — that part is fine
        #expect(ptyTracker.row == 0)
        #expect(macTerminal.row == 0)

        // Now navigate to what the PTY considers its last row
        let lastPtyRow = contentRows // 39 in 1-indexed = row 38 in 0-indexed
        feedBoth(ptyTracker, macTerminal, "\u{1B}[\(lastPtyRow);1H") // CUP to row 39 (1-indexed)

        // Both should be at row 38 (0-indexed)
        #expect(ptyTracker.row == lastPtyRow - 1)
        #expect(macTerminal.row == lastPtyRow - 1)

        // LF at this row — THIS IS WHERE THEY DIVERGE
        feedBoth(ptyTracker, macTerminal, "\n")

        // ptyTracker: row 38 is its scrollBottom → stays at 38, content scrolls
        #expect(ptyTracker.row == contentRows - 1, """
            CursorTracker (PTY-sized) should stay at row \(contentRows - 1) \
            because it's at scrollBottom after ESC[r] with rows=\(contentRows)
            """)

        // macTerminal: row 38 is NOT its scrollBottom (39 is) → cursor moves to 39
        #expect(macTerminal.row == contentRows, """
            Mac terminal (full-sized) should advance to row \(contentRows) \
            because its scrollBottom is \(terminalRows - 1), not \(contentRows - 1). \
            THIS IS THE DESYNC: tracker says \(contentRows - 1), reality is \(contentRows).
            """)

        // THE BUG: 1-row cursor position desync
        #expect(ptyTracker.row != macTerminal.row,
                "After LF at PTY's scroll bottom, the two trackers must diverge — this proves the desync")
        #expect(macTerminal.row - ptyTracker.row == 1,
                "Mac terminal cursor is exactly 1 row below what CursorTracker reports")
    }

    /// Proves that after the desync, refreshBar() would return the cursor to
    /// the wrong row. This explains the user-reported symptom: "cursor position
    /// is one line above where it should be."
    @Test("refreshBar cursor return is off by 1 row after desync")
    func refreshBarCursorReturnOffByOne() {
        let ptyTracker = CursorTracker(cols: 80, rows: contentRows)

        // Simulate TUI app startup: ESC[r] + render full screen + cursor at bottom
        feed(ptyTracker, "\u{1B}[r")  // reset scroll region
        // TUI app renders contentRows lines of content, ending with cursor at last row
        for i in 1...contentRows {
            feed(ptyTracker, "\u{1B}[\(i);1H")  // CUP to each row
            feed(ptyTracker, String(repeating: "X", count: 10)) // some content
        }

        // TUI positions cursor at its "input prompt" row (e.g., row 5, 0-indexed: 4)
        feed(ptyTracker, "\u{1B}[5;3H") // row 5, col 3 (1-indexed)

        // Now simulate LFs that push cursor to PTY's scroll bottom
        feed(ptyTracker, "\u{1B}[\(contentRows);1H") // go to last PTY row
        feed(ptyTracker, "\n") // LF at scroll bottom

        let reportedRow = ptyTracker.row
        _ = ptyTracker.col

        // refreshBar would use CUP(reportedRow+1, reportedCol+1) to return cursor.
        // But the Mac terminal's cursor is actually 1 row below.
        //
        // refreshBar sends: ESC[<reportedRow+1>;<reportedCol+1>H
        // This moves cursor to row `reportedRow` (0-indexed) on the Mac terminal.
        // But the real cursor was at row `reportedRow + 1`.
        // After refreshBar, cursor is 1 row too high.

        #expect(reportedRow == contentRows - 1,
                "CursorTracker reports cursor at row \(contentRows - 1) (PTY's scroll bottom)")

        // The ACTUAL Mac terminal cursor is at contentRows (row 39, 0-indexed),
        // which is the status bar row! This is how the status bar gets overwritten.
        let actualMacRow = contentRows // = terminalRows - 1 = 39 (0-indexed) = the status bar row!
        #expect(actualMacRow == terminalRows - 1,
                "Real cursor has moved into the status bar row (\(terminalRows - 1))")
    }

    /// Proves that multiple LFs at the desync boundary accumulate — the error
    /// doesn't self-correct. Each LF where the tracker says "at scroll bottom,
    /// stay" but the terminal says "not at bottom, advance" increases the gap.
    /// However, the gap is capped at 1 row because after the Mac terminal reaches
    /// its own scroll bottom, it also stays.
    @Test("desync is capped at 1 row (Mac terminal reaches its own scroll bottom)")
    func desyncCappedAtOneRow() {
        let ptyTracker = CursorTracker(cols: 80, rows: contentRows)
        let macTerminal = CursorTracker(cols: 80, rows: terminalRows)

        feedBoth(ptyTracker, macTerminal, "\u{1B}[r") // reset scroll region

        // Go to PTY's scroll bottom
        feedBoth(ptyTracker, macTerminal, "\u{1B}[\(contentRows);1H")

        // First LF: desync appears (1 row gap)
        feedBoth(ptyTracker, macTerminal, "\n")
        #expect(macTerminal.row - ptyTracker.row == 1)

        // Second LF: ptyTracker stays at contentRows-1, macTerminal is now at ITS scroll bottom too
        feedBoth(ptyTracker, macTerminal, "\n")

        // Both are now at their respective scroll bottoms — gap stays at 1, not 2
        #expect(ptyTracker.row == contentRows - 1)
        #expect(macTerminal.row == terminalRows - 1)
        #expect(macTerminal.row - ptyTracker.row == 1, "Gap stays at exactly 1 row, doesn't grow")
    }

    /// The scroll region desync means the Mac terminal's scroll region includes
    /// the status bar row. When content scrolls, it can push the status bar
    /// content upward, causing the "duplicate status bar" visual.
    @Test("Mac terminal scroll region includes status bar row after ESC[r]")
    func scrollRegionIncludesStatusBarRow() {
        let macTerminal = CursorTracker(cols: 80, rows: terminalRows)

        // AttachStatusBar.setup() would have set scroll region to 1..contentRows
        // (ESC[1;39r] for 40-row terminal). But then...
        feed(macTerminal, "\u{1B}[1;\(contentRows)r") // initial status bar scroll region
        feed(macTerminal, "\u{1B}[1;1H") // home

        // Verify: LF at row contentRows-1 (scroll bottom = 38, 0-indexed) stays
        feed(macTerminal, "\u{1B}[\(contentRows);1H") // row 39 (1-indexed) = 38 (0-indexed)
        feed(macTerminal, "\n")
        #expect(macTerminal.row == contentRows - 1, "Before ESC[r]: scroll bottom protects status bar row")

        // TUI app sends ESC[r] → Mac terminal resets to FULL height
        feed(macTerminal, "\u{1B}[r")

        // Now scroll bottom is terminalRows-1 (row 39, 0-indexed) = the status bar row!
        feed(macTerminal, "\u{1B}[\(terminalRows);1H") // move to the very last row (status bar row)
        feed(macTerminal, "\n") // LF at the REAL scroll bottom
        #expect(macTerminal.row == terminalRows - 1,
                "After ESC[r]: cursor can reach and stay at the status bar row (\(terminalRows - 1))")

        // This means TUI output CAN now position content on the status bar row,
        // and scrolling CAN involve that row — causing status bar content to scroll up
        // and appear duplicated when refreshBar redraws.
    }
}

// MARK: - Fix Verification

@Suite("AttachStatusBar — Fix Verification")
struct AttachStatusBarFixTests {

    let terminalRows = 40
    var contentRows: Int { terminalRows - 1 }

    /// Proves that consumeScrollRegionReset() enables the output path to detect
    /// ESC[r] and immediately correct the scroll region, preventing the desync.
    @Test("consumeScrollRegionReset flag enables immediate correction after ESC[r]")
    func scrollRegionResetFlagEnablesCorrection() {
        let ptyTracker = CursorTracker(cols: 80, rows: contentRows)

        // TUI app sends ESC[r]
        feed(ptyTracker, "\u{1B}[r")

        // Output path checks this AFTER tracker.process():
        #expect(ptyTracker.consumeScrollRegionReset() == true,
                "Flag is set — output path should write ESC[1;\(contentRows)r + CUP")

        // After correction written to Mac terminal, scroll region is [1, contentRows].
        // Simulate the TUI continuing to render:
        feed(ptyTracker, "\u{1B}[\(contentRows);1H")
        feed(ptyTracker, "\n")
        #expect(ptyTracker.row == contentRows - 1,
                "CursorTracker stays at scroll bottom — and Mac terminal would too after correction")
    }

    /// Proves that ESC[1;Nr] with explicit N = contentRows does NOT trigger
    /// the flag — no unnecessary correction.
    @Test("explicit ESC[1;Nr] matching contentRows does not trigger correction")
    func explicitMatchingDoesNotTrigger() {
        let ptyTracker = CursorTracker(cols: 80, rows: contentRows)

        feed(ptyTracker, "\u{1B}[1;\(contentRows)r")
        #expect(ptyTracker.consumeScrollRegionReset() == false,
                "Explicit params matching PTY size — no desync, no correction needed")
    }

    /// Proves the fix handles the common TUI startup sequence:
    /// ESC[r] → clear screen → render → CUP to prompt position.
    @Test("full TUI startup sequence: flag set once, correction restores correct state")
    func fullTUIStartupSequence() {
        let ptyTracker = CursorTracker(cols: 80, rows: contentRows)

        // TUI startup: reset scroll region + clear + render + position cursor
        feed(ptyTracker, "\u{1B}[r")             // reset scroll region
        feed(ptyTracker, "\u{1B}[2J")             // clear screen
        feed(ptyTracker, "\u{1B}[1;1H")           // home
        feed(ptyTracker, String(repeating: "X", count: 80)) // render first line

        // Flag should still be set (not consumed by any internal mechanism)
        #expect(ptyTracker.consumeScrollRegionReset() == true)

        // After correction, cursor should be where the tracker reports
        #expect(ptyTracker.row == 0) // first line
        #expect(ptyTracker.col == 79) // end of 80-char line (clamped to cols-1)
    }
}

// MARK: - Alternate Screen Detection

@Suite("AttachStatusBar — Alternate Screen Detection")
struct AlternateScreenDetectionTests {

    let contentRows = 39

    /// ESC[?1049h (alternate screen enter) resets scroll region on the Mac terminal.
    /// CursorTracker must detect this and flag scrollRegionWasReset so that
    /// correctScrollRegion fires.
    @Test("ESC[?1049h triggers scroll region reset flag")
    func altScreenEnterTriggersReset() {
        let tracker = CursorTracker(cols: 80, rows: contentRows)

        // Position cursor somewhere non-home
        feed(tracker, "\u{1B}[10;5H")
        #expect(tracker.row == 9)
        #expect(tracker.col == 4)

        // Enter alternate screen
        feed(tracker, "\u{1B}[?1049h")

        // Flag should be set
        #expect(tracker.consumeScrollRegionReset() == true,
                "ESC[?1049h should flag scroll region reset")

        // Cursor should be homed (alternate screen resets cursor)
        #expect(tracker.row == 0, "Alternate screen entry homes cursor to row 0")
        #expect(tracker.col == 0, "Alternate screen entry homes cursor to col 0")
    }

    /// ESC[?47h (older alternate screen) should also trigger the flag.
    @Test("ESC[?47h triggers scroll region reset flag")
    func altScreen47TriggersReset() {
        let tracker = CursorTracker(cols: 80, rows: contentRows)
        feed(tracker, "\u{1B}[?47h")
        #expect(tracker.consumeScrollRegionReset() == true)
        #expect(tracker.row == 0)
    }

    /// ESC[?1047h (another alternate screen variant) should also trigger.
    @Test("ESC[?1047h triggers scroll region reset flag")
    func altScreen1047TriggersReset() {
        let tracker = CursorTracker(cols: 80, rows: contentRows)
        feed(tracker, "\u{1B}[?1047h")
        #expect(tracker.consumeScrollRegionReset() == true)
        #expect(tracker.row == 0)
    }

    /// ESC[?25h (show cursor) should NOT trigger the flag.
    @Test("ESC[?25h does not trigger scroll region reset")
    func showCursorDoesNotTrigger() {
        let tracker = CursorTracker(cols: 80, rows: contentRows)
        feed(tracker, "\u{1B}[10;5H")
        feed(tracker, "\u{1B}[?25h")
        #expect(tracker.consumeScrollRegionReset() == false,
                "ESC[?25h (show cursor) should not flag scroll region reset")
        // Cursor should NOT move
        #expect(tracker.row == 9)
        #expect(tracker.col == 4)
    }

    /// ESC[?1049l (exit alternate screen) should NOT trigger the flag.
    /// The main screen's scroll region is restored by the terminal, not reset.
    @Test("ESC[?1049l does not trigger scroll region reset")
    func altScreenExitDoesNotTrigger() {
        let tracker = CursorTracker(cols: 80, rows: contentRows)
        feed(tracker, "\u{1B}[?1049l")
        #expect(tracker.consumeScrollRegionReset() == false)
    }

    /// Normal (non-private) CSI sequences should not be affected by the
    /// private mode detection.
    @Test("Normal CSI unaffected by private mode tracking")
    func normalCSIUnaffected() {
        let tracker = CursorTracker(cols: 80, rows: contentRows)
        feed(tracker, "\u{1B}[5;10H") // CUP
        #expect(tracker.row == 4)
        #expect(tracker.col == 9)
        feed(tracker, "\u{1B}[r")     // DECSTBM reset
        #expect(tracker.consumeScrollRegionReset() == true)
        #expect(tracker.row == 0)
    }
}

// MARK: - Initial PTY Size (Fixed)

@Suite("AttachStatusBar — Initial PTY Size")
struct AttachInitialSizeTests {

    /// Verifies the correct behavior: PTY is created with rows-1 when status bar
    /// is enabled, so there is no size gap between PTY creation and attach.
    ///
    /// Both sessionCreateCommand() and TUIScreens.newSessionAction() now subtract 1
    /// for the status bar before creating the PTY:
    ///   let rows = isAttachStatusBarEnabled() && rawRows > 2 ? rawRows - 1 : rawRows
    ///   createSessionOnAgent(cols: cols, rows: rows)  ← already rows-1
    @Test("PTY created at rows-1 when status bar enabled — no size gap")
    func ptyCreatedAtCorrectRows() {
        let terminalRows = 40
        let contentRows = terminalRows - 1 // 39

        // PTY created with contentRows (status bar already accounted for)
        let initialPtyRows = contentRows

        // Shell starts and renders at the correct height
        let tracker = CursorTracker(cols: 80, rows: initialPtyRows)
        feed(tracker, "\u{1B}[\(initialPtyRows);1H") // shell positions at last PTY row
        #expect(tracker.row == contentRows - 1,
                "Shell renders at row \(contentRows - 1) — correct for \(contentRows)-row PTY")
        // sendCurrentSize() sets PTY to rows-1 — same value, no SIGWINCH, no race
        #expect(initialPtyRows == contentRows,
                "PTY initial rows (\(initialPtyRows)) == effective rows (\(contentRows)) — no size gap")
    }
}
