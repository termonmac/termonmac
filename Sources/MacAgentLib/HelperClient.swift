import Foundation
import RemoteDevCore
import CPosixHelpers

#if os(macOS)

/// IPC client that connects to the PTY helper process via Unix domain socket
/// and conforms to PTYManagerProtocol so it can be used as a drop-in replacement.
public final class HelperClient: PTYManagerProtocol, @unchecked Sendable {
    private var socketFD: Int32 = -1
    private let fdLock = NSLock()
    private let writeLock = NSLock()
    private let pendingLock = NSLock()
    private var pendingRequests: [UInt64: (HelperMessage) -> Void] = [:]
    private var requestIdCounter: UInt64 = 0

    // Session cache — populated from helper responses and local mutations
    private var sessionCache: [String: SessionDetail] = [:]
    private var sessionOffsets: [String: UInt64] = [:]
    private let cacheLock = NSLock()

    // Serial queue for dispatching events to avoid blocking the read loop
    private let eventQueue = DispatchQueue(label: "helper-client.events")
    private var readThread: Thread?

    // Reconnection state
    private var socketPath: String?
    private var shouldReconnect = true
    private static let maxReconnectAttempts = 10

    // Keepalive timer to detect half-open sockets
    private var keepaliveTimer: DispatchSourceTimer?
    private static let keepaliveInterval: TimeInterval = 30


    // PTYManagerProtocol properties
    public var onOutput: ((String, Data) -> Void)?
    public var onSessionExited: ((String) -> Void)?
    public var workDir: String?

    /// Called after successful reconnection to the helper.
    public var onReconnected: (() -> Void)?

    /// Called when all reconnect attempts are exhausted.
    public var onDisconnected: (() -> Void)?

    /// Called when socket reconnect fails, giving the owner a chance to restart the helper process.
    /// Should return true if a new helper was started and the socket path is still valid.
    public var onRestartHelper: (() -> Bool)?

    public var isEmpty: Bool {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return sessionCache.isEmpty
    }

    public var sessionCount: Int {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return sessionCache.count
    }

    public private(set) var maxSessions: Int = PTYManager.defaultMaxSessions

    public func updateMaxSessions(_ newMax: Int) {
        if newMax < 0 {
            maxSessions = newMax
        } else {
            maxSessions = max(newMax, sessionCount)
        }
        _ = sendRequest(.updateMaxSessions(maxSessions: maxSessions))
    }

    public init() {}

    deinit {
        disconnect()
    }

    // MARK: - Connection

    /// Low-level socket connect (no read loop).
    private func connectSocket(socketPath: String) throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw HelperClientError.socketCreationFailed(errno)
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            Darwin.close(fd)
            throw HelperClientError.pathTooLong
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
                pathBytes.withUnsafeBufferPointer { src in
                    _ = memcpy(dest, src.baseAddress!, src.count)
                }
            }
        }

        let addrLen = socklen_t(MemoryLayout<sa_family_t>.size + pathBytes.count)
        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(fd, sockPtr, addrLen)
            }
        }
        guard result == 0 else {
            Darwin.close(fd)
            throw HelperClientError.connectFailed(errno)
        }

        // Prevent child processes (forkpty shells) from inheriting this fd
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)

        fdLock.lock()
        self.socketFD = fd
        fdLock.unlock()
    }

    public func connect(socketPath: String) throws {
        self.socketPath = socketPath
        self.shouldReconnect = true
        try connectSocket(socketPath: socketPath)
        startReadLoop()
        startKeepalive()
    }

    public func disconnect() {
        shouldReconnect = false
        stopKeepalive()
        fdLock.lock()
        let fd = socketFD
        socketFD = -1
        fdLock.unlock()
        if fd >= 0 {
            // shutdown unblocks any concurrent read() on this fd (close alone may not on macOS)
            Darwin.shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
        }
        wakePendingRequests()
    }

    /// Connect without auto-reconnect. Used by Mac CLI for direct pty_helper.sock connection.
    public func connectNoReconnect(socketPath: String) throws {
        self.socketPath = socketPath
        self.shouldReconnect = false
        try connectSocket(socketPath: socketPath)
        startReadLoop()
    }

    public var isConnected: Bool {
        fdLock.lock()
        defer { fdLock.unlock() }
        return socketFD >= 0
    }

    private func wakePendingRequests() {
        pendingLock.lock()
        let pending = pendingRequests
        pendingRequests.removeAll()
        pendingLock.unlock()
        for (_, handler) in pending {
            handler(.ipcError("helper connection lost"))
        }
    }

    // MARK: - Keepalive

    private func startKeepalive() {
        stopKeepalive()
        let timer = DispatchSource.makeTimerSource(queue: eventQueue)
        timer.schedule(deadline: .now() + Self.keepaliveInterval,
                       repeating: Self.keepaliveInterval)
        timer.setEventHandler { [weak self] in
            guard let self, self.isConnected else { return }
            if !self.sendPing() {
                log("[helperClient] keepalive ping failed — read loop will handle reconnect")
            }
        }
        timer.resume()
        keepaliveTimer = timer
    }

    private func stopKeepalive() {
        keepaliveTimer?.cancel()
        keepaliveTimer = nil
    }

    // MARK: - Read loop (with reconnect)

    private func startReadLoop() {
        let thread = Thread { [weak self] in
            self?.readLoop()
        }
        thread.name = "helper-client.read"
        thread.qualityOfService = .userInteractive
        readThread = thread
        thread.start()
    }

    private func readLoop() {
        while true {
            // Read frames while connected
            while socketFD >= 0 {
                do {
                    guard let response = try IPCFraming.readFrame(IPCResponse.self, from: socketFD) else {
                        break  // EOF
                    }
                    handleResponse(response)
                } catch {
                    if socketFD >= 0 {
                        log("[helperClient] read error: \(error)")
                    }
                    break
                }
            }

            // Disconnected — atomically claim the fd to avoid double-close
            fdLock.lock()
            let oldFD = socketFD
            socketFD = -1
            fdLock.unlock()
            if oldFD >= 0 { Darwin.close(oldFD) }
            wakePendingRequests()

            guard shouldReconnect else { return }

            // Attempt reconnection (includes helper restart as last resort)
            if attemptReconnect() {
                continue  // reconnected — resume read loop
            }

            // All retries exhausted
            log("[helperClient] giving up reconnection")
            eventQueue.async { [weak self] in
                self?.onDisconnected?()
            }
            return
        }
    }

    private func attemptReconnect() -> Bool {
        guard let path = socketPath else { return false }

        // Phase 1: Try reconnecting to existing helper (it may have just restarted)
        for attempt in 1...Self.maxReconnectAttempts {
            guard shouldReconnect else { return false }

            // Exponential backoff: 500ms, 1s, 1.5s, 2s, 2.5s, 3s, 3s, ...
            let delayMs = min(attempt, 6) * 500
            usleep(UInt32(delayMs) * 1000)

            guard shouldReconnect else { return false }

            log("[helperClient] reconnect attempt \(attempt)/\(Self.maxReconnectAttempts)")

            do {
                try connectSocket(socketPath: path)
                syncSessions()
                log("[helperClient] reconnected with \(sessionCount) sessions")
                eventQueue.async { [weak self] in
                    self?.onReconnected?()
                }
                return true
            } catch {
                log("[helperClient] reconnect attempt \(attempt) failed: \(error)")
            }
        }

        // Phase 2: Socket reconnect exhausted — try restarting the helper process
        guard shouldReconnect else { return false }
        guard let restart = onRestartHelper, restart() else {
            log("[helperClient] helper restart not available or failed")
            return false
        }

        log("[helperClient] helper restarted — attempting final connect")
        // Snapshot stale sessions before sync clears them
        cacheLock.lock()
        let staleSessions = Array(sessionCache.keys)
        cacheLock.unlock()

        do {
            try connectSocket(socketPath: path)
            syncSessions()
            log("[helperClient] connected to restarted helper with \(sessionCount) sessions")
            // Notify about lost sessions (helper restart kills all PTY processes)
            for sessionId in staleSessions {
                if !hasSession(sessionId) {
                    eventQueue.async { [weak self] in
                        self?.onSessionExited?(sessionId)
                    }
                }
            }
            eventQueue.async { [weak self] in
                self?.onReconnected?()
            }
            return true
        } catch {
            log("[helperClient] post-restart connect failed: \(error)")
            return false
        }
    }

    private func handleResponse(_ response: IPCResponse) {
        if let requestId = response.id {
            // For ptyFdReady: receive the fd on this thread BEFORE signaling the caller
            if case .ptyFdReady = response.message {
                fdLock.lock()
                let fd = socketFD
                fdLock.unlock()
                receivedPtyFd = fd >= 0 ? c_recvfd(fd) : -1
                fdPassSemaphore.signal()
            }
            // Response to a pending request
            pendingLock.lock()
            let handler = pendingRequests.removeValue(forKey: requestId)
            pendingLock.unlock()
            handler?(response.message)
        } else {
            // Unsolicited event
            switch response.message {
            case .ptyOutput(let sessionId, let data, let offset):
                cacheLock.lock()
                sessionOffsets[sessionId] = offset
                cacheLock.unlock()
                eventQueue.async { [weak self] in
                    self?.onOutput?(sessionId, data)
                }
            case .sessionExited(let sessionId):
                cacheLock.lock()
                sessionCache.removeValue(forKey: sessionId)
                sessionOffsets.removeValue(forKey: sessionId)
                cacheLock.unlock()
                eventQueue.async { [weak self] in
                    self?.onSessionExited?(sessionId)
                }
            default:
                break
            }
        }
    }

    // MARK: - Request helpers

    private func nextRequestId() -> UInt64 {
        pendingLock.lock()
        defer { pendingLock.unlock() }
        requestIdCounter += 1
        return requestIdCounter
    }

    /// Send request and block until response arrives.
    private func sendRequest(_ request: HelperRequest, timeout: TimeInterval = 10) -> HelperMessage {
        let id = nextRequestId()
        let semaphore = DispatchSemaphore(value: 0)
        var result: HelperMessage = .ok

        pendingLock.lock()
        pendingRequests[id] = { msg in
            result = msg
            semaphore.signal()
        }
        pendingLock.unlock()

        do {
            writeLock.lock()
            fdLock.lock()
            let fd = socketFD
            fdLock.unlock()
            guard fd >= 0 else {
                writeLock.unlock()
                pendingLock.lock()
                pendingRequests.removeValue(forKey: id)
                pendingLock.unlock()
                log("[helperClient] send failed: not connected")
                return .ipcError("helper not connected")
            }
            try IPCFraming.writeFrame(IPCRequest(id: id, request: request), to: fd)
            writeLock.unlock()
        } catch {
            writeLock.unlock()
            pendingLock.lock()
            pendingRequests.removeValue(forKey: id)
            pendingLock.unlock()
            log("[helperClient] send error: \(error)")
            return .ipcError("helper communication failed")
        }

        let waitResult = semaphore.wait(timeout: .now() + timeout)
        if waitResult == .timedOut {
            pendingLock.lock()
            pendingRequests.removeValue(forKey: id)
            pendingLock.unlock()
            log("[helperClient] request timed out (id=\(id))")
            return .ipcError("helper request timed out")
        }
        return result
    }

    /// Send request without waiting for response (fire-and-forget).
    private func sendFireAndForget(_ request: HelperRequest) {
        do {
            let id = nextRequestId()
            writeLock.lock()
            fdLock.lock()
            let fd = socketFD
            fdLock.unlock()
            guard fd >= 0 else {
                writeLock.unlock()
                return
            }
            try IPCFraming.writeFrame(IPCRequest(id: id, request: request), to: fd)
            writeLock.unlock()
        } catch {
            writeLock.unlock()
            log("[helperClient] send error: \(error)")
        }
    }

    // MARK: - fd passing

    /// Received PTY master fd (set by readLoop when ptyFdReady arrives).
    private var receivedPtyFd: Int32 = -1
    private let fdPassSemaphore = DispatchSemaphore(value: 0)

    /// Request the PTY master fd from pty_helper. Returns the fd (>= 0) on success, -1 on failure.
    /// The fd is received inside the readLoop thread to avoid socket read races.
    /// Failure reason from the last requestPtyFd call (for caller diagnostics).
    public private(set) var lastFdPassError: String?

    public func requestPtyFd(sessionId: String) -> Int32 {
        lastFdPassError = nil
        receivedPtyFd = -1
        let response = sendRequest(.requestPtyFd(sessionId: sessionId))
        guard case .ptyFdReady = response else {
            lastFdPassError = "pty_helper returned \(response) instead of ptyFdReady — is pty_helper running the latest build?"
            return -1
        }
        // readLoop has already called c_recvfd and stored the result
        let result = fdPassSemaphore.wait(timeout: .now() + 5)
        if result == .timedOut {
            lastFdPassError = "semaphore timeout — c_recvfd in readLoop may have failed"
            return -1
        }
        if receivedPtyFd < 0 {
            lastFdPassError = "c_recvfd returned -1 (errno from recvmsg)"
        }
        return receivedPtyFd
    }

    /// Notify pty_helper that we're returning the PTY fd.
    public func releasePtyFd(sessionId: String) {
        _ = sendRequest(.releasePtyFd(sessionId: sessionId))
    }

    /// Send tee output to pty_helper for scrollback buffering (fire-and-forget).
    public func sendTeeOutput(sessionId: String, data: Data, offset: UInt64) {
        sendFireAndForget(.teeOutput(sessionId: sessionId, data: data, offset: offset))
    }

    // MARK: - PTYManagerProtocol

    @discardableResult
    public func createSession(sessionId: String, name: String, cols: Int, rows: Int,
                              sessionWorkDir: String?, sessionType: SessionType,
                              parentSessionId: String?, branchName: String?,
                              parentRepoPath: String?, parentBranchName: String?) -> (success: Bool, error: String?) {
        let response = sendRequest(.createSession(
            sessionId: sessionId, name: name, cols: cols, rows: rows,
            workDir: sessionWorkDir, sessionType: sessionType.rawValue,
            parentSessionId: parentSessionId, branchName: branchName,
            parentRepoPath: parentRepoPath, parentBranchName: parentBranchName))

        if case .ipcError(let reason) = response {
            return (false, reason)
        }
        if case .createResult(_, let success, _) = response, success {
            let detail = SessionDetail(
                sessionId: sessionId, name: name, cols: cols, rows: rows,
                cwd: nil, workDir: sessionWorkDir, sessionType: sessionType,
                parentSessionId: parentSessionId, branchName: branchName,
                parentRepoPath: parentRepoPath, parentBranchName: parentBranchName)
            cacheLock.lock()
            sessionCache[sessionId] = detail
            cacheLock.unlock()
            return (true, nil)
        }
        if case .createResult(_, _, let error) = response {
            return (false, error)
        }
        return (false, "unexpected response from helper")
    }

    public func write(_ data: Data, to sessionId: String) {
        sendFireAndForget(.writeInput(sessionId: sessionId, data: data))
    }

    public func resize(sessionId: String, cols: Int, rows: Int) {
        cacheLock.lock()
        if var detail = sessionCache[sessionId] {
            detail = SessionDetail(sessionId: detail.sessionId, name: detail.name,
                                   cols: cols, rows: rows,
                                   cwd: detail.cwd, workDir: detail.workDir,
                                   sessionType: detail.sessionType,
                                   parentSessionId: detail.parentSessionId,
                                   branchName: detail.branchName,
                                   parentRepoPath: detail.parentRepoPath,
                                   parentBranchName: detail.parentBranchName)
            sessionCache[sessionId] = detail
        }
        cacheLock.unlock()
        sendFireAndForget(.resize(sessionId: sessionId, cols: cols, rows: rows))
    }

    public func updateCwd(sessionId: String, directory: String) {
        cacheLock.lock()
        if var detail = sessionCache[sessionId] {
            detail = SessionDetail(sessionId: detail.sessionId, name: detail.name,
                                   cols: detail.cols, rows: detail.rows,
                                   cwd: directory, workDir: detail.workDir,
                                   sessionType: detail.sessionType,
                                   parentSessionId: detail.parentSessionId,
                                   branchName: detail.branchName,
                                   parentRepoPath: detail.parentRepoPath,
                                   parentBranchName: detail.parentBranchName)
            sessionCache[sessionId] = detail
        }
        cacheLock.unlock()
        sendFireAndForget(.updateCwd(sessionId: sessionId, directory: directory))
    }

    public func getCwd(sessionId: String) -> String? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return sessionCache[sessionId]?.cwd
    }

    public func rename(sessionId: String, name: String) {
        cacheLock.lock()
        if var detail = sessionCache[sessionId] {
            detail = SessionDetail(sessionId: detail.sessionId, name: name,
                                   cols: detail.cols, rows: detail.rows,
                                   cwd: detail.cwd, workDir: detail.workDir,
                                   sessionType: detail.sessionType,
                                   parentSessionId: detail.parentSessionId,
                                   branchName: detail.branchName,
                                   parentRepoPath: detail.parentRepoPath,
                                   parentBranchName: detail.parentBranchName)
            sessionCache[sessionId] = detail
        }
        cacheLock.unlock()
        sendFireAndForget(.rename(sessionId: sessionId, name: name))
    }

    public func destroy(sessionId: String) {
        cacheLock.lock()
        sessionCache.removeValue(forKey: sessionId)
        sessionOffsets.removeValue(forKey: sessionId)
        cacheLock.unlock()
        sendFireAndForget(.destroySession(sessionId: sessionId))
    }

    public func destroyAll() {
        cacheLock.lock()
        sessionCache.removeAll()
        sessionOffsets.removeAll()
        cacheLock.unlock()
        sendFireAndForget(.destroyAll)
    }

    public func drainReplay(sessionId: String) -> Data {
        let response = sendRequest(.replayDrain(sessionId: sessionId))
        if case .drainResult(_, let data) = response {
            return data
        }
        return Data()
    }

    public func replayIncremental(sessionId: String, sinceOffset: UInt64?) -> (data: Data, currentOffset: UInt64, isFull: Bool) {
        let response = sendRequest(.replayRequest(sessionId: sessionId, sinceOffset: sinceOffset))
        if case .replayResult(_, let data, let currentOffset, let isFull) = response {
            cacheLock.lock()
            sessionOffsets[sessionId] = currentOffset
            cacheLock.unlock()
            return (data, currentOffset, isFull)
        }
        return (Data(), 0, false)
    }

    public func currentOffset(sessionId: String) -> UInt64 {
        // Serve from local cache (updated by ptyOutput events)
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return sessionOffsets[sessionId] ?? 0
    }

    public func sessionInfoList() -> [PTYSessionInfo] {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return sessionCache.values.map { detail in
            PTYSessionInfo(sessionId: detail.sessionId, name: detail.name,
                           cols: detail.cols, rows: detail.rows,
                           sessionType: detail.sessionType,
                           cwd: detail.cwd ?? detail.workDir)
        }
    }

    public func slavePath(for sessionId: String) -> String? { nil }

    public func getWorkDir(sessionId: String) -> String? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return sessionCache[sessionId]?.workDir
    }

    public func getParentRepoPath(sessionId: String) -> String? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return sessionCache[sessionId]?.parentRepoPath
    }

    public func getParentBranchName(sessionId: String) -> String? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return sessionCache[sessionId]?.parentBranchName
    }

    public func getSize(sessionId: String) -> (cols: Int, rows: Int) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        let detail = sessionCache[sessionId]
        return (cols: detail?.cols ?? 80, rows: detail?.rows ?? 24)
    }

    public func getSessionType(sessionId: String) -> SessionType {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return sessionCache[sessionId]?.sessionType ?? .normal
    }

    public func getParentSessionId(sessionId: String) -> String? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return sessionCache[sessionId]?.parentSessionId
    }

    public func getBranchName(sessionId: String) -> String? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return sessionCache[sessionId]?.branchName
    }

    public func updateSessionType(sessionId: String, type: SessionType, branchName: String?) {
        cacheLock.lock()
        if var detail = sessionCache[sessionId] {
            detail = SessionDetail(sessionId: detail.sessionId, name: detail.name,
                                   cols: detail.cols, rows: detail.rows,
                                   cwd: detail.cwd, workDir: detail.workDir,
                                   sessionType: type,
                                   parentSessionId: detail.parentSessionId,
                                   branchName: branchName ?? detail.branchName,
                                   parentRepoPath: detail.parentRepoPath,
                                   parentBranchName: detail.parentBranchName)
            sessionCache[sessionId] = detail
        }
        cacheLock.unlock()
        sendFireAndForget(.updateSessionType(sessionId: sessionId, type: type.rawValue, branchName: branchName))
    }

    public func updateSessionParent(sessionId: String, parentSessionId: String?,
                                     parentRepoPath: String?, parentBranchName: String?) {
        cacheLock.lock()
        if var detail = sessionCache[sessionId] {
            detail = SessionDetail(sessionId: detail.sessionId, name: detail.name,
                                   cols: detail.cols, rows: detail.rows,
                                   cwd: detail.cwd, workDir: detail.workDir,
                                   sessionType: detail.sessionType,
                                   parentSessionId: parentSessionId,
                                   branchName: detail.branchName,
                                   parentRepoPath: parentRepoPath,
                                   parentBranchName: parentBranchName)
            sessionCache[sessionId] = detail
        }
        cacheLock.unlock()
        sendFireAndForget(.updateSessionParent(sessionId: sessionId, parentSessionId: parentSessionId,
                                               parentRepoPath: parentRepoPath, parentBranchName: parentBranchName))
    }

    public func hasSession(_ sessionId: String) -> Bool {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return sessionCache[sessionId] != nil
    }

    public func switchToBufferOnly() {
        sendFireAndForget(.switchToBufferOnly)
    }

    public func switchToLive() {
        sendFireAndForget(.switchToLive)
    }

    public func defaultSessionId() -> String? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return sessionCache.keys.sorted().first
    }

    // MARK: - Helper lifecycle

    /// Fetch live session list from helper and populate local cache.
    public func syncSessions() {
        let response = sendRequest(.listSessions)
        if case .sessionList(let sessions) = response {
            cacheLock.lock()
            sessionCache.removeAll()
            for detail in sessions {
                sessionCache[detail.sessionId] = detail
            }
            cacheLock.unlock()
            log("[helperClient] synced \(sessions.count) sessions from helper")
        }
    }

    public func sendPing() -> Bool {
        let response = sendRequest(.ping)
        if case .pong = response { return true }
        return false
    }

    public func checkVersion() -> Bool {
        let response = sendRequest(.version)
        if case .versionResult(let version) = response {
            return version == ipcProtocolVersion
        }
        return false
    }

    public func sendShutdown() {
        sendFireAndForget(.shutdown)
    }

    public enum HelperClientError: Error {
        case socketCreationFailed(Int32)
        case pathTooLong
        case connectFailed(Int32)
    }
}

#endif
