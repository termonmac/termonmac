import Foundation
import RemoteDevCore

#if os(macOS)
/// Persists room-level config (session names, selected tabs, active session)
/// to `~/.config/termonmac/room_config.json` so it survives Mac agent restarts
/// and iOS reconnects.
final class RoomConfigStore: @unchecked Sendable {
    private let lock = NSLock()
    private let configDir: String
    private let configPath: String
    private var config: RoomConfig

    init(configDir dir: String? = nil) {
        let home = dir ?? NSString("~/.config/termonmac").expandingTildeInPath
        configDir = home
        configPath = home + "/room_config.json"
        config = RoomConfig()
        load()
    }

    // MARK: - Public API

    var current: RoomConfig {
        lock.lock()
        defer { lock.unlock() }
        return config
    }

    /// Returns the persisted session configs (used to restore PTY sessions on restart)
    func storedSessions() -> [RoomSessionConfig] {
        lock.lock()
        defer { lock.unlock() }
        return config.sessions
    }

    func addSession(sessionId: String, name: String, sessionType: SessionType? = nil,
                    parentSessionId: String? = nil, worktreeDir: String? = nil, branchName: String? = nil,
                    parentRepoPath: String? = nil, parentBranchName: String? = nil) {
        lock.lock()
        defer { lock.unlock() }
        guard !config.sessions.contains(where: { $0.sessionId == sessionId }) else { return }
        config.sessions.append(RoomSessionConfig(
            sessionId: sessionId, name: name, sessionType: sessionType,
            parentSessionId: parentSessionId, worktreeDir: worktreeDir, branchName: branchName,
            parentRepoPath: parentRepoPath, parentBranchName: parentBranchName
        ))
        save()
    }

    func updateWorktreeDir(sessionId: String, directory: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let idx = config.sessions.firstIndex(where: { $0.sessionId == sessionId }) else { return }
        config.sessions[idx].worktreeDir = stripFileURL(directory)
        save()
    }

    func updateSessionType(sessionId: String, sessionType: SessionType, branchName: String? = nil) {
        lock.lock()
        defer { lock.unlock() }
        guard let idx = config.sessions.firstIndex(where: { $0.sessionId == sessionId }) else { return }
        config.sessions[idx].sessionType = sessionType
        if let branchName { config.sessions[idx].branchName = branchName }
        save()
    }

    func updateSessionParent(sessionId: String, parentSessionId: String?,
                              parentRepoPath: String?, parentBranchName: String?) {
        lock.lock()
        defer { lock.unlock() }
        guard let idx = config.sessions.firstIndex(where: { $0.sessionId == sessionId }) else { return }
        config.sessions[idx].parentSessionId = parentSessionId
        config.sessions[idx].parentRepoPath = parentRepoPath
        config.sessions[idx].parentBranchName = parentBranchName
        save()
    }

    func renameSession(sessionId: String, name: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let idx = config.sessions.firstIndex(where: { $0.sessionId == sessionId }) else { return }
        config.sessions[idx].name = name
        save()
    }

    func removeSession(sessionId: String) {
        lock.lock()
        defer { lock.unlock() }
        config.sessions.removeAll { $0.sessionId == sessionId }
        if config.activeSessionId == sessionId {
            config.activeSessionId = config.sessions.first?.sessionId
        }
        save()
    }

    /// Apply an update from iOS (tab changes, active session, etc.)
    func applyUpdate(_ update: RoomConfig) {
        lock.lock()
        defer { lock.unlock() }
        for incoming in update.sessions {
            if let idx = config.sessions.firstIndex(where: { $0.sessionId == incoming.sessionId }) {
                config.sessions[idx].name = incoming.name
                config.sessions[idx].selectedTab = incoming.selectedTab
            }
        }
        config.activeSessionId = update.activeSessionId
        save()
    }

    /// Reconcile stored config with live PTY sessions:
    /// - Remove entries for sessions that no longer exist
    /// - Add entries for sessions not yet tracked
    func reconcile(with liveSessionIds: [(id: String, name: String)]) {
        lock.lock()
        defer { lock.unlock() }
        let liveSet = Set(liveSessionIds.map(\.id))
        config.sessions.removeAll { !liveSet.contains($0.sessionId) }
        for live in liveSessionIds {
            if !config.sessions.contains(where: { $0.sessionId == live.id }) {
                config.sessions.append(RoomSessionConfig(sessionId: live.id, name: live.name))
            }
        }
        if let active = config.activeSessionId, !liveSet.contains(active) {
            config.activeSessionId = config.sessions.first?.sessionId
        }
        save()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: configPath)) else {
            return
        }
        guard var loaded = try? JSONDecoder().decode(RoomConfig.self, from: data) else {
            log("[room_config] WARNING: room_config.json is corrupt, using defaults.")
            return
        }
        // Sanitize any file:// URLs that leaked into worktreeDir
        for i in loaded.sessions.indices {
            if let dir = loaded.sessions[i].worktreeDir, dir.hasPrefix("file://") {
                let afterScheme = dir.dropFirst(7)
                if let slashIdx = afterScheme.firstIndex(of: "/") {
                    loaded.sessions[i].worktreeDir = String(afterScheme[slashIdx...])
                }
            }
        }
        config = loaded
    }

    private func save() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: configDir) {
            try? fm.createDirectory(atPath: configDir, withIntermediateDirectories: true)
        }
        guard let data = try? JSONEncoder().encode(config) else { return }
        do {
            try data.write(to: URL(fileURLWithPath: configPath), options: .atomic)
        } catch {
            log("[room_config] WARNING: failed to save room_config.json: \(error.localizedDescription)")
        }
    }
}
#endif
