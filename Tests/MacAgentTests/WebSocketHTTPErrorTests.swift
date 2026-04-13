import Testing
import Foundation
@testable import MacAgentLib
import RemoteDevCore
import Network

// MARK: - MockHTTPServer

/// Minimal TCP server that returns a configurable HTTP response to reject WebSocket upgrades.
private final class MockHTTPServer: @unchecked Sendable {
    let port: UInt16
    private let listener: NWListener

    init(statusCode: Int, statusText: String = "Error") throws {
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

        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, _ in
                // Got HTTP upgrade request — reply with our error status
                let body = "HTTP \(statusCode) \(statusText)"
                let response = "HTTP/1.1 \(statusCode) \(statusText)\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
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

    var url: URL {
        URL(string: "ws://127.0.0.1:\(port)/ws")!
    }

    func stop() {
        listener.cancel()
    }
}

// MARK: - Integration Tests

@Suite(.serialized)
struct WebSocketHTTPErrorTests {

    @Test("WebSocketClient throws httpUpgradeFailed(401) on HTTP 401 response")
    func testWebSocketClient401() async throws {
        let server = try MockHTTPServer(statusCode: 401, statusText: "Unauthorized")
        defer { server.stop() }

        let client = WebSocketClient()
        do {
            try await client.connect(url: server.url)
            #expect(Bool(false), "connect() should have thrown")
        } catch let error as WebSocketClient.WebSocketError {
            guard case .httpUpgradeFailed(let code) = error else {
                #expect(Bool(false), "Expected httpUpgradeFailed, got \(error)")
                return
            }
            #expect(code == 401, "Expected status 401, got \(code)")
        }
        client.disconnect()
    }

    @Test("WebSocketClient throws httpUpgradeFailed(403) on HTTP 403 response")
    func testWebSocketClient403() async throws {
        let server = try MockHTTPServer(statusCode: 403, statusText: "Forbidden")
        defer { server.stop() }

        let client = WebSocketClient()
        do {
            try await client.connect(url: server.url)
            #expect(Bool(false), "connect() should have thrown")
        } catch let error as WebSocketClient.WebSocketError {
            guard case .httpUpgradeFailed(let code) = error else {
                #expect(Bool(false), "Expected httpUpgradeFailed, got \(error)")
                return
            }
            #expect(code == 403, "Expected status 403, got \(code)")
        }
        client.disconnect()
    }

    @Test("RelayConnection retries 401 three times then fires onTokenInvalid")
    func testRelayConnectionExitsOn401() async throws {
        let httpServer = try MockHTTPServer(statusCode: 401, statusText: "Unauthorized")
        defer { httpServer.stop() }

        let tokenInvalid = Flag()

        let conn = RelayConnection(
            serverURL: "ws://127.0.0.1:\(httpServer.port)",
            workDir: "/tmp",
            crypto: SessionCrypto(),
            roomID: "TEST01",
            roomSecret: "secret",
            configDir: makeTempDir()
            // No wsFactory override — uses real WebSocketClient
        )

        conn.onTokenInvalid = { tokenInvalid.value = true }

        // start() should return after 3 transient retries + 1 final 401 that fires onTokenInvalid
        let task = Task { await conn.start() }

        try await awaitCondition(timeout: 90) { tokenInvalid.value }
        #expect(tokenInvalid.value, "onTokenInvalid should fire after 3 transient 401 retries")

        task.cancel()
        await task.value
        conn.disconnect()
    }

    @Test("WebSocketClient throws httpUpgradeFailed(410) on HTTP 410 response")
    func testWebSocketClient410() async throws {
        let server = try MockHTTPServer(statusCode: 410, statusText: "Gone")
        defer { server.stop() }

        let client = WebSocketClient()
        do {
            try await client.connect(url: server.url)
            #expect(Bool(false), "connect() should have thrown")
        } catch let error as WebSocketClient.WebSocketError {
            guard case .httpUpgradeFailed(let code) = error else {
                #expect(Bool(false), "Expected httpUpgradeFailed, got \(error)")
                return
            }
            #expect(code == 410, "Expected status 410, got \(code)")
        }
        client.disconnect()
    }

    @Test("RelayConnection exits on HTTP 410 from real server")
    func testRelayConnectionExitsOn410() async throws {
        let httpServer = try MockHTTPServer(statusCode: 410, statusText: "Gone")
        defer { httpServer.stop() }

        let accountDeleted = Flag()

        let conn = RelayConnection(
            serverURL: "ws://127.0.0.1:\(httpServer.port)",
            workDir: "/tmp",
            crypto: SessionCrypto(),
            roomID: "TEST01",
            roomSecret: "secret",
            configDir: makeTempDir()
        )

        conn.onAccountDeleted = { accountDeleted.value = true }

        // start() should return (not hang) because 410 exits the reconnect loop
        let task = Task { await conn.start() }

        try await awaitCondition(timeout: 10) { accountDeleted.value }
        #expect(accountDeleted.value, "onAccountDeleted should fire on HTTP 410")

        task.cancel()
        await task.value
        conn.disconnect()
    }
}
