import Foundation
import RemoteDevCore

final class MockWebSocket: WebSocketProtocol, @unchecked Sendable {
    var onDisconnect: (() -> Void)?
    var onMessageSent: ((String) -> Void)?
    private(set) var _lastCloseCode: Int?
    var lastCloseCode: Int? { _lastCloseCode }

    private let lock = NSLock()
    private var _sentMessages: [String] = []
    private var _connectCallCount = 0
    private var _disconnectCallCount = 0
    private var _connectedURL: URL?
    private var pendingReceiveMessages: [String] = []

    var sentMessages: [String] { lock.withLock { _sentMessages } }
    var connectCallCount: Int { lock.withLock { _connectCallCount } }
    var disconnectCallCount: Int { lock.withLock { _disconnectCallCount } }
    var connectedURL: URL? { lock.withLock { _connectedURL } }

    private var receiveContinuation: AsyncThrowingStream<String, Error>.Continuation?
    var shouldFailConnect = false
    var shouldEndReceiveImmediately = false
    var connectDelay: TimeInterval?
    var httpErrorOnConnect: Int?

    func connect(url: URL) async throws {
        lock.withLock {
            _connectCallCount += 1
            _connectedURL = url
        }
        if let code = httpErrorOnConnect {
            throw WebSocketClient.WebSocketError.httpUpgradeFailed(statusCode: code)
        }
        if shouldFailConnect {
            throw MockError.connectionFailed
        }
        if let delay = connectDelay {
            try await Task.sleep(for: .seconds(delay))
        }
    }

    func connect(request: URLRequest) async throws {
        lock.withLock {
            _connectCallCount += 1
            _connectedURL = request.url
        }
        if let code = httpErrorOnConnect {
            throw WebSocketClient.WebSocketError.httpUpgradeFailed(statusCode: code)
        }
        if shouldFailConnect {
            throw MockError.connectionFailed
        }
        if let delay = connectDelay {
            try await Task.sleep(for: .seconds(delay))
        }
    }

    func send(_ message: String) async throws {
        lock.withLock { _sentMessages.append(message) }
        onMessageSent?(message)
    }

    func receive() -> AsyncThrowingStream<String, Error> {
        if shouldEndReceiveImmediately {
            return AsyncThrowingStream { $0.finish() }
        }
        return AsyncThrowingStream { continuation in
            self.lock.withLock {
                self.receiveContinuation = continuation
                for msg in self.pendingReceiveMessages {
                    continuation.yield(msg)
                }
                self.pendingReceiveMessages.removeAll()
            }
        }
    }

    func disconnect() {
        let cont: AsyncThrowingStream<String, Error>.Continuation? = lock.withLock {
            _disconnectCallCount += 1
            pendingReceiveMessages.removeAll()
            let c = receiveContinuation
            receiveContinuation = nil
            return c
        }
        cont?.finish()
        onDisconnect?()
    }

    // MARK: - Test helpers

    func simulateReceive(_ message: String) {
        lock.withLock {
            if let cont = receiveContinuation {
                cont.yield(message)
            } else {
                pendingReceiveMessages.append(message)
            }
        }
    }

    func simulateError(_ error: Error) {
        let cont: AsyncThrowingStream<String, Error>.Continuation? = lock.withLock {
            let c = receiveContinuation
            receiveContinuation = nil
            return c
        }
        cont?.finish(throwing: error)
    }

    /// Simulate server-side WebSocket close with a close code and reason.
    func simulateServerClose(code: Int, reason: String = "") {
        let cont: AsyncThrowingStream<String, Error>.Continuation? = lock.withLock {
            let c = receiveContinuation
            receiveContinuation = nil
            return c
        }
        cont?.finish(throwing: WebSocketClient.WebSocketError.serverClose(code: code, reason: reason))
    }

    enum MockError: Error {
        case connectionFailed
    }
}
