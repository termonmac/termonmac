import Foundation
import RemoteDevCore

#if os(macOS)
public final class InputLogStore: @unchecked Sendable {
    private var cache: [String: InputLogData] = [:]
    private var saveTimers: [String: DispatchWorkItem] = [:]
    private let queue = DispatchQueue(label: "InputLogStore")
    private let lock = NSLock()
    private let maxLogSize = 32_768 // 32KB

    // MARK: - Public API

    public init() {}

    public func loadLog(sessionId: String, workDir: String) -> InputLogData {
        lock.lock()
        defer { lock.unlock() }
        return _loadLog(sessionId: sessionId, workDir: workDir)
    }

    public func appendEntry(_ entry: InputLogEntry, sessionId: String, workDir: String) {
        lock.lock()
        defer { lock.unlock() }
        if cache[sessionId] == nil {
            _ = _loadLog(sessionId: sessionId, workDir: workDir)
        }
        cache[sessionId]?.entries.append(entry)
        _scheduleSave(sessionId: sessionId, workDir: workDir)
    }

    public func updateLog(_ logData: InputLogData, workDir: String) {
        lock.lock()
        defer { lock.unlock() }
        let sessionId = logData.sessionId
        cache[sessionId] = logData
        _scheduleSave(sessionId: sessionId, workDir: workDir)
    }

    public func flushToDisk(sessionId: String, workDir: String) {
        lock.lock()
        defer { lock.unlock() }
        saveTimers[sessionId]?.cancel()
        saveTimers.removeValue(forKey: sessionId)
        _saveToDisk(sessionId: sessionId, workDir: workDir)
    }

    public func removeLog(sessionId: String) {
        lock.lock()
        defer { lock.unlock() }
        cache.removeValue(forKey: sessionId)
        saveTimers[sessionId]?.cancel()
        saveTimers.removeValue(forKey: sessionId)
    }

    // MARK: - Git Exclude

    public func ensureGitExclude(workDir: String) {
        let gitPath = URL(fileURLWithPath: workDir).appendingPathComponent(".git")
        var gitDir: URL

        // Handle worktree: .git is a file containing "gitdir: <path>"
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: gitPath.path, isDirectory: &isDir), !isDir.boolValue {
            guard let content = try? String(contentsOf: gitPath, encoding: .utf8),
                  content.hasPrefix("gitdir: ") else { return }
            let relative = content.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "gitdir: ", with: "")
            let resolvedGitDir = URL(fileURLWithPath: relative, relativeTo: gitPath.deletingLastPathComponent())
            // Check for commondir to get the real .git directory
            let commondirFile = resolvedGitDir.appendingPathComponent("commondir")
            if let commondir = try? String(contentsOf: commondirFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) {
                gitDir = URL(fileURLWithPath: commondir, relativeTo: resolvedGitDir)
            } else {
                gitDir = resolvedGitDir
            }
        } else {
            gitDir = gitPath
        }

        let excludeFile = gitDir.appendingPathComponent("info/exclude")
        let excludeDir = excludeFile.deletingLastPathComponent()
        let pattern = ".remotedev"

        do {
            try FileManager.default.createDirectory(at: excludeDir, withIntermediateDirectories: true)
            var content = ""
            if FileManager.default.fileExists(atPath: excludeFile.path) {
                content = try String(contentsOf: excludeFile, encoding: .utf8)
            }
            if !content.contains(pattern) {
                if !content.isEmpty && !content.hasSuffix("\n") {
                    content += "\n"
                }
                content += pattern + "\n"
                try content.write(to: excludeFile, atomically: true, encoding: .utf8)
                log("[InputLogStore] added .remotedev to git exclude")
            }
        } catch {
            log("[InputLogStore] failed to update git exclude: \(error.localizedDescription)")
        }
    }

    // MARK: - Private

    private func logFileURL(sessionId: String, workDir: String) -> URL {
        URL(fileURLWithPath: workDir)
            .appendingPathComponent(".remotedev/input-log")
            .appendingPathComponent("\(sessionId).json")
    }

    /// Internal load — caller must hold lock.
    private func _loadLog(sessionId: String, workDir: String) -> InputLogData {
        if let cached = cache[sessionId] {
            return cached
        }
        let url = logFileURL(sessionId: sessionId, workDir: workDir)
        guard FileManager.default.fileExists(atPath: url.path) else {
            let empty = InputLogData(sessionId: sessionId)
            cache[sessionId] = empty
            return empty
        }
        do {
            let data = try Data(contentsOf: url)
            let logData = try JSONDecoder().decode(InputLogData.self, from: data)
            cache[sessionId] = logData
            return logData
        } catch {
            log("[InputLogStore] failed to load \(sessionId): \(error.localizedDescription)")
            let empty = InputLogData(sessionId: sessionId)
            cache[sessionId] = empty
            return empty
        }
    }

    /// Internal schedule — caller must hold lock.
    private func _scheduleSave(sessionId: String, workDir: String) {
        saveTimers[sessionId]?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.lock()
            defer { self.lock.unlock() }
            self._saveToDisk(sessionId: sessionId, workDir: workDir)
        }
        saveTimers[sessionId] = item
        queue.asyncAfter(deadline: .now() + 0.5, execute: item)
    }

    /// Internal save — caller must hold lock.
    private func _saveToDisk(sessionId: String, workDir: String) {
        guard var logData = cache[sessionId] else { return }
        let url = logFileURL(sessionId: sessionId, workDir: workDir)
        do {
            let dir = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            var data = try encoder.encode(logData)
            if data.count > maxLogSize {
                logData.entries.sort { $0.sortOrder < $1.sortOrder }
                while data.count > maxLogSize, !logData.entries.isEmpty {
                    logData.entries.removeFirst()
                    data = try encoder.encode(logData)
                }
                cache[sessionId] = logData
            }
            try data.write(to: url, options: .atomic)
        } catch {
            log("[InputLogStore] failed to save \(sessionId): \(error.localizedDescription)")
        }
    }
}
#endif
