import Foundation

#if os(macOS)

// MARK: - TUI Menu Engine

/// Interactive TUI menu for termonmac, navigated with arrow keys / j-k.
struct TUIMenu {

    // MARK: - Data model

    struct MenuItem {
        let label: String
        let action: () -> MenuResult
    }

    enum MenuResult {
        case stay            // redraw current menu (same items)
        case refreshMenu     // return to caller to rebuild menu with fresh data
        case back            // pop to parent
        case quit            // exit TUI
        case attachSession(String) // break out to attach flow
        case upgrade         // break out to upgrade flow
    }

    // MARK: - Terminal helpers

    private static var savedTermios = termios()

    static func enableRawMode() {
        tcgetattr(STDIN_FILENO, &savedTermios)
        var raw = savedTermios
        // Disable canonical mode, echo, and signal generation
        raw.c_lflag &= ~UInt(ICANON | ECHO | ISIG)
        raw.c_cc.16 = 1  // VMIN  — read returns after 1 byte
        raw.c_cc.17 = 0  // VTIME — no timeout
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)
    }

    static func disableRawMode() {
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &savedTermios)
    }

    /// Read a single keypress.  Returns the key enum.
    enum Key {
        case up, down, left, right, enter, backspace, char(Character), quit
    }

    static func readKey() -> Key {
        var buf = [UInt8](repeating: 0, count: 3)
        let n = read(STDIN_FILENO, &buf, 3)
        guard n > 0 else { return .quit }

        if n == 1 {
            switch buf[0] {
            case 0x0A, 0x0D: return .enter              // Enter
            case 0x7F, 0x08: return .backspace           // Backspace / Delete
            case 0x1B:       return .quit                // bare Escape
            case 0x03:       return .quit                // Ctrl-C
            case UInt8(ascii: "q"), UInt8(ascii: "Q"): return .quit
            case UInt8(ascii: "k"): return .up
            case UInt8(ascii: "j"): return .down
            default:
                return .char(Character(UnicodeScalar(buf[0])))
            }
        }

        // Escape sequences: ESC [ A/B
        if n == 3 && buf[0] == 0x1B && buf[1] == 0x5B {
            switch buf[2] {
            case 0x41: return .up     // ESC[A
            case 0x42: return .down   // ESC[B
            case 0x43: return .right  // ESC[C
            case 0x44: return .left   // ESC[D
            default: break
            }
        }

        return .char("?")
    }

    // MARK: - ANSI drawing

    static let esc = "\u{1B}["

    static func clearScreen() {
        out("\(esc)2J\(esc)H")
    }

    static func moveTo(row: Int, col: Int) {
        out("\(esc)\(row);\(col)H")
    }

    static func out(_ s: String) {
        let data = Array(s.utf8)
        Darwin.write(STDOUT_FILENO, data, data.count)
    }

    static func writeln(_ s: String) {
        out(s + "\r\n")
    }

    static func hideCursor() { out("\(esc)?25l") }
    static func showCursor() { out("\(esc)?25h") }

    static func terminalWidth() -> Int {
        var ws = winsize()
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0, ws.ws_col > 0 {
            return Int(ws.ws_col)
        }
        return 80
    }

    // ANSI style helpers
    static func bold(_ s: String) -> String   { "\(esc)1m\(s)\(esc)0m" }
    static func dim(_ s: String) -> String    { "\(esc)2m\(s)\(esc)0m" }
    static func cyan(_ s: String) -> String   { "\(esc)36m\(s)\(esc)0m" }
    static func green(_ s: String) -> String  { "\(esc)32m\(s)\(esc)0m" }
    static func yellow(_ s: String) -> String { "\(esc)33m\(s)\(esc)0m" }
    static func red(_ s: String) -> String    { "\(esc)31m\(s)\(esc)0m" }

    // MARK: - Menu rendering

    /// Draw a bordered menu and handle input loop.
    /// Returns the MenuResult from the selected action.
    @discardableResult
    static func runMenu(title: String, items: [MenuItem],
                        header: String? = nil, footer: String? = nil,
                        charActions: [Character: (Int) -> MenuResult] = [:]) -> MenuResult {
        var cursor = 0

        while true {
            clearScreen()
            moveTo(row: 1, col: 1)

            // Compute box width (labels may contain \n for multi-line items)
            let contentLines = items.flatMap { item -> [String] in
                item.label.components(separatedBy: "\n").enumerated().map { idx, sub in
                    idx == 0 ? "    \(sub)" : "      \(sub)"
                }
            }
            var maxLen = contentLines.map { stripAnsi($0).count }.max() ?? 20
            if let h = header { maxLen = max(maxLen, stripAnsi(h).count + 2) }
            let footerText = footer ?? "↑↓ navigate  →/⏎ select  ←/⌫ back  q quit"
            maxLen = max(maxLen, stripAnsi(footerText).count + 2)
            maxLen = max(maxLen, title.count + 2)
            let termWidth = terminalWidth()
            let maxBoxWidth = max(termWidth - 2, 20)  // 2 chars left margin
            let boxWidth = min(max(maxLen + 6, 36), maxBoxWidth)

            // Top border
            writeln("  \(dim("┌─ \(title) " + String(repeating: "─", count: max(0, boxWidth - title.count - 5)) + "┐"))")

            // Header (e.g., status line)
            if let h = header {
                let hTrunc = truncateAnsi(h, maxVisible: boxWidth - 5)
                writeln("  \(dim("│"))  \(hTrunc)\(padding(hTrunc, boxWidth))\(dim("│"))")
                writeln("  \(dim("│"))\(String(repeating: " ", count: boxWidth - 2))\(dim("│"))")
            }

            // Menu items (labels may contain \n for multi-line display)
            for (i, item) in items.enumerated() {
                let subLabels = item.label.components(separatedBy: "\n")
                for (lineIdx, subLabel) in subLabels.enumerated() {
                    let line: String
                    if lineIdx == 0 {
                        let indicator = i == cursor ? cyan("▸") : " "
                        let styled = i == cursor ? bold(subLabel) : subLabel
                        line = truncateAnsi("  \(indicator) \(styled)", maxVisible: boxWidth - 3)
                    } else {
                        // Continuation lines: dim for unselected, bold for selected
                        let styled = i == cursor ? bold(subLabel) : dim(subLabel)
                        line = truncateAnsi("      \(styled)", maxVisible: boxWidth - 3)
                    }
                    let visLen = stripAnsi(line).count
                    let pad = String(repeating: " ", count: max(1, boxWidth - 2 - visLen))
                    writeln("  \(dim("│"))\(line)\(pad)\(dim("│"))")
                }
            }

            // Empty line before footer
            writeln("  \(dim("│"))\(String(repeating: " ", count: boxWidth - 2))\(dim("│"))")

            // Footer
            let footerTrunc = truncateAnsi(footerText, maxVisible: boxWidth - 5)
            writeln("  \(dim("│"))  \(dim(footerTrunc))\(padding(footerTrunc, boxWidth))\(dim("│"))")
            writeln("  \(dim("└" + String(repeating: "─", count: boxWidth - 2) + "┘"))")

            // Input
            switch readKey() {
            case .up:
                cursor = (cursor - 1 + items.count) % items.count
            case .down:
                cursor = (cursor + 1) % items.count
            case .enter, .right:
                let result = items[cursor].action()
                switch result {
                case .stay: continue
                case .refreshMenu: return .stay
                case .back: return .back
                case .quit: return .quit
                case .attachSession, .upgrade: return result
                }
            case .quit:
                return .quit
            case .backspace, .left:
                return .back
            case .char(let ch):
                if let action = charActions[ch] {
                    let result = action(cursor)
                    switch result {
                    case .stay: continue
                    case .refreshMenu: return .stay
                    case .back: return .back
                    case .quit: return .quit
                    case .attachSession, .upgrade: return result
                    }
                }
            }
        }
    }

    // MARK: - Utilities

    static func padding(_ text: String, _ boxWidth: Int) -> String {
        let visLen = stripAnsi(text).count
        return String(repeating: " ", count: max(1, boxWidth - 2 - visLen - 2))
    }

    /// Truncate a string (possibly containing ANSI escapes) to a given visible width,
    /// appending "…" if truncated.
    static func truncateAnsi(_ s: String, maxVisible: Int) -> String {
        let visLen = stripAnsi(s).count
        guard visLen > maxVisible, maxVisible > 1 else { return s }
        var result = ""
        var visible = 0
        var inEscape = false
        for ch in s {
            if ch == "\u{1B}" { inEscape = true; result.append(ch); continue }
            if inEscape {
                result.append(ch)
                if ch.isLetter || ch == "m" { inEscape = false }
                continue
            }
            if visible >= maxVisible - 1 {
                result.append("…")
                result.append("\(esc)0m")  // reset any open ANSI style
                return result
            }
            result.append(ch)
            visible += 1
        }
        return result
    }

    static func stripAnsi(_ s: String) -> String {
        // Remove ANSI escape sequences for length calculation
        var result = ""
        var inEscape = false
        for ch in s {
            if ch == "\u{1B}" { inEscape = true; continue }
            if inEscape {
                if ch.isLetter || ch == "m" { inEscape = false }
                continue
            }
            result.append(ch)
        }
        return result
    }

    /// Show a message and wait for any key to return.
    static func pressAnyKey(_ message: String = "Press any key to continue...") {
        writeln("")
        writeln("  \(dim(message))")
        _ = readKey()
    }

    /// Run a blocking action, showing its output, then wait for keypress.
    /// Temporarily exits raw mode so the action can use normal stdio.
    static func runAction(label: String, action: () -> Void) -> MenuResult {
        disableRawMode()
        showCursor()
        // Clear screen and show header
        print("\u{1B}[2J\u{1B}[H", terminator: "")
        print("── \(label) ──")
        print()
        action()
        print()
        print("Press Enter to return...", terminator: "")
        _ = readLine()
        enableRawMode()
        hideCursor()
        return .stay
    }

    /// Prompt for confirmation (y/N).  Temporarily leaves raw mode.
    static func confirm(_ prompt: String) -> Bool {
        disableRawMode()
        showCursor()
        print()
        print(prompt, terminator: " ")
        let answer = readLine()?.lowercased() ?? ""
        enableRawMode()
        hideCursor()
        return answer == "y" || answer == "yes"
    }

    /// Prompt for case-sensitive confirmation.  Temporarily leaves raw mode.
    static func confirmExact(_ prompt: String, expected: String) -> Bool {
        disableRawMode()
        showCursor()
        print()
        print(prompt, terminator: " ")
        let answer = readLine() ?? ""
        enableRawMode()
        hideCursor()
        return answer == expected
    }

    /// Prompt for a directory path with Tab completion.  Temporarily leaves raw mode.
    static func promptPath(_ label: String) -> String? {
        disableRawMode()
        showCursor()
        print()
        let answer = PathInput.readPath(prompt: label + " ")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        enableRawMode()
        hideCursor()
        guard let answer, !answer.isEmpty else { return nil }
        return answer
    }

    /// Prompt for text input.  Temporarily leaves raw mode.
    static func prompt(_ label: String) -> String? {
        disableRawMode()
        showCursor()
        print()
        print(label, terminator: " ")
        let answer = readLine()?.trimmingCharacters(in: .whitespaces)
        enableRawMode()
        hideCursor()
        guard let answer, !answer.isEmpty else { return nil }
        return answer
    }

    /// Prompt for text input with a default value.  Temporarily leaves raw mode.
    /// Returns the default when the user presses Enter without typing anything.
    static func prompt(_ label: String, default defaultValue: String) -> String? {
        disableRawMode()
        showCursor()
        print()
        print("\(label) [\(defaultValue)]", terminator: " ")
        let answer = readLine()?.trimmingCharacters(in: .whitespaces)
        enableRawMode()
        hideCursor()
        guard let answer else { return nil }
        return answer.isEmpty ? defaultValue : answer
    }
}

#endif
