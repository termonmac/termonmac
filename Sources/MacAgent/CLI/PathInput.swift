import Foundation
import CEditline

/// Reads a file-system path from stdin with directory Tab completion.
enum PathInput {

    /// Read a path with directory tab-completion.
    /// Returns `nil` on EOF (Ctrl-D).
    static func readPath(prompt: String) -> String? {
        let prevCompletion = rl_attempted_completion_function
        let prevAppend = rl_completion_append_character
        rl_attempted_completion_function = dirCompletion
        rl_completion_append_character = 0  // we include trailing / in matches
        defer {
            rl_attempted_completion_function = prevCompletion
            rl_completion_append_character = prevAppend
        }

        guard let buf = readline(prompt) else { return nil }
        defer { free(buf) }
        return String(cString: buf)
    }
}

// MARK: - readline completion callbacks (file-scope, no captures → C-compatible)

private var _matches: [String] = []
private var _matchIdx = 0

private func dirCompletion(
    _ text: UnsafePointer<CChar>?,
    _ start: Int32,
    _ end: Int32
) -> UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>? {
    rl_attempted_completion_over = 1  // don't fall back to default filename completion
    return rl_completion_matches(text, dirGenerator)
}

private func dirGenerator(
    _ text: UnsafePointer<CChar>?,
    _ state: Int32
) -> UnsafeMutablePointer<CChar>? {
    if state == 0 {
        _matches = buildDirCompletions(for: text.map(String.init(cString:)) ?? "")
        _matchIdx = 0
    }
    guard _matchIdx < _matches.count else { return nil }
    defer { _matchIdx += 1 }
    return strdup(_matches[_matchIdx])
}

// MARK: - Directory listing

private func buildDirCompletions(for input: String) -> [String] {
    // Normalize bare ~ to ~/ so it lists home directory contents
    let input = (input == "~") ? "~/" : input

    // Expand ~ to home directory
    let expanded: String
    if input.hasPrefix("~") {
        var exp = NSString(string: input).expandingTildeInPath
        // expandingTildeInPath strips trailing /; preserve it so the
        // searchDir/namePrefix split below works correctly.
        if input.hasSuffix("/") && !exp.hasSuffix("/") { exp += "/" }
        expanded = exp
    } else if !input.hasPrefix("/") && !input.isEmpty {
        expanded = FileManager.default.currentDirectoryPath + "/" + input
    } else {
        expanded = input
    }

    let searchDir: String
    let namePrefix: String

    if expanded.hasSuffix("/") {
        searchDir = expanded
        namePrefix = ""
    } else if expanded.isEmpty {
        searchDir = FileManager.default.currentDirectoryPath
        namePrefix = ""
    } else {
        searchDir = (expanded as NSString).deletingLastPathComponent
        namePrefix = (expanded as NSString).lastPathComponent
    }

    let dir = searchDir.isEmpty ? "/" : searchDir

    guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) else {
        return []
    }

    var result: [String] = []
    for name in entries.sorted() {
        if name.hasPrefix(".") && !namePrefix.hasPrefix(".") { continue }
        guard namePrefix.isEmpty || name.hasPrefix(namePrefix) else { continue }

        guard TCCHelper.isDirectory(name: name, parentDir: dir) else { continue }

        // Reconstruct match preserving original input style (~/..., /..., relative)
        let match: String
        if input.hasSuffix("/") || input.isEmpty {
            match = input + name
        } else if input.contains("/") {
            match = (input as NSString).deletingLastPathComponent + "/" + name
        } else {
            match = name
        }
        result.append(match + "/")
    }
    return result
}
