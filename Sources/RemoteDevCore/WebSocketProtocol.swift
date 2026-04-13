import Foundation

public protocol WebSocketProtocol: AnyObject {
    var onDisconnect: (() -> Void)? { get set }
    /// The close code from the last `didCloseWith` delegate call, or nil if no close frame was received.
    /// Survives even when the receive stream was already finished by a concurrent error.
    var lastCloseCode: Int? { get }
    func connect(url: URL) async throws
    func connect(request: URLRequest) async throws
    func send(_ message: String) async throws
    func receive() -> AsyncThrowingStream<String, Error>
    func disconnect()
}
