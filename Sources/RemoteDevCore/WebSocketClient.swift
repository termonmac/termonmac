import Foundation

public final class WebSocketClient: NSObject, URLSessionWebSocketDelegate, WebSocketProtocol {
    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var continuation: AsyncThrowingStream<String, Error>.Continuation?

    private var connectContinuation: CheckedContinuation<Void, Error>?

    /// Single lock protecting all shared mutable state (task, session,
    /// continuation, connectContinuation, _onDisconnect).
    /// Pattern: snapshot values under lock, perform side-effects outside.
    private let lock = NSLock()

    private var _onDisconnect: (() -> Void)?
    public var onDisconnect: (() -> Void)? {
        get { lock.withLock { _onDisconnect } }
        set { lock.withLock { _onDisconnect = newValue } }
    }

    private var _lastCloseCode: Int?
    public var lastCloseCode: Int? {
        get { lock.withLock { _lastCloseCode } }
    }

    /// Maximum time to wait for WebSocket upgrade (TCP connect + TLS + HTTP 101).
    /// Prevents connect() from hanging forever if the server silently drops SYN.
    public static let connectTimeout: TimeInterval = 30

    public override init() {
        super.init()
    }

    /// URLSession configuration for long-lived WebSocket connections.
    /// Both timeouts disabled — relay heartbeats handle keepalive.
    static func makeSessionConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.default
        config.shouldUseExtendedBackgroundIdleMode = true
        // No resource timeout — CF Durable Objects handle WebSocket keepalive
        // via automatic ping/pong. The previous 10s value caused premature
        // disconnects (ENOTCONN ~2-3s after connect).
        config.timeoutIntervalForResource = 0
        // Disable per-request timeout for long-lived WebSocket connections.
        // Default 60s can cause premature disconnects during brief relay delays.
        config.timeoutIntervalForRequest = 0
        return config
    }

    public func connect(url: URL) async throws {
        let config = Self.makeSessionConfiguration()
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        let task = session.webSocketTask(with: url)
        lock.withLock {
            self.session = session
            self.task = task
            self._lastCloseCode = nil
        }
        try await connectWithTimeout(task: task)
    }

    public func connect(request: URLRequest) async throws {
        let config = Self.makeSessionConfiguration()
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        let task = session.webSocketTask(with: request)
        lock.withLock {
            self.session = session
            self.task = task
            self._lastCloseCode = nil
        }
        try await connectWithTimeout(task: task)
    }

    /// Start the WebSocket task and wait for the upgrade, with a timeout guard.
    /// Without this, connect() can hang forever if the server silently drops
    /// the TCP SYN (e.g. Cloudflare rate-limit) because URLSession has no
    /// resource/request timeout (both set to 0 for long-lived connections).
    ///
    /// Uses a GCD timer instead of Task.sleep for the timeout because the
    /// Swift cooperative thread pool can become exhausted during rapid
    /// reconnect loops, preventing Task-based timers from ever firing.
    private func connectWithTimeout(task: URLSessionWebSocketTask) async throws {
        log("[ws] connectWithTimeout: starting (timeout=\(Self.connectTimeout)s)")
        // GCD-based timeout — independent of the cooperative thread pool
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + Self.connectTimeout)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            log("[ws] connect timeout after \(Self.connectTimeout)s — forcing disconnect")
            self.lock.lock()
            let cont = self.connectContinuation
            self.connectContinuation = nil
            let t = self.task
            self.task = nil
            let s = self.session
            self.session = nil
            self.lock.unlock()
            cont?.resume(throwing: WebSocketError.connectTimedOut)
            t?.cancel()
            s?.invalidateAndCancel()
        }
        timer.resume()

        defer { timer.cancel() }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            self.lock.lock()
            self.connectContinuation = cont
            self.lock.unlock()
            task.resume()
        }
    }

    /// Send timeout — same rationale as connect timeout.
    public static let sendTimeout: TimeInterval = 10

    public func send(_ message: String) async throws {
        let currentTask: URLSessionWebSocketTask? = lock.withLock { self.task }
        guard let currentTask else { throw WebSocketError.notConnected }

        // GCD-based timeout for send — the cooperative pool may be exhausted,
        // so Task.sleep-based timeouts cannot be relied upon.
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let finished = NSLock()
            var resumed = false

            let timer = DispatchSource.makeTimerSource(queue: .global())
            timer.schedule(deadline: .now() + Self.sendTimeout)
            timer.setEventHandler {
                finished.lock()
                guard !resumed else { finished.unlock(); return }
                resumed = true
                finished.unlock()
                log("[ws] send timeout after \(Self.sendTimeout)s")
                cont.resume(throwing: WebSocketError.sendTimedOut)
            }
            timer.resume()

            currentTask.send(.string(message)) { error in
                timer.cancel()
                finished.lock()
                guard !resumed else { finished.unlock(); return }
                resumed = true
                finished.unlock()
                if let error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume()
                }
            }
        }
    }

    public func receive() -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            self.lock.lock()
            self.continuation = continuation
            self.lock.unlock()
            self.readLoop()
        }
    }

    /// All continuation access goes through self.continuation under lock.
    /// finish() uses "take under lock" (atomically nil + snapshot) so exactly
    /// one thread ever calls finish — preventing the concurrent-dealloc crash
    /// in AsyncThrowingStream._Storage.
    private func readLoop() {
        let currentTask: URLSessionWebSocketTask? = lock.withLock { self.task }
        guard let currentTask else {
            let streamCont: AsyncThrowingStream<String, Error>.Continuation? = lock.withLock {
                let c = self.continuation
                self.continuation = nil
                return c
            }
            streamCont?.finish(throwing: WebSocketError.notConnected)
            return
        }
        currentTask.receive { [weak self] result in
            switch result {
            case .success(let message):
                if let self {
                    switch message {
                    case .string(let text):
                        self.lock.withLock { _ = self.continuation?.yield(text) }
                    case .data(let data):
                        if let text = String(data: data, encoding: .utf8) {
                            self.lock.withLock { _ = self.continuation?.yield(text) }
                        }
                    @unknown default:
                        break
                    }
                    self.readLoop()
                }
            case .failure(let error):
                guard let self else { return }
                // Atomically take the continuation — only the winner calls finish
                let (streamCont, response, disconnectHandler) = self.lock.withLock {
                    let c = self.continuation
                    self.continuation = nil
                    return (c, self.task?.response, self._onDisconnect)
                }
                guard let streamCont else { return }
                // Check if the server returned an HTTP error (e.g. 403) instead of upgrading
                if let httpResponse = response as? HTTPURLResponse,
                   httpResponse.statusCode != 101 {
                    streamCont.finish(throwing: WebSocketError.httpUpgradeFailed(statusCode: httpResponse.statusCode))
                } else {
                    streamCont.finish(throwing: error)
                }
                disconnectHandler?()
            }
        }
    }

    public func disconnect() {
        lock.lock()
        let connectCont = connectContinuation
        connectContinuation = nil
        let t = task
        task = nil
        let streamCont = continuation
        continuation = nil
        let s = session
        session = nil
        lock.unlock()

        connectCont?.resume(throwing: CancellationError())
        t?.cancel(with: .goingAway, reason: nil)
        streamCont?.finish()
        s?.invalidateAndCancel()
    }

    // MARK: - URLSessionWebSocketDelegate

    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        lock.lock()
        let cont = connectContinuation
        connectContinuation = nil
        lock.unlock()
        cont?.resume()
    }

    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let reasonStr = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "none"
        log("[ws] didCloseWith code=\(closeCode.rawValue) reason=\(reasonStr)")
        lock.lock()
        _lastCloseCode = closeCode.rawValue
        let cont = continuation
        continuation = nil
        let disconnectHandler = _onDisconnect
        lock.unlock()
        guard let cont else { return }
        cont.finish(throwing: WebSocketError.serverClose(code: closeCode.rawValue, reason: reasonStr))
        disconnectHandler?()
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        if let error {
            log("[ws] didCompleteWithError: \(error)")
        }
        // Safety net: if the receive stream is still active when the task
        // completes, finish it here. Normally readLoop's task.receive callback
        // handles this, but if the callback doesn't fire (edge case), the
        // stream would hang forever — preventing reconnection.
        lock.lock()
        let streamCont = continuation
        continuation = nil
        let connectCont = connectContinuation
        connectContinuation = nil
        lock.unlock()

        if let streamCont {
            log("[ws] didCompleteWithError: finishing orphaned receive continuation")
            if let error {
                streamCont.finish(throwing: error)
            } else {
                streamCont.finish()
            }
        }
        if let connectCont {
            if let error {
                // Extract HTTP status code from failed WebSocket upgrade
                // so RelayConnection can distinguish 401/403/etc.
                if let httpResponse = task.response as? HTTPURLResponse,
                   httpResponse.statusCode != 101 {
                    connectCont.resume(throwing: WebSocketError.httpUpgradeFailed(statusCode: httpResponse.statusCode))
                } else {
                    connectCont.resume(throwing: error)
                }
            } else {
                connectCont.resume()
            }
        }
    }

    public enum WebSocketError: Error, LocalizedError {
        case notConnected
        case httpUpgradeFailed(statusCode: Int)
        case serverClose(code: Int, reason: String)
        case connectTimedOut
        case sendTimedOut

        public var errorDescription: String? {
            switch self {
            case .notConnected:
                return "WebSocket not connected"
            case .httpUpgradeFailed(let statusCode):
                return "WebSocket upgrade failed with HTTP \(statusCode)"
            case .serverClose(let code, let reason):
                return "WebSocket server close: \(code) \(reason)"
            case .connectTimedOut:
                return "WebSocket connect timed out after \(WebSocketClient.connectTimeout)s"
            case .sendTimedOut:
                return "WebSocket send timed out after \(WebSocketClient.sendTimeout)s"
            }
        }
    }
}
