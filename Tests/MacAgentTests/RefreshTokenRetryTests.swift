import Testing
import Foundation
import Network
@testable import MacAgentLib

// MARK: - MockRefreshServer

/// TCP server that simulates the /auth/refresh endpoint.
/// Returns a configurable sequence of HTTP responses, allowing tests to
/// simulate transient 401s followed by a successful 200.
private final class MockRefreshServer: @unchecked Sendable {
    let port: UInt16
    private let listener: NWListener
    private let lock = NSLock()
    private let counterBox: NSMutableArray = [0 as NSNumber]
    private let responses: [(Int, String)]  // [(statusCode, body)]

    /// Create a server with a fixed sequence of responses.
    /// After the sequence is exhausted, the last response is repeated.
    init(responses: [(Int, String)]) throws {
        self.responses = responses
        let params = NWParameters.tcp
        let listener = try NWListener(using: params, on: .any)

        let semaphore = DispatchSemaphore(value: 0)
        var assignedPort: UInt16 = 0

        listener.stateUpdateHandler = { state in
            if case .ready = state, let port = listener.port {
                assignedPort = port.rawValue
                semaphore.signal()
            }
        }

        // Capture locals to avoid referencing self before init completes.
        let allResponses = responses
        let counterLock = lock
        let counterBox = self.counterBox

        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { _, _, _, _ in
                let idx: Int = counterLock.withLock {
                    let i = (counterBox[0] as! NSNumber).intValue
                    counterBox[0] = NSNumber(value: i + 1)
                    return i
                }
                let (statusCode, body) = idx < allResponses.count
                    ? allResponses[idx]
                    : allResponses[allResponses.count - 1]

                let statusText: String
                switch statusCode {
                case 200: statusText = "OK"
                case 401: statusText = "Unauthorized"
                case 429: statusText = "Too Many Requests"
                case 500: statusText = "Internal Server Error"
                default:  statusText = "Error"
                }

                let response = "HTTP/1.1 \(statusCode) \(statusText)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        }

        listener.start(queue: .global())
        semaphore.wait()
        self.listener = listener
        self.port = assignedPort
    }

    var requestCount: Int { lock.withLock { (counterBox[0] as! NSNumber).intValue } }

    var serverURL: String { "http://127.0.0.1:\(port)" }

    func stop() { listener.cancel() }
}

// MARK: - Tests

@Suite(.serialized)
struct RefreshTokenRetryTests {

    private func successBody(apiKey: String = "new-api-key", refreshToken: String = "new-refresh-token") -> String {
        """
        {"api_key":"\(apiKey)","refresh_token":"\(refreshToken)"}
        """
    }

    @Test("Transient 401s are retried and recover on success")
    func testTransient401Recovery() async throws {
        let server = try MockRefreshServer(responses: [
            (401, #"{"error":"REFRESH_TOKEN_INVALID"}"#),
            (401, #"{"error":"REFRESH_TOKEN_INVALID"}"#),
            (200, #"{"api_key":"new-key","refresh_token":"new-rt"}"#),
        ])
        defer { server.stop() }

        let configDir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: configDir) }

        let result = await refreshAPIKey(
            serverURL: server.serverURL,
            refreshToken: "old-refresh-token",
            configDir: configDir
        )

        #expect(result != nil, "Should succeed after transient 401s")
        #expect(result?.apiKey == "new-key")
        #expect(result?.refreshToken == "new-rt")
        #expect(server.requestCount == 3, "Expected 3 requests (2 retries + 1 success)")

        // Verify tokens were persisted to disk
        let savedApiKey = try? String(contentsOfFile: configDir + "/api_key", encoding: .utf8)
        #expect(savedApiKey == "new-key")
    }

    @Test("Persistent 401 exhausts retries and returns nil")
    func testPersistent401ExhaustsRetries() async throws {
        let server = try MockRefreshServer(responses: [
            (401, #"{"error":"REFRESH_TOKEN_INVALID"}"#),
        ])
        defer { server.stop() }

        let configDir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: configDir) }

        let result = await refreshAPIKey(
            serverURL: server.serverURL,
            refreshToken: "expired-token",
            configDir: configDir,
            maxAttempts: 3
        )

        #expect(result == nil, "Should return nil after exhausting retries")
        #expect(server.requestCount == 3, "Expected 3 attempts (maxAttempts)")
    }

    @Test("Task cancellation stops retry loop early")
    func testCancellationStopsRetry() async throws {
        let server = try MockRefreshServer(responses: [
            (401, #"{"error":"REFRESH_TOKEN_INVALID"}"#),
        ])
        defer { server.stop() }

        let configDir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: configDir) }

        let task = Task {
            await refreshAPIKey(
                serverURL: server.serverURL,
                refreshToken: "some-token",
                configDir: configDir
            )
        }

        // Let a few attempts happen, then cancel
        try await Task.sleep(for: .seconds(2))
        task.cancel()
        let result = await task.value

        #expect(result == nil, "Should return nil on cancellation")
        #expect(server.requestCount < 10, "Should not exhaust all retries")
        #expect(server.requestCount >= 1, "Should have made at least 1 attempt")
    }
}
