import Foundation
#if os(macOS)
import AppKit
#endif

/// Helpers for avoiding macOS TCC (Transparency, Consent, and Control) permission
/// prompts when listing home directory contents.
///
/// macOS 10.15+ prompts for consent when a non-sandboxed app accesses protected
/// directories (Documents, Downloads, Desktop, Music, etc.) via filesystem APIs
/// like `stat()` / `fileExists(atPath:isDirectory:)`.  When we only need to know
/// whether an entry is a directory for UI purposes, we can skip the syscall for
/// known-protected names that are always directories.
enum TCCHelper {

    /// Directory names under the home directory that are TCC-protected.
    /// Calling `fileExists(atPath:isDirectory:)` on these triggers consent dialogs.
    private static let protectedNames: Set<String> = [
        "Desktop",
        "Documents",
        "Downloads",
        "Movies",
        "Music",
        "Pictures",
    ]

    private static let homeDir: String = NSHomeDirectory()

    /// Returns `true` if `name` inside `parentDir` is a known TCC-protected
    /// directory that should be assumed to be a directory without calling
    /// `fileExists`.
    static func isTCCProtected(name: String, parentDir: String) -> Bool {
        guard protectedNames.contains(name) else { return false }
        // Normalize both paths for comparison (resolve symlinks, trailing slashes)
        let normalized = URL(fileURLWithPath: parentDir).standardized.path
        return normalized == homeDir
    }

    /// Check whether the entry at `parentDir/name` is a directory, skipping
    /// the filesystem call for TCC-protected home-directory entries.
    /// Returns `true` if the entry is a directory (or assumed to be one).
    static func isDirectory(name: String, parentDir: String) -> Bool {
        if isTCCProtected(name: name, parentDir: parentDir) {
            return true
        }
        var isDir: ObjCBool = false
        let full = (parentDir as NSString).appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: full, isDirectory: &isDir) && isDir.boolValue
    }

    // MARK: - Full Disk Access check

    /// Returns `true` if the current process has Full Disk Access.
    /// Tests by attempting to list `~/Desktop` — a TCC-protected directory.
    static func hasFullDiskAccess() -> Bool {
        let testPath = homeDir + "/Desktop"
        do {
            _ = try FileManager.default.contentsOfDirectory(atPath: testPath)
            return true
        } catch {
            return false
        }
    }

    #if os(macOS)
    /// Opens System Settings > Privacy & Security > Full Disk Access.
    static func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Reveals the termonmac binary in Finder so the user can drag it into
    /// System Settings > Full Disk Access.
    /// Returns the resolved path of the binary.
    @discardableResult
    static func revealBinaryInFinder() -> String {
        let symPath = ProcessInfo.processInfo.arguments[0]
        let resolved = URL(fileURLWithPath: symPath).resolvingSymlinksInPath().path
        NSWorkspace.shared.selectFile(resolved, inFileViewerRootedAtPath: "")
        return resolved
    }
    #endif
}
