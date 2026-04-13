import Testing
import Foundation
@testable import RemoteDevCore

// MARK: - Python-based WebSocket test server

private final class PyWSServer: @unchecked Sendable {
    private(set) var port: Int = 0
    private var process: Process?

    private static let venvPath = "/tmp/ws-test-venv"

    /// Ensure the Python venv with `websockets` is ready; create it on first use.
    private static let venvReady: Bool = {
        let python3Path = "\(venvPath)/bin/python3"
        if FileManager.default.fileExists(atPath: python3Path) {
            let check = Process()
            check.executableURL = URL(fileURLWithPath: python3Path)
            check.arguments = ["-c", "import websockets"]
            check.standardOutput = Pipe()
            check.standardError = Pipe()
            try? check.run()
            check.waitUntilExit()
            if check.terminationStatus == 0 { return true }
        }
        let createVenv = Process()
        createVenv.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        createVenv.arguments = ["-m", "venv", "--clear", venvPath]
        try? createVenv.run()
        createVenv.waitUntilExit()
        guard createVenv.terminationStatus == 0 else { return false }
        let installPkg = Process()
        installPkg.executableURL = URL(fileURLWithPath: "\(venvPath)/bin/pip")
        installPkg.arguments = ["install", "-q", "websockets"]
        try? installPkg.run()
        installPkg.waitUntilExit()
        return installPkg.terminationStatus == 0
    }()

    private static func ensureVenv() throws {
        guard venvReady else {
            throw NSError(domain: "PyWSServer", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to set up Python venv at \(venvPath)"])
        }
    }

    init(mode: String) throws {
        try Self.ensureVenv()
        let script = """
        import asyncio, websockets
        async def handler(ws):
            await ws.send("test-message")
            delay = 0.0 if "\(mode)".endswith("-nodelay") else 0.3
            await asyncio.sleep(delay)
            mode = "\(mode)".replace("-nodelay", "")
            if mode == "abrupt":
                ws.transport.abort()
            else:
                await ws.close(code=1000, reason="done")
        async def main():
            srv = await websockets.serve(handler, "127.0.0.1", 0)
            port = srv.sockets[0].getsockname()[1]
            print(f"PORT:{port}", flush=True)
            await srv.serve_forever()
        asyncio.run(main())
        """
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "\(Self.venvPath)/bin/python3")
        proc.arguments = ["-c", script]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        try proc.run()
        self.process = proc

        let readHandle = pipe.fileHandleForReading
        let deadline = Date().addingTimeInterval(5)
        var output = ""
        while Date() < deadline {
            if let data = try? readHandle.availableData, !data.isEmpty {
                output += String(data: data, encoding: .utf8) ?? ""
                if output.contains("PORT:") { break }
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard let portStr = output.components(separatedBy: "\n")
            .first(where: { $0.hasPrefix("PORT:") })?
            .replacingOccurrences(of: "PORT:", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines),
              let p = Int(portStr) else {
            proc.terminate()
            throw NSError(domain: "PyWSServer", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Server didn't start: \(output)"])
        }
        self.port = p
        Thread.sleep(forTimeInterval: 0.2)
    }

    func stop() {
        process?.terminate()
        process?.waitUntilExit()
        process = nil
    }
}

// MARK: - Tests

@Suite("WebSocketClient abrupt close behavior")
struct WebSocketAbruptCloseTests {

    /// Baseline: when server sends a clean WebSocket close, the receive stream
    /// should end (either cleanly or with an error) — it must NOT hang.
    @Test("Clean close ends receive stream",
          .timeLimit(.minutes(1)))
    func testCleanCloseEndsReceiveStream() async throws {
        let server = try PyWSServer(mode: "clean")
        defer { server.stop() }

        let client = WebSocketClient()
        try await client.connect(url: URL(string: "ws://127.0.0.1:\(server.port)")!)

        var messages: [String] = []
        let stream = client.receive()
        do {
            for try await text in stream { messages.append(text) }
        } catch {
            // Stream ending with error is acceptable (e.g. ENOTCONN after close)
        }
        #expect(messages.contains("test-message"),
                "Should have received message before close. Got: \(messages)")
    }

    /// BUG REPRODUCTION: server abruptly kills TCP (no WebSocket close frame).
    ///
    /// When this happens, only `didCompleteWithError` fires (not `didCloseWith`).
    /// If `didCompleteWithError` doesn't finish the receive stream `continuation`,
    /// the `for try await` loop hangs forever.
    ///
    /// **If this test TIMES OUT (1 min), the bug is confirmed.**
    @Test("Abrupt TCP close must not hang receive stream",
          .timeLimit(.minutes(1)))
    func testAbruptCloseDoesNotHang() async throws {
        let server = try PyWSServer(mode: "abrupt")
        defer { server.stop() }

        let client = WebSocketClient()
        try await client.connect(url: URL(string: "ws://127.0.0.1:\(server.port)")!)

        var messages: [String] = []
        let stream = client.receive()
        do {
            for try await text in stream { messages.append(text) }
        } catch {
            // Error is expected (ECONNRESET or ENOTCONN)
        }
        // If we reach here, the stream ended (test passes).
        // If the bug exists, we never reach here — test times out.
        #expect(messages.contains("test-message"),
                "Should have received message before TCP kill. Got: \(messages)")
    }

    /// Production scenario: server sends quota_exceeded then IMMEDIATELY closes.
    /// No delay between message and close. This is the exact timing from the
    /// production bug at 10:12:01.
    @Test("Immediate clean close after message must not hang",
          .timeLimit(.minutes(1)))
    func testImmediateCleanClose() async throws {
        let server = try PyWSServer(mode: "clean-nodelay")
        defer { server.stop() }

        let client = WebSocketClient()
        try await client.connect(url: URL(string: "ws://127.0.0.1:\(server.port)")!)

        var messages: [String] = []
        let stream = client.receive()
        do {
            for try await text in stream { messages.append(text) }
        } catch {
            // Error is expected
        }
        #expect(messages.contains("test-message"),
                "Should have received message. Got: \(messages)")
    }

    /// Production scenario: server sends message then IMMEDIATELY kills TCP.
    @Test("Immediate abrupt close after message must not hang",
          .timeLimit(.minutes(1)))
    func testImmediateAbruptClose() async throws {
        let server = try PyWSServer(mode: "abrupt-nodelay")
        defer { server.stop() }

        let client = WebSocketClient()
        try await client.connect(url: URL(string: "ws://127.0.0.1:\(server.port)")!)

        var messages: [String] = []
        let stream = client.receive()
        do {
            for try await text in stream { messages.append(text) }
        } catch {
            // Error is expected
        }
        // Message might or might not arrive before the close; the key is NO HANG
    }
}
