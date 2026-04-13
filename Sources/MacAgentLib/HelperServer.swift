import Foundation
import RemoteDevCore
import CPosixHelpers

#if os(macOS)

/// Unix domain socket server that owns PTYManager and serves IPC requests.
///
/// Supports multiple concurrent clients. The first client that sends `.switchToLive`
/// becomes the "primary" client and receives push events (ptyOutput, sessionExited).
/// Additional clients (e.g. Mac CLI direct-connect) can connect simultaneously
/// for fd-pass and control operations without disrupting the primary.
public final class HelperServer {
    private let socketPath: String
    private let ptyManager = PTYManager()
    private var listenFD: Int32 = -1

    /// Per-client state.
    private struct ClientState {
        let conn: ClientConnection
        var isLive: Bool = false
        /// Sessions whose PTY master fd has been passed to this client via SCM_RIGHTS.
        var fdPassedSessions: Set<String> = []
    }

    /// All connected clients, keyed by fd.
    private var clients: [Int32: ClientState] = [:]
    /// Sessions that exited while no live clients were connected.
    /// Drained and delivered on the next `.switchToLive`.
    private var pendingExits: Set<String> = []
    private let clientsLock = NSLock()
    private var idleTimer: DispatchSourceTimer?
    private let idleTimeout: TimeInterval

    /// If false, checkIdleShutdown will not call exit() — used in tests.
    public var exitOnIdle = true

    /// Called when the server would exit due to idle timeout or shutdown request.
    /// If set, called instead of exit(). Used in tests.
    public var onShutdown: (() -> Void)?

    public init(socketPath: String, workDir: String?, idleTimeout: TimeInterval = 60) {
        self.socketPath = socketPath
        self.idleTimeout = idleTimeout
        ptyManager.workDir = workDir

        ptyManager.onOutput = { [weak self] sessionId, data in
            guard let self else { return }
            let offset = self.ptyManager.currentOffset(sessionId: sessionId)
            let response = IPCResponse(id: nil, message: .ptyOutput(sessionId: sessionId, data: data, offset: offset))
            // Send to all live clients
            self.clientsLock.lock()
            let liveConns = self.clients.values.filter { $0.isLive }.map { $0.conn }
            self.clientsLock.unlock()
            for conn in liveConns {
                conn.safeWrite { fd in try? IPCFraming.writeFrame(response, to: fd) }
            }
        }

        ptyManager.onSessionExited = { [weak self] sessionId in
            guard let self else { return }
            let response = IPCResponse(id: nil, message: .sessionExited(sessionId: sessionId))
            self.clientsLock.lock()
            let liveConns = self.clients.values.filter { $0.isLive }.map { $0.conn }
            if liveConns.isEmpty {
                self.pendingExits.insert(sessionId)
                self.clientsLock.unlock()
                log("[helperServer] session \(sessionId) exited with no live clients — queued")
            } else {
                self.pendingExits.remove(sessionId)
                self.clientsLock.unlock()
                for conn in liveConns {
                    conn.safeWrite { fd in try? IPCFraming.writeFrame(response, to: fd) }
                }
            }
            self.checkIdleShutdown()
        }
    }

    // MARK: - Server lifecycle

    public func start() throws {
        // Remove stale socket
        unlink(socketPath)

        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else {
            throw HelperServerError.socketCreationFailed(errno)
        }
        _ = fcntl(listenFD, F_SETFD, FD_CLOEXEC)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            throw HelperServerError.pathTooLong
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
                pathBytes.withUnsafeBufferPointer { src in
                    _ = memcpy(dest, src.baseAddress!, src.count)
                }
            }
        }

        let addrLen = socklen_t(MemoryLayout<sa_family_t>.size + pathBytes.count)
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(listenFD, sockPtr, addrLen)
            }
        }
        guard bindResult == 0 else {
            throw HelperServerError.bindFailed(errno)
        }

        // Set socket permissions to 0600
        chmod(socketPath, 0o600)

        guard listen(listenFD, 5) == 0 else {
            throw HelperServerError.listenFailed(errno)
        }

        log("[helperServer] listening on \(socketPath)")
        startAcceptLoop()
        resetIdleTimer()
    }

    public func shutdown() {
        log("[helperServer] shutting down")
        cancelIdleTimer()
        ptyManager.destroyAll()

        clientsLock.lock()
        pendingExits.removeAll()
        let allConns = clients.values.map { $0.conn }
        clients.removeAll()
        clientsLock.unlock()
        for conn in allConns { conn.closeOnce() }

        if listenFD >= 0 {
            close(listenFD)
            listenFD = -1
        }
        unlink(socketPath)
    }

    // MARK: - Accept loop

    private func startAcceptLoop() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            log("[helperServer] accept loop started")
            while let self = self, self.listenFD >= 0 {
                let fd = accept(self.listenFD, nil, nil)
                if fd < 0 {
                    if errno == EINTR { continue }
                    if self.listenFD < 0 { break }  // shutdown
                    log("[helperServer] accept failed: \(errno)")
                    continue
                }

                // Prevent child processes (forkpty shells) from inheriting this fd
                _ = fcntl(fd, F_SETFD, FD_CLOEXEC)

                log("[helperServer] client connected (fd=\(fd))")

                // Register client with thread-safe connection wrapper
                let conn = ClientConnection(fd: fd)
                self.clientsLock.lock()
                self.clients[fd] = ClientState(conn: conn)
                self.clientsLock.unlock()

                self.cancelIdleTimer()

                // Handle each client on its own thread so accept loop is not blocked
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    self?.handleClient(conn: conn)
                }
            }
            log("[helperServer] accept loop exited")
        }
    }

    // MARK: - Client handling

    private func handleClient(conn: ClientConnection) {
        let fd = conn.fd
        while true {
            do {
                guard let request = try IPCFraming.readFrame(IPCRequest.self, from: fd) else {
                    break  // EOF — client disconnected
                }
                if let response = processRequest(request, conn: conn) {
                    conn.safeWrite { fd in try? IPCFraming.writeFrame(response, to: fd) }
                }
            } catch {
                log("[helperServer] client error (fd=\(fd)): \(error)")
                break
            }
        }

        // Client disconnected — clean up
        clientsLock.lock()
        let state = clients.removeValue(forKey: fd)
        let hasLiveClients = clients.values.contains { $0.isLive }
        clientsLock.unlock()
        conn.closeOnce()

        // Resume any sessions whose fd was passed to this client (crash recovery)
        if let state {
            for sessionId in state.fdPassedSessions {
                ptyManager.resumeOutput(for: sessionId)
                log("[helperServer] crash recovery: resumed DispatchSource for session \(sessionId)")
            }

            if state.isLive {
                log("[helperServer] live client disconnected (fd=\(fd))")
                if !hasLiveClients {
                    // No more live clients — switch to buffer-only
                    ptyManager.switchToBufferOnly()
                    log("[helperServer] switched to buffer-only (no live clients)")
                }
            } else {
                log("[helperServer] client disconnected (fd=\(fd))")
            }
        }

        resetIdleTimer()
    }

    // MARK: - Request processing

    private func processRequest(_ envelope: IPCRequest, conn: ClientConnection) -> IPCResponse? {
        let id = envelope.id
        let clientFD = conn.fd
        switch envelope.request {
        case .createSession(let sessionId, let name, let cols, let rows,
                            let workDir, let sessionType, let parentSessionId,
                            let branchName, let parentRepoPath, let parentBranchName):
            let sType = sessionType.flatMap { SessionType(rawValue: $0) } ?? .normal
            let result = ptyManager.createSession(
                sessionId: sessionId, name: name, cols: cols, rows: rows,
                sessionWorkDir: workDir, sessionType: sType,
                parentSessionId: parentSessionId, branchName: branchName,
                parentRepoPath: parentRepoPath, parentBranchName: parentBranchName)
            return IPCResponse(id: id, message: .createResult(sessionId: sessionId, success: result.success, error: result.error))

        case .destroySession(let sessionId):
            clientsLock.lock()
            pendingExits.remove(sessionId)
            clientsLock.unlock()
            ptyManager.destroy(sessionId: sessionId)
            checkIdleShutdown()
            return nil

        case .destroyAll:
            clientsLock.lock()
            pendingExits.removeAll()
            clientsLock.unlock()
            ptyManager.destroyAll()
            checkIdleShutdown()
            return nil

        case .writeInput(let sessionId, let data):
            ptyManager.write(data, to: sessionId)
            return nil

        case .resize(let sessionId, let cols, let rows):
            ptyManager.resize(sessionId: sessionId, cols: cols, rows: rows)
            return nil

        case .rename(let sessionId, let name):
            ptyManager.rename(sessionId: sessionId, name: name)
            return nil

        case .updateCwd(let sessionId, let directory):
            ptyManager.updateCwd(sessionId: sessionId, directory: directory)
            return nil

        case .updateSessionType(let sessionId, let type, let branchName):
            let sType = SessionType(rawValue: type) ?? .normal
            ptyManager.updateSessionType(sessionId: sessionId, type: sType, branchName: branchName)
            return nil

        case .updateSessionParent(let sessionId, let parentSessionId, let parentRepoPath, let parentBranchName):
            ptyManager.updateSessionParent(sessionId: sessionId, parentSessionId: parentSessionId,
                                           parentRepoPath: parentRepoPath, parentBranchName: parentBranchName)
            return nil

        case .switchToBufferOnly:
            clientsLock.lock()
            clients[clientFD]?.isLive = false
            let hasLiveClients = clients.values.contains { $0.isLive }
            clientsLock.unlock()
            if !hasLiveClients {
                ptyManager.switchToBufferOnly()
            }
            return nil

        case .switchToLive:
            clientsLock.lock()
            clients[clientFD]?.isLive = true
            let pending = pendingExits
            pendingExits.removeAll()
            let allLiveConns = clients.values.filter { $0.isLive }.map { $0.conn }
            clientsLock.unlock()
            ptyManager.switchToLive()
            for exitedId in pending {
                let exitResponse = IPCResponse(id: nil, message: .sessionExited(sessionId: exitedId))
                for liveConn in allLiveConns {
                    liveConn.safeWrite { fd in try? IPCFraming.writeFrame(exitResponse, to: fd) }
                }
                ptyManager.destroy(sessionId: exitedId)
                log("[helperServer] delivered pending sessionExited for \(exitedId)")
            }
            if !pending.isEmpty { checkIdleShutdown() }
            return nil

        case .replayRequest(let sessionId, let sinceOffset):
            let result = ptyManager.replayIncremental(sessionId: sessionId, sinceOffset: sinceOffset)
            return IPCResponse(id: id, message: .replayResult(
                sessionId: sessionId, data: result.data,
                currentOffset: result.currentOffset, isFull: result.isFull))

        case .replayDrain(let sessionId):
            let data = ptyManager.drainReplay(sessionId: sessionId)
            return IPCResponse(id: id, message: .drainResult(sessionId: sessionId, data: data))

        case .currentOffset(let sessionId):
            let offset = ptyManager.currentOffset(sessionId: sessionId)
            return IPCResponse(id: id, message: .offsetResult(sessionId: sessionId, offset: offset))

        case .listSessions:
            let details = buildSessionDetails()
            return IPCResponse(id: id, message: .sessionList(sessions: details))

        case .ping:
            return IPCResponse(id: id, message: .pong)

        case .version:
            return IPCResponse(id: id, message: .versionResult(version: ipcProtocolVersion))

        case .shutdown:
            log("[helperServer] shutdown requested by client")
            let resp = IPCResponse(id: id, message: .ok)
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.shutdown()
                self?.onShutdown?()
                if self?.exitOnIdle == true {
                    exit(0)
                }
            }
            return resp

        // fd passing: pass PTY master fd to client for zero-latency direct I/O
        case .requestPtyFd(let sessionId):
            guard let masterFD = ptyManager.masterFD(for: sessionId), masterFD >= 0 else {
                log("[helperServer] requestPtyFd declined: session \(sessionId) masterFD unavailable")
                return IPCResponse(id: id, message: .ok)
            }
            // Suspend DispatchSource before passing fd — only one reader at a time
            ptyManager.suspendOutput(for: sessionId)
            clientsLock.lock()
            clients[clientFD]?.fdPassedSessions.insert(sessionId)
            clientsLock.unlock()
            // Atomically send ptyFdReady + fd under per-client lock to prevent
            // other ptyOutput frames from interleaving on the socket.
            let response = IPCResponse(id: id, message: .ptyFdReady(sessionId: sessionId))
            do {
                let sendResult = try conn.safeWrite { fd -> Int32 in
                    try IPCFraming.writeFrame(response, to: fd)
                    return c_sendfd(fd, masterFD)
                }
                if sendResult == nil {
                    // Connection already closed
                    log("[helperServer] client closed before fd-pass for session \(sessionId)")
                    ptyManager.resumeOutput(for: sessionId)
                    clientsLock.lock()
                    clients[clientFD]?.fdPassedSessions.remove(sessionId)
                    clientsLock.unlock()
                } else if sendResult! < 0 {
                    // writeFrame succeeded but c_sendfd failed — protocol desync.
                    // Client will call c_recvfd() which consumes 1 byte of the next
                    // IPC frame, breaking all subsequent framing. Must close client.
                    log("[helperServer] c_sendfd failed for session \(sessionId), errno=\(errno) — closing client (desync)")
                    ptyManager.resumeOutput(for: sessionId)
                    clientsLock.lock()
                    clients[clientFD]?.fdPassedSessions.remove(sessionId)
                    clientsLock.unlock()
                    conn.closeOnce()
                } else {
                    log("[helperServer] fd passed for session \(sessionId) to client fd=\(clientFD)")
                }
            } catch {
                // writeFrame itself failed — no desync since c_sendfd was never called
                log("[helperServer] writeFrame failed for ptyFdReady: \(error)")
                ptyManager.resumeOutput(for: sessionId)
                clientsLock.lock()
                clients[clientFD]?.fdPassedSessions.remove(sessionId)
                clientsLock.unlock()
            }
            return nil  // response already sent above

        case .teeOutput(let sessionId, let data, _):
            ptyManager.appendTeeOutput(data, for: sessionId)
            return nil

        case .releasePtyFd(let sessionId):
            clientsLock.lock()
            let removed = clients[clientFD]?.fdPassedSessions.remove(sessionId)
            clientsLock.unlock()
            if removed != nil {
                ptyManager.resumeOutput(for: sessionId)
                log("[helperServer] fd released for session \(sessionId), DispatchSource resumed")
            }
            return IPCResponse(id: id, message: .ok)

        case .updateMaxSessions(let maxSessions):
            ptyManager.updateMaxSessions(maxSessions)
            log("[helperServer] maxSessions updated to \(ptyManager.maxSessions)")
            return IPCResponse(id: id, message: .ok)
        }
    }

    private func buildSessionDetails() -> [SessionDetail] {
        let infos = ptyManager.sessionInfoList()
        return infos.map { info in
            SessionDetail(
                sessionId: info.sessionId,
                name: info.name,
                cols: info.cols,
                rows: info.rows,
                cwd: ptyManager.getCwd(sessionId: info.sessionId),
                workDir: ptyManager.getWorkDir(sessionId: info.sessionId),
                sessionType: ptyManager.getSessionType(sessionId: info.sessionId),
                parentSessionId: ptyManager.getParentSessionId(sessionId: info.sessionId),
                branchName: ptyManager.getBranchName(sessionId: info.sessionId),
                parentRepoPath: ptyManager.getParentRepoPath(sessionId: info.sessionId),
                parentBranchName: ptyManager.getParentBranchName(sessionId: info.sessionId))
        }
    }

    // MARK: - Idle timeout

    private func resetIdleTimer() {
        cancelIdleTimer()

        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + idleTimeout)
        timer.setEventHandler { [weak self] in
            self?.checkIdleShutdown()
        }
        timer.resume()
        idleTimer = timer
    }

    private func cancelIdleTimer() {
        idleTimer?.cancel()
        idleTimer = nil
    }

    private func checkIdleShutdown() {
        clientsLock.lock()
        let hasClients = !clients.isEmpty
        let pending = pendingExits
        clientsLock.unlock()

        let sessionCount = ptyManager.sessionCount
        let effectivelyEmpty = sessionCount == 0
            || (!pending.isEmpty && sessionCount == pending.count)

        if !hasClients && effectivelyEmpty {
            if !pending.isEmpty {
                clientsLock.lock()
                let zombies = pendingExits
                pendingExits.removeAll()
                clientsLock.unlock()
                for sid in zombies { ptyManager.destroy(sessionId: sid) }
            }
            log("[helperServer] no clients and no sessions — exiting")
            shutdown()
            onShutdown?()
            if exitOnIdle {
                exit(0)
            }
        }
    }

    public enum HelperServerError: Error {
        case socketCreationFailed(Int32)
        case pathTooLong
        case bindFailed(Int32)
        case listenFailed(Int32)
    }
}

#endif
