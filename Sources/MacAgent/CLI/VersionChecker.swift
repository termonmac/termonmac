import Foundation

#if os(macOS)

struct VersionChecker {
    private static let githubAPI = "https://api.github.com/repos/termonmac/termonmac/releases/latest"
    private static let checkInterval: TimeInterval = 24 * 60 * 60 // 24 hours

    private static var cacheFile: String {
        CLIRouter.configDir + "/version_check.json"
    }

    struct UpdateInfo {
        let currentVersion: String
        let latestVersion: String
    }

    // MARK: - Public API

    /// Read from cache only (instant, no network). For TUI header.
    static func cachedUpdateInfo() -> UpdateInfo? {
        guard !CLIRouter.version.hasSuffix("-dev") else { return nil }
        guard let cached = readCache() else { return nil }
        return compareVersions(current: CLIRouter.version, latest: cached.latestVersion)
    }

    /// Check with network fetch if cache is stale. For `termonmac version`.
    static func checkForUpdate() -> UpdateInfo? {
        guard !CLIRouter.version.hasSuffix("-dev") else { return nil }

        let current = CLIRouter.version

        if let cached = readCache(),
           cached.checkedAt.timeIntervalSinceNow > -checkInterval,
           cached.checkedAt.timeIntervalSinceNow <= 0 {
            return compareVersions(current: current, latest: cached.latestVersion)
        }

        guard let latest = fetchLatestVersion() else { return nil }
        writeCache(latestVersion: latest)
        return compareVersions(current: current, latest: latest)
    }

    /// Trigger a background cache refresh (non-blocking).
    static func refreshCacheInBackground() {
        guard !CLIRouter.version.hasSuffix("-dev") else { return }
        if let cached = readCache(),
           cached.checkedAt.timeIntervalSinceNow > -checkInterval,
           cached.checkedAt.timeIntervalSinceNow <= 0 {
            return
        }
        DispatchQueue.global(qos: .utility).async {
            if let latest = fetchLatestVersion() {
                writeCache(latestVersion: latest)
            }
        }
    }

    /// Run `brew upgrade` + `service restart` (without helper), then `execv` to relaunch.
    static func performUpgrade() {
        // Check if brew actually has a newer version before upgrading
        let check = Process()
        check.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        check.arguments = ["brew", "outdated", "termonmac/tap/termonmac"]
        let checkPipe = Pipe()
        check.standardOutput = checkPipe
        check.standardError = FileHandle.nullDevice
        try? check.run()
        check.waitUntilExit()
        let outdated = String(data: checkPipe.fileHandleForReading.readDataToEndOfFile(),
                              encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if outdated.isEmpty {
            print("Already at the latest version via Homebrew.")
            return
        }

        print("Upgrading TermOnMac...")
        print()

        let brew = Process()
        brew.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        brew.arguments = ["brew", "upgrade", "termonmac/tap/termonmac"]

        do {
            try brew.run()
            brew.waitUntilExit()
        } catch {
            print("Failed to run brew upgrade: \(error.localizedDescription)")
            return
        }

        guard brew.terminationStatus == 0 else {
            print("brew upgrade failed (exit \(brew.terminationStatus)).")
            return
        }

        print()
        print("  \u{2713} TermOnMac upgraded.")

        if CLIRouter.isServiceLoaded() {
            CLIRouter.restartCommand(restartHelper: false)
            print()
            print("  Note: Active sessions are still on the old version.")
            print("  Run 'termonmac service restart --restart-helper' when ready.")
            print("  (This will end all active sessions.)")
        }

        print()

        // Clear the version check cache so the relaunched process doesn't show the notice
        try? FileManager.default.removeItem(atPath: cacheFile)

        // Re-exec with new binary
        execv(CommandLine.arguments[0], CommandLine.unsafeArgv)

        // If execv fails (unlikely), tell the user to re-run manually
        print("Please re-run 'termonmac' to use the new version.")
    }

    // MARK: - Version comparison

    private static func compareVersions(current: String, latest: String) -> UpdateInfo? {
        guard isNewer(latest, than: current) else { return nil }
        return UpdateInfo(currentVersion: current, latestVersion: latest)
    }

    private static func isNewer(_ a: String, than b: String) -> Bool {
        let aParts = a.split(separator: ".").compactMap { Int($0) }
        let bParts = b.split(separator: ".").compactMap { Int($0) }
        for i in 0..<3 {
            let av = i < aParts.count ? aParts[i] : 0
            let bv = i < bParts.count ? bParts[i] : 0
            if av > bv { return true }
            if av < bv { return false }
        }
        return false
    }

    // MARK: - GitHub API

    private static func fetchLatestVersion() -> String? {
        guard let url = URL(string: githubAPI) else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("termonmac/\(CLIRouter.version)", forHTTPHeaderField: "User-Agent")

        let sem = DispatchSemaphore(value: 0)
        var result: String?

        URLSession.shared.dataTask(with: request) { data, _, _ in
            defer { sem.signal() }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tagName = json["tag_name"] as? String else { return }
            let stripped = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
            result = stripped.split(separator: "-").first.map(String.init) ?? stripped
        }.resume()

        _ = sem.wait(timeout: .now() + 3)
        return result
    }

    // MARK: - Cache

    private struct CacheData {
        let latestVersion: String
        let checkedAt: Date
    }

    private static func readCache() -> CacheData? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: cacheFile)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = json["latest_version"] as? String,
              let timestamp = json["checked_at"] as? TimeInterval else {
            return nil
        }
        return CacheData(latestVersion: version, checkedAt: Date(timeIntervalSince1970: timestamp))
    }

    private static func writeCache(latestVersion: String) {
        let json: [String: Any] = [
            "latest_version": latestVersion,
            "checked_at": Date().timeIntervalSince1970,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: json) else { return }
        let fm = FileManager.default
        // Ensure config directory exists
        try? fm.createDirectory(atPath: CLIRouter.configDir, withIntermediateDirectories: true)
        let tempFile = cacheFile + ".tmp"
        try? data.write(to: URL(fileURLWithPath: tempFile))
        // moveItem throws if destination exists — remove first
        try? fm.removeItem(atPath: cacheFile)
        try? fm.moveItem(atPath: tempFile, toPath: cacheFile)
    }
}

#endif
