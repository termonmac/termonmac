#if os(macOS)
import Foundation

struct DisclaimerCheck {
    private static let fileName = "disclaimer_accepted"

    /// Silently marks the current disclaimer revision as accepted.
    /// Called after successful OAuth sign-in (the web login page references the TOS).
    static func markAccepted(configDir: String) {
        let filePath = configDir + "/" + fileName
        let currentVersion = "\(DisclaimerText.revision)"
        let fm = FileManager.default
        if !fm.fileExists(atPath: configDir) {
            try? fm.createDirectory(atPath: configDir, withIntermediateDirectories: true)
        }
        try? currentVersion.write(toFile: filePath, atomically: true, encoding: .utf8)
    }

    /// Ensures the disclaimer has been accepted for the current revision.
    /// In interactive mode (TTY), prompts the user.
    /// In non-interactive mode (e.g. launchd), exits with error if not accepted.
    static func ensureAccepted(configDir: String) {
        let filePath = configDir + "/" + fileName
        let currentVersion = "\(DisclaimerText.revision)"

        // Check if already accepted for current revision
        if let accepted = try? String(contentsOfFile: filePath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
           accepted == currentVersion {
            return
        }

        // Not yet accepted — check if interactive
        guard isatty(STDIN_FILENO) != 0 else {
            // Non-interactive (launchd): if a prior revision was accepted, keep running
            // to avoid crash-loop. User will see new disclaimer next interactive run.
            if let accepted = try? String(contentsOfFile: filePath, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !accepted.isEmpty {
                print("[warning] Disclaimer revision \(currentVersion) not yet accepted (have \(accepted)). Run 'termonmac' to review.")
                return
            }
            // Never accepted at all — cannot run without acceptance
            print("""
            [error] Terms not yet accepted (revision \(currentVersion)).
            Run 'termonmac' interactively in a terminal to review and accept the terms before using the launchd service.
            """)
            exit(1)
        }

        // Interactive: show disclaimer and prompt
        print(DisclaimerText.text)
        print("Do you accept the above terms? [y/N] ", terminator: "")

        guard let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased(),
              answer == "y" || answer == "yes" else {
            print("Terms not accepted. Exiting.")
            exit(1)
        }

        // Save acceptance
        let fm = FileManager.default
        if !fm.fileExists(atPath: configDir) {
            try? fm.createDirectory(atPath: configDir, withIntermediateDirectories: true)
        }
        do {
            try currentVersion.write(toFile: filePath, atomically: true, encoding: .utf8)
        } catch {
            print("Warning: could not save disclaimer acceptance: \(error.localizedDescription)")
        }
    }
}
#endif
