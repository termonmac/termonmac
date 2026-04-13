import Foundation

public enum GitNameSanitizer {
    /// Sanitize a string for use as a git branch name and folder name.
    /// Returns empty string if no valid characters remain.
    public static func sanitize(_ name: String) -> String {
        var s = name.trimmingCharacters(in: .whitespacesAndNewlines)

        // Replace illegal git branch chars and control characters with "-"
        let illegal = CharacterSet(charactersIn: " ~^:?[*\\/")
            .union(.controlCharacters)
        s = s.unicodeScalars
            .map { illegal.contains($0) ? "-" : String($0) }
            .joined()

        // Replace ".." → "." and "@{" → "@"
        while s.contains("..") {
            s = s.replacingOccurrences(of: "..", with: ".")
        }
        s = s.replacingOccurrences(of: "@{", with: "@")

        // Collapse consecutive hyphens
        while s.contains("--") {
            s = s.replacingOccurrences(of: "--", with: "-")
        }

        // Strip leading/trailing "." and "-"
        let trimChars = CharacterSet(charactersIn: ".-")
        s = s.trimmingCharacters(in: trimChars)

        // Strip trailing ".lock"
        if s.hasSuffix(".lock") {
            s = String(s.dropLast(5))
            s = s.trimmingCharacters(in: trimChars)
        }

        return s
    }
}
