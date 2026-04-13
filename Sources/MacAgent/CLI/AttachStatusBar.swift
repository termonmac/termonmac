import Foundation

#if os(macOS)

/// Manages the terminal title and bottom status bar during an attach session.
/// The status bar is purely local to the Mac CLI — it does not enter the PTY data stream,
/// so iOS clients never see it.
///
/// Cursor management uses CUP (absolute positioning) instead of DECSC/DECRC to avoid
/// overwriting the PTY application's cursor save slot (which is a single shared register).
struct AttachStatusBar {

    // MARK: - Terminal Title (OSC sequences)

    static func setTitle(_ sessionName: String) {
        rawWrite("\u{1b}]0;[termonmac] \(sessionName)\u{07}")
    }

    static func clearTitle() {
        rawWrite("\u{1b}]0;\u{07}")
    }

    // MARK: - Status Bar (scroll region + bottom row)

    /// Set up scroll region to reserve bottom row and draw the status bar.
    /// Returns effective rows for the PTY (rows - 1), or nil if terminal is too small.
    @discardableResult
    static func setup(sessionName: String, prefixLabel: String = "^]") -> Int? {
        guard let (cols, rows) = terminalSize(), rows > 2 else { return nil }
        let contentRows = rows - 1
        // Set scroll region to content area only
        rawWrite("\u{1b}[\(1);\(contentRows)r")
        drawBar(sessionName: sessionName, cols: cols, barRow: rows, prefixLabel: prefixLabel)
        return contentRows
    }

    /// Redraw on SIGWINCH. Returns new effective rows for PTY, or nil if too small.
    /// Cursor return uses default (1,1) because the shell will reposition after resize.
    @discardableResult
    static func redraw(sessionName: String, prefixLabel: String = "^]") -> Int? {
        guard let (cols, rows) = terminalSize(), rows > 2 else { return nil }
        let contentRows = rows - 1
        // Update scroll region for new size
        rawWrite("\u{1b}[\(1);\(contentRows)r")
        drawBar(sessionName: sessionName, cols: cols, barRow: rows, prefixLabel: prefixLabel)
        return contentRows
    }

    /// Coalesced bar repaint with CUP return to tracked cursor position.
    /// Called during output quiet periods (not after every PTY output).
    /// cursorRow/cursorCol are 0-indexed (from CursorTracker).
    static func refreshBar(sessionName: String, cursorRow: Int, cursorCol: Int, prefixLabel: String = "^]") {
        guard let (cols, rows) = terminalSize(), rows > 2 else { return }
        let contentRows = rows - 1
        // Re-establish scroll region — full-screen TUI apps (e.g. Claude Code)
        // may reset it via ESC[r] or ESC[?1049h], allowing their output to
        // overwrite the bar row. This unconditional DECSTBM acts as a self-healing
        // safety net (restored within 16ms of any scroll region change).
        rawWrite("\u{1b}[\(1);\(contentRows)r")
        drawBar(sessionName: sessionName, cols: cols, barRow: rows,
                returnRow: cursorRow + 1, returnCol: cursorCol + 1,
                prefixLabel: prefixLabel)
    }

    /// Remove scroll region, clear the status bar row, and clear the terminal title.
    static func teardown() {
        // Reset scroll region to full terminal
        rawWrite("\u{1b}[r")
        // Clear the last line (where status bar was)
        if let (_, rows) = terminalSize() {
            rawWrite("\u{1b}[\(rows);1H")  // move to last row
            rawWrite("\u{1b}[2K")           // erase entire line
        }
        clearTitle()
    }

    // MARK: - Private helpers

    private static func terminalSize() -> (cols: Int, rows: Int)? {
        var ws = winsize()
        guard ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0 else { return nil }
        return (Int(ws.ws_col), Int(ws.ws_row))
    }

    /// Draw the status bar on `barRow`, then move cursor to `returnRow;returnCol`.
    /// All coordinates are 1-indexed (terminal convention).
    /// Default return position is (1,1) — top-left, suitable for setup/resize
    /// where the shell will reposition the cursor via subsequent output.
    private static func drawBar(sessionName: String, cols: Int, barRow: Int,
                                returnRow: Int = 1, returnCol: Int = 1,
                                prefixLabel: String = "^]") {
        rawWrite("\u{1b}[\(barRow);1H")            // move to bar row
        let leftText = " \(sessionName)"
        let rightText = "\(prefixLabel) k kill  \(prefixLabel) d detach "
        let padding = max(0, cols - leftText.count - rightText.count)
        let bar = leftText + String(repeating: " ", count: padding) + rightText
        rawWrite("\u{1b}[7m")                       // reverse video
        rawWrite(bar)
        rawWrite("\u{1b}[0m")                       // reset attributes
        rawWrite("\u{1b}[\(returnRow);\(returnCol)H") // CUP to return position
    }

    private static func rawWrite(_ s: String) {
        let bytes = Array(s.utf8)
        bytes.withUnsafeBufferPointer { buf in
            var written = 0
            while written < buf.count {
                let w = Darwin.write(STDOUT_FILENO, buf.baseAddress!.advanced(by: written), buf.count - written)
                if w > 0 { written += w }
                else if w < 0 && (errno == EAGAIN || errno == EINTR) { continue }
                else { break }
            }
        }
    }
}

#endif
