import Foundation
import RemoteDevCore

#if os(macOS)

/// Accepts local Unix socket connections from `termonmac sessions` / `termonmac attach`.
/// Runs alongside AgentService and provides session listing and (future) attach I/O.
///
/// Supports multiple concurrent clients. Each client can optionally attach to a session,
/// becoming the "attached client" for that session and receiving push events (output,
/// sessionExited, takenOver). Query-only clients (e.g. `termonmac sessions`) connect,
/// request data, and disconnect without affecting attached clients.
public final class LocalSocketServer {
    private let socketPath: String
    private var listenFD: Int32 = -1

    /// Per-client state tracked by the server.
    private struct ClientState {
        let conn: ClientConnection
        /// The session this client is attached to, or nil for query-only clients.
        var attachedSessionId: String?
    }

    /// All connected clients, keyed by fd.
    private var clients: [Int32: ClientState] = [:]
    private let clientsLock = NSLock()

    /// Called to get the current session list. Set by AgentService.
    public var onListSessions: (() -> [LocalSessionInfo])?
    /// Called when Mac client creates a new session. Returns (sessionId, error).
    /// Parameters: (name, cols, rows, workDir)
    public var onCreateSession: ((String, Int, Int, String) -> (String?, String?))?
    /// Called when Mac client attaches to a session. Returns (success, error, replayData, helperSocketPath).
    public var onAttach: ((String) -> (Bool, String?, Data?, String?))?
    /// Called when Mac client sends input to a session.
    public var onInput: ((String, Data) -> Void)?
    /// Called when Mac client resizes a session.
    public var onResize: ((String, Int, Int) -> Void)?
    /// Called when an attached client detaches or disconnects.
    /// Parameter: the sessionId that was attached, or nil if the client was not attached.
    public var onDetach: ((_ sessionId: String?) -> Void)?
    /// Called when a client requests to kill (destroy) a session.
    public var onKillSession: ((_ sessionId: String) -> Void)?
    /// Called when a client requests to rename a session.
    public var onRenameSession: ((_ sessionId: String, _ name: String) -> Void)?

    public init(socketPath: String) {
        self.socketPath = socketPath
    }

    // MARK: - Lifecycle

    public func start() throws {
        unlink(socketPath)

        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else {
            throw LocalSocketError.socketCreationFailed(errno)
        }
        _ = fcntl(listenFD, F_SETFD, FD_CLOEXEC)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            throw LocalSocketError.pathTooLong
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
            throw LocalSocketError.bindFailed(errno)
        }
        chmod(socketPath, 0o600)

        guard listen(listenFD, 5) == 0 else {
            throw LocalSocketError.listenFailed(errno)
        }

        log("[localSocket] listening on \(socketPath)")
        startAcceptLoop()
    }

    public func shutdown() {
        let fd = listenFD
        listenFD = -1
        if fd >= 0 { close(fd) }

        clientsLock.lock()
        let allConns = clients.values.map { $0.conn }
        clients.removeAll()
        clientsLock.unlock()
        for conn in allConns { conn.closeOnce() }

        unlink(socketPath)
    }

    // MARK: - Accept loop

    private func startAcceptLoop() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            while let self = self, self.listenFD >= 0 {
                let fd = accept(self.listenFD, nil, nil)
                if fd < 0 {
                    if errno == EINTR { continue }
                    if self.listenFD < 0 { break }
                    continue
                }
                _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
                log("[localSocket] client connected (fd=\(fd))")

                // Register client with thread-safe connection wrapper
                let conn = ClientConnection(fd: fd)
                self.clientsLock.lock()
                self.clients[fd] = ClientState(conn: conn, attachedSessionId: nil)
                self.clientsLock.unlock()

                // Handle each client on its own thread so accept loop is not blocked
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    self?.handleClient(conn: conn)
                }
            }
        }
    }

    // MARK: - Client handling

    private func handleClient(conn: ClientConnection) {
        let fd = conn.fd
        while true {
            do {
                guard let request = try IPCFraming.readFrame(LocalIPC.Request.self, from: fd) else {
                    break
                }
                let (response, postAction) = processRequest(request, clientFD: fd)
                if let response {
                    conn.safeWrite { fd in try? IPCFraming.writeFrame(response, to: fd) }
                }
                postAction?()
            } catch {
                log("[localSocket] client error: \(error)")
                break
            }
        }

        // Clean up: remove client and fire onDetach if it was attached
        clientsLock.lock()
        let state = clients.removeValue(forKey: fd)
        clientsLock.unlock()
        conn.closeOnce()

        if let sessionId = state?.attachedSessionId {
            onDetach?(sessionId)
            log("[localSocket] attached client disconnected (session=\(sessionId))")
        } else {
            log("[localSocket] query client disconnected")
        }
    }

    private func processRequest(_ envelope: LocalIPC.Request, clientFD: Int32) -> (LocalIPC.Response?, (() -> Void)?) {
        let id = envelope.id
        switch envelope.message {
        case .listSessions:
            let sessions = onListSessions?() ?? []
            return (LocalIPC.Response(id: id, message: .sessionList(sessions: sessions)), nil)

        case .createSession(let name, let cols, let rows, let workDir):
            let (sessionId, error) = onCreateSession?(name, cols, rows, workDir) ?? (nil, "not supported")
            return (LocalIPC.Response(id: id, message: .createSessionResult(sessionId: sessionId, error: error)), nil)

        case .attach(let sessionId):
            // If another client is already attached to this session, kick it
            clientsLock.lock()
            let previousClient = clients.first(where: { $0.key != clientFD && $0.value.attachedSessionId == sessionId })
            if let prev = previousClient {
                clients[prev.key]?.attachedSessionId = nil  // clear so onDetach won't reset controller
                let prevConn = prev.value.conn
                clientsLock.unlock()
                prevConn.closeOnce()  // kicks the old client's handleClient loop
                log("[localSocket] kicked previous attach client (fd=\(prevConn.fd)) for session \(sessionId)")
            } else {
                clientsLock.unlock()
            }

            let (success, error, replayData, helperSocketPath) = onAttach?(sessionId) ?? (false, "not supported", nil, nil)
            if success {
                // Mark this client as attached to the session
                clientsLock.lock()
                clients[clientFD]?.attachedSessionId = sessionId
                clientsLock.unlock()
            }
            let response = LocalIPC.Response(id: id, message: .attachResult(success: success, error: error, helperSocketPath: helperSocketPath))
            // Push replay AFTER attachResult so client reads the response first (proxy mode only)
            let postAction: (() -> Void)? = (success && replayData != nil && helperSocketPath == nil) ? { [weak self] in
                self?.pushEvent(.output(sessionId: sessionId, data: replayData!))
            } : nil
            return (response, postAction)

        case .input(let sessionId, let data):
            onInput?(sessionId, data)
            return (nil, nil)

        case .resize(let sessionId, let cols, let rows):
            onResize?(sessionId, cols, rows)
            return (nil, nil)

        case .detach:
            // Clear attached state; onDetach fires when client disconnects in handleClient.
            clientsLock.lock()
            let sessionId = clients[clientFD]?.attachedSessionId
            clients[clientFD]?.attachedSessionId = nil
            clientsLock.unlock()
            // Fire detach immediately so AgentService can reclaim before client closes socket
            if let sessionId { onDetach?(sessionId) }
            return (LocalIPC.Response(id: id, message: .ok), nil)

        case .forceDetach(let sessionId):
            // Kick the client attached to this session (if any)
            clientsLock.lock()
            let target = clients.first(where: { $0.value.attachedSessionId == sessionId })
            if let target {
                clients[target.key]?.attachedSessionId = nil
                let targetConn = target.value.conn
                clientsLock.unlock()
                targetConn.closeOnce()
                onDetach?(sessionId)
                log("[localSocket] force-detached session \(sessionId)")
            } else {
                clientsLock.unlock()
            }
            return (LocalIPC.Response(id: id, message: .ok), nil)

        case .killSession(let sessionId):
            // If the session is Mac-attached, kick the attached client first
            clientsLock.lock()
            let target = clients.first(where: { $0.value.attachedSessionId == sessionId })
            if let target {
                clients[target.key]?.attachedSessionId = nil
                let targetConn = target.value.conn
                clientsLock.unlock()
                targetConn.closeOnce()
            } else {
                clientsLock.unlock()
            }
            onKillSession?(sessionId)
            return (LocalIPC.Response(id: id, message: .ok), nil)

        case .renameSession(let sessionId, let name):
            onRenameSession?(sessionId, name)
            return (LocalIPC.Response(id: id, message: .ok), nil)
        }
    }

    // MARK: - Push events to attached clients

    /// Push an event to the client attached to the given session.
    public func pushEvent(_ message: LocalIPC.ResponseMessage, sessionId: String) {
        clientsLock.lock()
        let targetConn = clients.first(where: { $0.value.attachedSessionId == sessionId })?.value.conn
        clientsLock.unlock()
        guard let conn = targetConn else { return }
        let response = LocalIPC.Response(id: nil, message: message)
        conn.safeWrite { fd in try? IPCFraming.writeFrame(response, to: fd) }
    }

    /// Push an event to all attached clients (legacy compatibility).
    public func pushEvent(_ message: LocalIPC.ResponseMessage) {
        clientsLock.lock()
        let attachedConns = clients.filter { $0.value.attachedSessionId != nil }.map { $0.value.conn }
        clientsLock.unlock()
        let response = LocalIPC.Response(id: nil, message: message)
        for conn in attachedConns {
            conn.safeWrite { fd in try? IPCFraming.writeFrame(response, to: fd) }
        }
    }

    public enum LocalSocketError: Error {
        case socketCreationFailed(Int32)
        case pathTooLong
        case bindFailed(Int32)
        case listenFailed(Int32)
    }
}

#endif
