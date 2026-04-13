import Foundation
import RemoteDevCore

#if os(macOS)
public final class PTYManager: PTYManagerProtocol, @unchecked Sendable {
    /// Negative value means unlimited.
    public static let defaultMaxSessions = -1
    public static let defaultCols = 80
    public static let defaultRows = 24

    public private(set) var maxSessions: Int

    struct ManagedSession {
        let pty: PTYSession
        let replayBuffer: RingBuffer
        var name: String
        var cols: Int
        var rows: Int
        var cwd: String?
        var sessionWorkDir: String?
        var sessionType: SessionType = .normal
        var parentSessionId: String?
        var branchName: String?
        var parentRepoPath: String?
        var parentBranchName: String?
    }

    private var sessions: [String: ManagedSession] = [:]
    private let lock = NSLock()

    /// Called when a session produces output: (sessionId, data)
    public var onOutput: ((String, Data) -> Void)?

    /// Called when a session's process exits: (sessionId)
    public var onSessionExited: ((String) -> Void)?

    /// The working directory for new PTY sessions.
    public var workDir: String?

    public init(maxSessions: Int = PTYManager.defaultMaxSessions) {
        self.maxSessions = maxSessions
    }

    public func updateMaxSessions(_ newMax: Int) {
        lock.lock()
        defer { lock.unlock() }
        if newMax < 0 {
            maxSessions = newMax
        } else {
            maxSessions = max(newMax, sessions.count)
        }
    }

    // MARK: - Session lifecycle

    /// Create a new PTY session. Does NOT start the PTY until resize is received.
    /// Returns false if max sessions reached.
    @discardableResult
    public func createSession(sessionId: String, name: String, cols: Int, rows: Int,
                       sessionWorkDir: String? = nil, sessionType: SessionType = .normal,
                       parentSessionId: String? = nil, branchName: String? = nil,
                       parentRepoPath: String? = nil, parentBranchName: String? = nil) -> (success: Bool, error: String?) {
        lock.lock()
        defer { lock.unlock() }

        guard maxSessions < 0 || sessions.count < maxSessions else {
            return (false, "session limit reached (\(maxSessions))")
        }
        guard sessions[sessionId] == nil else {
            return (false, "duplicate session id")
        }

        let effectiveWorkDir = sessionWorkDir ?? workDir
        let pty = PTYSession()
        let replay = RingBuffer()
        var managed = ManagedSession(pty: pty, replayBuffer: replay, name: name, cols: cols, rows: rows)
        managed.sessionWorkDir = effectiveWorkDir
        managed.sessionType = sessionType
        managed.parentSessionId = parentSessionId
        managed.branchName = branchName
        managed.parentRepoPath = parentRepoPath
        managed.parentBranchName = parentBranchName
        sessions[sessionId] = managed

        pty.onOutput = { [weak self] data in
            guard let self else { return }
            replay.append(data)
            self.onOutput?(sessionId, data)
        }

        pty.onExit = { [weak self] in
            self?.onSessionExited?(sessionId)
        }

        do {
            try pty.start(workDir: effectiveWorkDir, rows: UInt16(rows), cols: UInt16(cols), sessionId: sessionId)
            log("[ptyManager] session \(sessionId) (\(name)) started at \(cols)x\(rows) workDir=\(effectiveWorkDir ?? "default")")
        } catch {
            log("[ptyManager] failed to start session \(sessionId): \(error)")
            sessions.removeValue(forKey: sessionId)
            return (false, "failed to start terminal: \(error)")
        }

        return (true, nil)
    }

    public func write(_ data: Data, to sessionId: String) {
        lock.lock()
        let session = sessions[resolveSessionId(sessionId)]
        lock.unlock()
        session?.pty.write(data)
    }

    // MARK: - fd passing support

    public func masterFD(for sessionId: String) -> Int32? {
        lock.lock()
        defer { lock.unlock() }
        return sessions[resolveSessionId(sessionId)]?.pty.ptyMasterFD
    }

    public func suspendOutput(for sessionId: String) {
        lock.lock()
        let session = sessions[resolveSessionId(sessionId)]
        lock.unlock()
        session?.pty.suspendOutput()
    }

    public func resumeOutput(for sessionId: String) {
        lock.lock()
        let session = sessions[resolveSessionId(sessionId)]
        lock.unlock()
        session?.pty.resumeOutput()
    }

    public func appendTeeOutput(_ data: Data, for sessionId: String) {
        lock.lock()
        let session = sessions[resolveSessionId(sessionId)]
        lock.unlock()
        session?.pty.appendTeeOutput(data)
    }

    public func resize(sessionId: String, cols: Int, rows: Int) {
        lock.lock()
        let sid = resolveSessionId(sessionId)
        if var managed = sessions[sid] {
            managed.cols = cols
            managed.rows = rows
            sessions[sid] = managed
            lock.unlock()
            managed.pty.resize(cols: UInt16(cols), rows: UInt16(rows))
        } else {
            lock.unlock()
        }
    }

    public func updateCwd(sessionId: String, directory: String) {
        lock.lock()
        let sid = resolveSessionId(sessionId)
        if var managed = sessions[sid] {
            managed.cwd = directory
            sessions[sid] = managed
            log("[ptyManager] cwd for \(sid) updated to '\(directory)'")
        }
        lock.unlock()
    }

    public func getCwd(sessionId: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return sessions[resolveSessionId(sessionId)]?.cwd
    }

    public func rename(sessionId: String, name: String) {
        lock.lock()
        let sid = resolveSessionId(sessionId)
        if var managed = sessions[sid] {
            managed.name = name
            sessions[sid] = managed
            log("[ptyManager] renamed session \(sid) to '\(name)'")
        }
        lock.unlock()
    }

    public func destroy(sessionId: String) {
        lock.lock()
        let sid = resolveSessionId(sessionId)
        let session = sessions.removeValue(forKey: sid)
        lock.unlock()

        if let session {
            session.pty.onExit = nil  // prevent callback since we're explicitly destroying
            session.pty.stop()
            log("[ptyManager] destroyed session \(sid)")
        }
    }

    public func drainReplay(sessionId: String) -> Data {
        lock.lock()
        let session = sessions[resolveSessionId(sessionId)]
        lock.unlock()
        return session?.replayBuffer.drain() ?? Data()
    }

    /// Returns incremental replay data since the given offset.
    /// If offset is nil or too old, returns full replay (isFull = true).
    public func replayIncremental(sessionId: String, sinceOffset: UInt64?) -> (data: Data, currentOffset: UInt64, isFull: Bool) {
        lock.lock()
        let session = sessions[resolveSessionId(sessionId)]
        lock.unlock()

        guard let session else {
            return (Data(), 0, false)
        }

        if let offset = sinceOffset {
            return session.replayBuffer.snapshotSince(offset)
        } else {
            let snapshot = session.replayBuffer.snapshot()
            let currentOffset = session.replayBuffer.currentOffset
            return (snapshot, currentOffset, true)
        }
    }

    public func currentOffset(sessionId: String) -> UInt64 {
        lock.lock()
        let session = sessions[resolveSessionId(sessionId)]
        lock.unlock()
        return session?.replayBuffer.currentOffset ?? 0
    }

    public func sessionInfoList() -> [PTYSessionInfo] {
        lock.lock()
        defer { lock.unlock() }
        return sessions.map { (sid, managed) in
            PTYSessionInfo(sessionId: sid, name: managed.name, cols: managed.cols, rows: managed.rows,
                           sessionType: managed.sessionType,
                           cwd: managed.cwd ?? managed.sessionWorkDir)
        }
    }

    public func slavePath(for sessionId: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return sessions[resolveSessionId(sessionId)]?.pty.slavePath
    }

    public func getWorkDir(sessionId: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return sessions[resolveSessionId(sessionId)]?.sessionWorkDir
    }

    public func getParentRepoPath(sessionId: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return sessions[resolveSessionId(sessionId)]?.parentRepoPath
    }

    public func getParentBranchName(sessionId: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return sessions[resolveSessionId(sessionId)]?.parentBranchName
    }

    public func getSize(sessionId: String) -> (cols: Int, rows: Int) {
        lock.lock()
        defer { lock.unlock() }
        let s = sessions[resolveSessionId(sessionId)]
        return (cols: s?.cols ?? Self.defaultCols, rows: s?.rows ?? Self.defaultRows)
    }

    public func getSessionType(sessionId: String) -> SessionType {
        lock.lock()
        defer { lock.unlock() }
        return sessions[resolveSessionId(sessionId)]?.sessionType ?? .normal
    }

    public func getParentSessionId(sessionId: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return sessions[resolveSessionId(sessionId)]?.parentSessionId
    }

    public func getBranchName(sessionId: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return sessions[resolveSessionId(sessionId)]?.branchName
    }

    public func updateSessionType(sessionId: String, type: SessionType, branchName: String? = nil) {
        lock.lock()
        let sid = resolveSessionId(sessionId)
        if var managed = sessions[sid] {
            managed.sessionType = type
            if let branchName { managed.branchName = branchName }
            sessions[sid] = managed
        }
        lock.unlock()
    }

    public func updateSessionParent(sessionId: String, parentSessionId: String?,
                                     parentRepoPath: String?, parentBranchName: String?) {
        lock.lock()
        let sid = resolveSessionId(sessionId)
        if var managed = sessions[sid] {
            managed.parentSessionId = parentSessionId
            managed.parentRepoPath = parentRepoPath
            managed.parentBranchName = parentBranchName
            sessions[sid] = managed
        }
        lock.unlock()
    }

    public func hasSession(_ sessionId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return sessions[sessionId] != nil
    }

    public var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return sessions.isEmpty
    }

    public var sessionCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return sessions.count
    }

    /// Switch all sessions to buffer-only mode (peer disconnected).
    public func switchToBufferOnly() {
        lock.lock()
        let allSessions = sessions
        lock.unlock()

        for (_, managed) in allSessions {
            managed.pty.setOnOutput { data in
                managed.replayBuffer.append(data)
            }
        }
        log("[ptyManager] switched \(allSessions.count) sessions to buffer-only")
    }

    /// Switch all sessions to live mode (peer reconnected).
    public func switchToLive() {
        lock.lock()
        let allSessions = sessions
        lock.unlock()

        for (sid, managed) in allSessions {
            managed.pty.setOnOutput { [weak self] data in
                managed.replayBuffer.append(data)
                self?.onOutput?(sid, data)
            }
        }
        log("[ptyManager] switched \(allSessions.count) sessions to live")
    }

    public func destroyAll() {
        lock.lock()
        let allSessions = sessions
        sessions.removeAll()
        lock.unlock()

        for (sid, managed) in allSessions {
            managed.pty.onExit = nil
            managed.pty.stop()
            log("[ptyManager] destroyed session \(sid)")
        }
    }

    /// Resolve empty sessionId to the first session (backward compat with old iOS).
    private func resolveSessionId(_ sessionId: String) -> String {
        if !sessionId.isEmpty { return sessionId }
        lock.lock()
        defer { lock.unlock() }
        return sessions.keys.sorted().first ?? ""
    }

    /// Get the default (first) session ID for backward compatibility.
    public func defaultSessionId() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return sessions.keys.sorted().first
    }
}
#endif
