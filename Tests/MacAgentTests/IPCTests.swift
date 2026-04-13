import Testing
import Foundation
@testable import MacAgentLib
import RemoteDevCore
import CPosixHelpers

#if os(macOS)

// MARK: - Helpers

private func makeTempSocketPath() -> (dir: String, sock: String) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("IPCTest-\(UUID().uuidString)").path
    try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return (dir, dir + "/test.sock")
}

private func makeSocketPair() -> (Int32, Int32) {
    var fds: [Int32] = [0, 0]
    let rc = socketpair(AF_UNIX, SOCK_STREAM, 0, &fds)
    precondition(rc == 0, "socketpair failed")
    return (fds[0], fds[1])
}

/// Thread-safe collector for async PTY output.
private final class OutputCollector: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    func string() -> String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: data, encoding: .utf8) ?? ""
    }

    func count() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return data.count
    }
}

// MARK: - All IPC test suites serialized to avoid resource contention
@Suite("IPC Tests", .serialized)
struct IPCTests {

// MARK: - IPC Framing Tests

@Suite("IPC Framing")
struct IPCFramingTests {

    @Test("IPCRequest round-trip through socketpair")
    func requestRoundTrip() throws {
        let (r, w) = makeSocketPair()
        defer { close(r); close(w) }

        let request = IPCRequest(id: 42, request: .createSession(
            sessionId: "s1", name: "zsh", cols: 120, rows: 40,
            workDir: "/tmp", sessionType: "git",
            parentSessionId: nil, branchName: "main",
            parentRepoPath: nil, parentBranchName: nil))

        try IPCFraming.writeFrame(request, to: w)
        let decoded = try IPCFraming.readFrame(IPCRequest.self, from: r)

        #expect(decoded != nil)
        #expect(decoded!.id == 42)
        if case .createSession(let sid, let name, let cols, let rows, _, _, _, _, _, _) = decoded!.request {
            #expect(sid == "s1")
            #expect(name == "zsh")
            #expect(cols == 120)
            #expect(rows == 40)
        } else {
            Issue.record("Expected createSession")
        }
    }

    @Test("IPCResponse with binary data round-trips")
    func responseWithDataRoundTrip() throws {
        let (r, w) = makeSocketPair()
        defer { close(r); close(w) }

        let payload = Data(repeating: 0xAB, count: 4096)
        let response = IPCResponse(id: nil, message: .ptyOutput(sessionId: "s1", data: payload, offset: 999))

        try IPCFraming.writeFrame(response, to: w)
        let decoded = try IPCFraming.readFrame(IPCResponse.self, from: r)

        #expect(decoded != nil)
        #expect(decoded!.id == nil)
        if case .ptyOutput(let sid, let data, let offset) = decoded!.message {
            #expect(sid == "s1")
            #expect(data == payload)
            #expect(offset == 999)
        } else {
            Issue.record("Expected ptyOutput")
        }
    }

    @Test("multiple frames in sequence preserve ordering")
    func multipleFramesOrdered() throws {
        let (r, w) = makeSocketPair()
        defer { close(r); close(w) }

        for i: UInt64 in 0..<20 {
            let req = IPCRequest(id: i, request: .ping)
            try IPCFraming.writeFrame(req, to: w)
        }

        for i: UInt64 in 0..<20 {
            let decoded = try IPCFraming.readFrame(IPCRequest.self, from: r)
            #expect(decoded?.id == i)
        }
    }

    @Test("large payload round-trips")
    func largePayload() throws {
        let (r, w) = makeSocketPair()
        defer { close(r); close(w) }

        // 1MB payload — larger than socket buffer, so write on background thread
        let big = Data((0..<1_000_000).map { UInt8($0 & 0xFF) })
        let response = IPCResponse(id: 1, message: .replayResult(
            sessionId: "s1", data: big, currentOffset: 5000, isFull: true))

        let writeError = UnsafeMutablePointer<Error?>.allocate(capacity: 1)
        writeError.initialize(to: nil)
        let thread = Thread {
            do {
                try IPCFraming.writeFrame(response, to: w)
            } catch {
                writeError.pointee = error
            }
        }
        thread.start()

        let decoded = try IPCFraming.readFrame(IPCResponse.self, from: r)
        // Wait for write thread to complete
        Thread.sleep(forTimeInterval: 0.1)
        if let err = writeError.pointee { throw err }
        writeError.deallocate()

        if case .replayResult(_, let data, let offset, let isFull) = decoded!.message {
            #expect(data.count == 1_000_000)
            #expect(offset == 5000)
            #expect(isFull == true)
        } else {
            Issue.record("Expected replayResult")
        }
    }

    @Test("empty Data fields round-trip")
    func emptyData() throws {
        let (r, w) = makeSocketPair()
        defer { close(r); close(w) }

        let req = IPCRequest(id: 1, request: .writeInput(sessionId: "s1", data: Data()))
        try IPCFraming.writeFrame(req, to: w)
        let decoded = try IPCFraming.readFrame(IPCRequest.self, from: r)

        if case .writeInput(let sid, let data) = decoded!.request {
            #expect(sid == "s1")
            #expect(data.isEmpty)
        } else {
            Issue.record("Expected writeInput")
        }
    }

    @Test("EOF returns nil")
    func eofReturnsNil() throws {
        let (r, w) = makeSocketPair()
        close(w)  // close write end immediately
        defer { close(r) }

        let result = try IPCFraming.readFrame(IPCRequest.self, from: r)
        #expect(result == nil)
    }

    @Test("all HelperMessage cases round-trip")
    func allMessageCasesRoundTrip() throws {
        let (r, w) = makeSocketPair()
        defer { close(r); close(w) }

        let messages: [HelperMessage] = [
            .ok,
            .createResult(sessionId: "s1", success: true, error: nil),
            .createResult(sessionId: "s2", success: false, error: "max sessions"),
            .pong,
            .versionResult(version: 1),
            .sessionExited(sessionId: "s3"),
            .drainResult(sessionId: "s1", data: Data([1, 2, 3])),
            .offsetResult(sessionId: "s1", offset: 42),
            .sessionList(sessions: [
                SessionDetail(sessionId: "s1", name: "zsh", cols: 80, rows: 24,
                              cwd: "/tmp", workDir: "/home", sessionType: .git,
                              parentSessionId: nil, branchName: "main",
                              parentRepoPath: nil, parentBranchName: nil)
            ]),
        ]

        for (i, msg) in messages.enumerated() {
            let resp = IPCResponse(id: UInt64(i), message: msg)
            try IPCFraming.writeFrame(resp, to: w)
        }

        for i in 0..<messages.count {
            let decoded = try IPCFraming.readFrame(IPCResponse.self, from: r)
            #expect(decoded?.id == UInt64(i))
        }
    }
}

// MARK: - IPC Client-Server Tests

@Suite("IPC Client-Server", .serialized)
struct IPCClientServerTests {

    @Test("ping pong")
    func pingPong() throws {
        let (dir, sock) = makeTempSocketPath()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let server = HelperServer(socketPath: sock, workDir: "/tmp")
        server.exitOnIdle = false
        try server.start()

        let client = HelperClient()
        try client.connect(socketPath: sock)
        defer { client.disconnect(); server.shutdown() }

        #expect(client.sendPing() == true)
    }

    @Test("version check returns compatible")
    func versionCheck() throws {
        let (dir, sock) = makeTempSocketPath()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let server = HelperServer(socketPath: sock, workDir: "/tmp")
        server.exitOnIdle = false
        try server.start()

        let client = HelperClient()
        try client.connect(socketPath: sock)
        defer { client.disconnect(); server.shutdown() }

        #expect(client.checkVersion() == true)
    }

    @Test("create session and list")
    func createAndList() throws {
        let (dir, sock) = makeTempSocketPath()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let server = HelperServer(socketPath: sock, workDir: "/tmp")
        server.exitOnIdle = false
        try server.start()

        let client = HelperClient()
        try client.connect(socketPath: sock)
        defer { client.disconnect(); server.shutdown() }

        let ok = client.createSession(sessionId: "s1", name: "test-shell",
                                       cols: 100, rows: 30, sessionWorkDir: "/tmp",
                                       sessionType: .normal, parentSessionId: nil,
                                       branchName: nil, parentRepoPath: nil,
                                       parentBranchName: nil)
        #expect(ok.success == true)
        #expect(client.sessionCount == 1)

        let infos = client.sessionInfoList()
        #expect(infos.count == 1)
        #expect(infos[0].sessionId == "s1")
        #expect(infos[0].name == "test-shell")
    }

    @Test("resize updates size in cache")
    func resizeUpdatesSize() throws {
        let (dir, sock) = makeTempSocketPath()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let server = HelperServer(socketPath: sock, workDir: "/tmp")
        server.exitOnIdle = false
        try server.start()

        let client = HelperClient()
        try client.connect(socketPath: sock)
        defer { client.disconnect(); server.shutdown() }

        client.createSession(sessionId: "s1", name: "zsh", cols: 80, rows: 24,
                             sessionWorkDir: nil, sessionType: .normal,
                             parentSessionId: nil, branchName: nil,
                             parentRepoPath: nil, parentBranchName: nil)

        client.resize(sessionId: "s1", cols: 132, rows: 50)
        let size = client.getSize(sessionId: "s1")
        #expect(size.cols == 132)
        #expect(size.rows == 50)
    }

    @Test("destroy removes session")
    func destroySession() throws {
        let (dir, sock) = makeTempSocketPath()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let server = HelperServer(socketPath: sock, workDir: "/tmp")
        server.exitOnIdle = false
        try server.start()

        let client = HelperClient()
        try client.connect(socketPath: sock)
        defer { client.disconnect(); server.shutdown() }

        client.createSession(sessionId: "s1", name: "zsh", cols: 80, rows: 24,
                             sessionWorkDir: nil, sessionType: .normal,
                             parentSessionId: nil, branchName: nil,
                             parentRepoPath: nil, parentBranchName: nil)
        #expect(client.hasSession("s1") == true)

        client.destroy(sessionId: "s1")
        #expect(client.hasSession("s1") == false)
        #expect(client.isEmpty == true)
    }

    @Test("write input and receive output")
    func writeInputReceiveOutput() async throws {
        let (dir, sock) = makeTempSocketPath()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let server = HelperServer(socketPath: sock, workDir: "/tmp")
        server.exitOnIdle = false
        try server.start()

        let client = HelperClient()
        let collector = OutputCollector()
        client.onOutput = { _, data in
            collector.append(data)
        }
        try client.connect(socketPath: sock)
        defer { client.disconnect(); server.shutdown() }

        client.createSession(sessionId: "s1", name: "zsh", cols: 80, rows: 24,
                             sessionWorkDir: nil, sessionType: .normal,
                             parentSessionId: nil, branchName: nil,
                             parentRepoPath: nil, parentBranchName: nil)

        // Switch to live so output events are forwarded
        client.switchToLive()

        // Wait for shell init
        try await Task.sleep(for: .milliseconds(500))

        // Send command with unique marker
        client.write(Data("echo IPC_MARKER_42\n".utf8), to: "s1")

        // Wait for marker in output
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if collector.string().contains("IPC_MARKER_42") { break }
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(collector.string().contains("IPC_MARKER_42"))
        #expect(client.currentOffset(sessionId: "s1") > 0)
    }

    @Test("syncSessions populates cache from helper")
    func syncSessionsFromHelper() async throws {
        let (dir, sock) = makeTempSocketPath()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let server = HelperServer(socketPath: sock, workDir: "/tmp")
        server.exitOnIdle = false
        try server.start()

        // First client creates sessions
        let client1 = HelperClient()
        try client1.connect(socketPath: sock)

        client1.createSession(sessionId: "s1", name: "zsh-1", cols: 80, rows: 24,
                              sessionWorkDir: "/tmp", sessionType: .normal,
                              parentSessionId: nil, branchName: nil,
                              parentRepoPath: nil, parentBranchName: nil)
        client1.createSession(sessionId: "s2", name: "zsh-2", cols: 100, rows: 30,
                              sessionWorkDir: "/tmp", sessionType: .git,
                              parentSessionId: nil, branchName: "dev",
                              parentRepoPath: nil, parentBranchName: nil)
        client1.disconnect()

        // Wait for server to process disconnect and re-enter accept loop
        try await Task.sleep(for: .milliseconds(500))

        // Second client connects and syncs — simulates main process restart
        let client2 = HelperClient()
        try client2.connect(socketPath: sock)
        defer { client2.disconnect(); server.shutdown() }

        // Cache should be empty before sync
        #expect(client2.isEmpty == true)

        client2.syncSessions()
        #expect(client2.sessionCount == 2)
        #expect(client2.hasSession("s1") == true)
        #expect(client2.hasSession("s2") == true)
        #expect(client2.getSessionType(sessionId: "s2") == .git)
        #expect(client2.getBranchName(sessionId: "s2") == "dev")
    }

    @Test("replay incremental returns data")
    func replayIncremental() async throws {
        let (dir, sock) = makeTempSocketPath()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let server = HelperServer(socketPath: sock, workDir: "/tmp")
        server.exitOnIdle = false
        try server.start()

        let client = HelperClient()
        try client.connect(socketPath: sock)
        defer { client.disconnect(); server.shutdown() }

        client.createSession(sessionId: "s1", name: "zsh", cols: 80, rows: 24,
                             sessionWorkDir: nil, sessionType: .normal,
                             parentSessionId: nil, branchName: nil,
                             parentRepoPath: nil, parentBranchName: nil)

        // Wait for shell output to accumulate
        try await Task.sleep(for: .milliseconds(800))

        // Full replay (sinceOffset: nil)
        let result = client.replayIncremental(sessionId: "s1", sinceOffset: nil)
        #expect(result.data.count > 0)
        #expect(result.isFull == true)
        #expect(result.currentOffset > 0)
    }
}

// MARK: - Re-attach Query Filtering Tests

@Suite("Re-attach terminal query filtering", .serialized)
struct ReattachQueryFilteringTests {

    /// Scenario 1 (re-attach): tee data from a previous fd-pass session contains
    /// unfiltered terminal queries. On re-attach, replay data must be filtered
    /// before writing to stdout, otherwise the Mac terminal responds and ZLE
    /// leaks response bytes as garbage commands ("2", "4c").
    @Test("tee data bypasses interceptor — replay contains raw queries")
    func teeDataContainsQueries() async throws {
        let (dir, sock) = makeTempSocketPath()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let server = HelperServer(socketPath: sock, workDir: "/tmp")
        server.exitOnIdle = false
        try server.start()

        let client = HelperClient()
        try client.connect(socketPath: sock)
        defer { client.disconnect(); server.shutdown() }

        client.createSession(sessionId: "s1", name: "zsh", cols: 80, rows: 24,
                             sessionWorkDir: nil, sessionType: .normal,
                             parentSessionId: nil, branchName: nil,
                             parentRepoPath: nil, parentBranchName: nil)
        client.switchToLive()
        try await Task.sleep(for: .milliseconds(500))

        // Simulate fd-pass tee: send output containing DA1 query (unfiltered)
        let teeData = Data("prompt % \u{1B}[csome output".utf8)
        client.sendTeeOutput(sessionId: "s1", data: teeData, offset: 0)
        try await Task.sleep(for: .milliseconds(200))

        // Get replay — should contain the raw DA1 query from tee data
        let replay = client.replayIncremental(sessionId: "s1", sinceOffset: nil)
        let replayStr = String(data: replay.data, encoding: .utf8) ?? ""
        #expect(replayStr.contains("\u{1B}[c"), "Replay should contain raw DA1 query from tee path")

        // Apply interceptor (what the fix does before writing to stdout)
        let filtered = TerminalQueryInterceptor.intercept(replay.data)
        let filteredStr = String(data: filtered.filteredOutput, encoding: .utf8) ?? ""
        #expect(!filteredStr.contains("\u{1B}[c"), "Filtered replay must NOT contain DA1 query")
        #expect(filteredStr.contains("prompt % "), "Normal text preserved")
        #expect(filteredStr.contains("some output"), "Normal text preserved")
        #expect(filtered.responses.count >= 1, "DA1 response generated for local delivery")
    }

    /// Verify multiple query types are all filtered (pure unit test, no PTY)
    @Test("replay with DA1 + DA2 + DSR + DECRPM + OSC — all filtered")
    func multipleQueriesInReplay() {
        // Simulate replay data containing multiple query types
        // (as would accumulate from fd-pass tee during a Claude Code session)
        var replay = "line1\r\n"
        replay += "\u{1B}[c"           // DA1
        replay += "\u{1B}[>c"          // DA2
        replay += "\u{1B}[5n"          // DSR 5
        replay += "\u{1B}[?2004$p"     // DECRPM
        replay += "\u{1B}]10;?\u{07}"  // OSC 10
        replay += "line2\r\n"

        let filtered = TerminalQueryInterceptor.intercept(Data(replay.utf8))
        let filteredStr = String(data: filtered.filteredOutput, encoding: .utf8)!

        // All queries stripped
        #expect(!filteredStr.contains("\u{1B}[c"), "DA1 stripped")
        #expect(!filteredStr.contains("\u{1B}[>c"), "DA2 stripped")
        #expect(!filteredStr.contains("\u{1B}[5n"), "DSR stripped")
        #expect(!filteredStr.contains("\u{1B}[?2004$p"), "DECRPM stripped")
        #expect(!filteredStr.contains("\u{1B}]10;?"), "OSC 10 stripped")

        // Normal content preserved
        #expect(filteredStr.contains("line1"), "Normal text preserved")
        #expect(filteredStr.contains("line2"), "Normal text preserved")

        // Responses generated for all 5 queries
        #expect(filtered.responses.count == 5, "All 5 query types get local responses")
    }

    /// Scenario 2 (Claude Code): live output from masterFD containing queries
    /// must be filtered before reaching stdout. This simulates the output reader
    /// loop applying the interceptor.
    @Test("live output interception — queries stripped, responses generated")
    func liveOutputInterception() {
        // Simulate a chunk read from masterFD containing embedded queries
        // (as when Claude Code queries terminal capabilities on startup)
        var output = "\u{1B}[?25l"               // hide cursor (pass through)
        output += "\u{1B}[c"                      // DA1 query (intercept)
        output += "\u{1B}[>c"                     // DA2 query (intercept)
        output += "\u{1B}[H\u{1B}[2J"            // clear screen (pass through)
        output += "Claude Code v2.1"              // text (pass through)
        output += "\u{1B}]10;?\u{07}"             // OSC 10 query (intercept)

        let rawData = Data(output.utf8)
        let result = TerminalQueryInterceptor.intercept(rawData)

        // Queries stripped, display sequences preserved
        let filtered = String(data: result.filteredOutput, encoding: .utf8)!
        #expect(filtered.contains("\u{1B}[?25l"), "DECTCEM preserved")
        #expect(filtered.contains("\u{1B}[H\u{1B}[2J"), "Clear screen preserved")
        #expect(filtered.contains("Claude Code v2.1"), "Text preserved")
        #expect(!filtered.contains("\u{1B}[c"), "DA1 stripped")
        #expect(!filtered.contains("\u{1B}[>c"), "DA2 stripped")
        #expect(!filtered.contains("\u{1B}]10;?"), "OSC 10 stripped")

        // 3 queries → 3 responses (DA1, DA2, OSC 10)
        #expect(result.responses.count == 3)
    }

    /// After the fix, tee data sent to HelperServer is already filtered.
    /// This means subsequent re-attach replay is clean without needing
    /// another round of filtering (defense in depth).
    @Test("filtered tee produces clean replay — no double-filtering needed")
    func filteredTeeProducesCleanReplay() async throws {
        let (dir, sock) = makeTempSocketPath()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let server = HelperServer(socketPath: sock, workDir: "/tmp")
        server.exitOnIdle = false
        try server.start()

        let client = HelperClient()
        try client.connect(socketPath: sock)
        defer { client.disconnect(); server.shutdown() }

        client.createSession(sessionId: "s1", name: "zsh", cols: 80, rows: 24,
                             sessionWorkDir: nil, sessionType: .normal,
                             parentSessionId: nil, branchName: nil,
                             parentRepoPath: nil, parentBranchName: nil)
        client.switchToLive()
        try await Task.sleep(for: .milliseconds(500))

        // Simulate the FIXED output reader: filter BEFORE tee
        let rawOutput = Data("prompt % \u{1B}[c\u{1B}[>coutput".utf8)
        let intercepted = TerminalQueryInterceptor.intercept(rawOutput)

        // Send filtered data as tee (what the fix does)
        client.sendTeeOutput(sessionId: "s1", data: intercepted.filteredOutput, offset: 0)
        try await Task.sleep(for: .milliseconds(200))

        // Replay should be clean
        let replay = client.replayIncremental(sessionId: "s1", sinceOffset: nil)
        let replayFiltered = TerminalQueryInterceptor.intercept(replay.data)

        // No additional queries found — tee was already clean
        #expect(replayFiltered.responses.isEmpty, "Clean tee → clean replay, no queries to strip")
        #expect(replayFiltered.filteredOutput == replay.data, "No filtering needed — data unchanged")
    }
}

// MARK: - IPC Stress Tests

@Suite("IPC Stress", .serialized)
struct IPCStressTests {

    @Test("high-throughput output doesn't lose data")
    func highThroughputOutput() async throws {
        let (dir, sock) = makeTempSocketPath()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let server = HelperServer(socketPath: sock, workDir: "/tmp")
        server.exitOnIdle = false
        try server.start()

        let client = HelperClient()
        let collector = OutputCollector()
        client.onOutput = { _, data in
            collector.append(data)
        }
        try client.connect(socketPath: sock)
        defer { client.disconnect(); server.shutdown() }

        client.createSession(sessionId: "s1", name: "zsh", cols: 80, rows: 24,
                             sessionWorkDir: nil, sessionType: .normal,
                             parentSessionId: nil, branchName: nil,
                             parentRepoPath: nil, parentBranchName: nil)
        client.switchToLive()

        try await Task.sleep(for: .milliseconds(500))

        // Generate lots of output
        client.write(Data("seq 1 5000\n".utf8), to: "s1")

        // Wait for last line to appear
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if collector.string().contains("5000") { break }
            try await Task.sleep(for: .milliseconds(100))
        }

        let output = collector.string()
        #expect(output.contains("1"))
        #expect(output.contains("2500"))
        #expect(output.contains("5000"))
    }

    @Test("concurrent create and destroy don't crash")
    func concurrentCreateDestroy() async throws {
        let (dir, sock) = makeTempSocketPath()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let server = HelperServer(socketPath: sock, workDir: "/tmp")
        server.exitOnIdle = false
        try server.start()

        let client = HelperClient()
        try client.connect(socketPath: sock)
        defer { client.disconnect(); server.shutdown() }

        // Create and destroy sessions rapidly from multiple threads
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<8 {
                group.addTask {
                    let sid = "stress-\(i)"
                    let result = client.createSession(sessionId: sid, name: "zsh",
                                                   cols: 80, rows: 24, sessionWorkDir: nil,
                                                   sessionType: .normal, parentSessionId: nil,
                                                   branchName: nil, parentRepoPath: nil,
                                                   parentBranchName: nil)
                    if result.success {
                        client.destroy(sessionId: sid)
                    }
                }
            }
        }

        // Should not crash; final state should be consistent
        #expect(client.sessionCount >= 0)
    }

    @Test("reconnect recovers sessions")
    func reconnectRecoversSessions() async throws {
        let (dir, sock) = makeTempSocketPath()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let server = HelperServer(socketPath: sock, workDir: "/tmp")
        server.exitOnIdle = false
        try server.start()

        // First connection: create sessions
        let client1 = HelperClient()
        try client1.connect(socketPath: sock)

        client1.createSession(sessionId: "persist-1", name: "zsh-1", cols: 80, rows: 24,
                              sessionWorkDir: nil, sessionType: .normal,
                              parentSessionId: nil, branchName: nil,
                              parentRepoPath: nil, parentBranchName: nil)
        client1.createSession(sessionId: "persist-2", name: "zsh-2", cols: 80, rows: 24,
                              sessionWorkDir: nil, sessionType: .normal,
                              parentSessionId: nil, branchName: nil,
                              parentRepoPath: nil, parentBranchName: nil)
        client1.switchToLive()

        // Simulate main crash — disconnect abruptly
        client1.disconnect()

        // Wait for server to detect disconnect
        try await Task.sleep(for: .milliseconds(300))

        // New connection: sync should recover both sessions
        let client2 = HelperClient()
        try client2.connect(socketPath: sock)
        defer { client2.disconnect(); server.shutdown() }

        client2.syncSessions()
        #expect(client2.sessionCount == 2)
        #expect(client2.hasSession("persist-1") == true)
        #expect(client2.hasSession("persist-2") == true)
    }
}

// MARK: - Multi-Client and Recovery Tests

@Suite("Multi-Client and Recovery", .serialized)
struct MultiClientRecoveryTests {

    @Test("two clients connect simultaneously and both work")
    func multiClientSimultaneous() async throws {
        let (dir, sock) = makeTempSocketPath()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let server = HelperServer(socketPath: sock, workDir: "/tmp")
        server.exitOnIdle = false
        try server.start()

        // Client 1 (AgentService) connects and creates a session
        let client1 = HelperClient()
        try client1.connect(socketPath: sock)
        client1.switchToLive()

        client1.createSession(sessionId: "s1", name: "zsh", cols: 80, rows: 24,
                              sessionWorkDir: nil, sessionType: .normal,
                              parentSessionId: nil, branchName: nil,
                              parentRepoPath: nil, parentBranchName: nil)

        // Client 2 (Mac CLI) connects simultaneously — no yield needed
        let client2 = HelperClient()
        let collector = OutputCollector()
        client2.onOutput = { sid, data in
            if sid == "s1" { collector.append(data) }
        }
        try client2.connectNoReconnect(socketPath: sock)
        client2.switchToLive()
        client2.syncSessions()

        // Both clients see the session
        #expect(client1.sessionCount == 1)
        #expect(client2.sessionCount == 1)
        #expect(client1.isConnected == true)
        #expect(client2.isConnected == true)

        // Client 2 does I/O while client 1 stays connected
        try await Task.sleep(for: .milliseconds(300))
        client2.write(Data("echo MULTI_CLIENT_TEST\n".utf8), to: "s1")

        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if collector.string().contains("MULTI_CLIENT_TEST") { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(collector.string().contains("MULTI_CLIENT_TEST"))

        // Client 1 still connected after client 2's I/O
        #expect(client1.isConnected == true)
        #expect(client1.sendPing() == true)

        // Client 2 disconnects — client 1 unaffected
        client2.disconnect()
        try await Task.sleep(for: .milliseconds(200))

        #expect(client1.isConnected == true)
        #expect(client1.sessionCount == 1)
        #expect(client1.sendPing() == true)

        client1.disconnect()
        server.shutdown()
    }

    @Test("onRestartHelper is called when socket reconnect fails")
    func restartHelperCallback() async throws {
        let (dir, sock) = makeTempSocketPath()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let server = HelperServer(socketPath: sock, workDir: "/tmp")
        server.exitOnIdle = false
        try server.start()

        let client = HelperClient()
        var restartCalled = false
        let restartLock = NSLock()
        client.onRestartHelper = {
            restartLock.lock()
            restartCalled = true
            restartLock.unlock()
            // Simulate starting a new helper by starting another server
            // (In real code, AgentService spawns the helper process)
            return false  // Return false to test the failure path
        }
        try client.connect(socketPath: sock)

        // Kill the server to trigger reconnect → restart chain
        server.shutdown()

        // Wait for reconnect attempts + restart callback
        // 10 attempts × exponential backoff ≈ 21s max, but server is gone so connects fail fast
        let deadline = ContinuousClock.now + .seconds(30)
        while ContinuousClock.now < deadline {
            restartLock.lock()
            let called = restartCalled
            restartLock.unlock()
            if called { break }
            try await Task.sleep(for: .milliseconds(200))
        }

        restartLock.lock()
        let wasCalled = restartCalled
        restartLock.unlock()
        #expect(wasCalled == true)

        client.disconnect()
    }

    @Test("connectNoReconnect does not auto-reconnect on server shutdown")
    func connectNoReconnectNoRetry() async throws {
        let (dir, sock) = makeTempSocketPath()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let server = HelperServer(socketPath: sock, workDir: "/tmp")
        server.exitOnIdle = false
        try server.start()

        let client = HelperClient()
        try client.connectNoReconnect(socketPath: sock)

        #expect(client.isConnected == true)
        #expect(client.sendPing() == true)

        // Server shutdown closes client fd → client detects disconnect
        server.shutdown()

        // Wait for client to detect disconnect
        try await Task.sleep(for: .milliseconds(500))

        // Should NOT have auto-reconnected (shouldReconnect = false)
        #expect(client.isConnected == false)

        client.disconnect()
    }
}

// MARK: - Zombie Session Tests

@Suite("Zombie Session", .serialized)
struct ZombieSessionTests {

    @Test("session exit with no live clients delivers on reconnect")
    func pendingExitDeliveredOnReconnect() async throws {
        let (dir, sock) = makeTempSocketPath()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let server = HelperServer(socketPath: sock, workDir: "/tmp")
        server.exitOnIdle = false
        try server.start()

        let client = HelperClient()
        var exitedSessions: [String] = []
        let exitLock = NSLock()
        client.onSessionExited = { sid in
            exitLock.lock()
            exitedSessions.append(sid)
            exitLock.unlock()
        }
        try client.connect(socketPath: sock)
        client.switchToLive()

        client.createSession(sessionId: "zombie-1", name: "zsh", cols: 80, rows: 24,
                              sessionWorkDir: nil, sessionType: .normal,
                              parentSessionId: nil, branchName: nil,
                              parentRepoPath: nil, parentBranchName: nil)

        try await Task.sleep(for: .milliseconds(200))

        // Switch to buffer-only FIRST so there are no live clients
        client.switchToBufferOnly()
        try await Task.sleep(for: .milliseconds(100))

        // Now make the shell exit while no live clients
        client.write(Data("exit\n".utf8), to: "zombie-1")

        // Wait for shell to exit — exit notification queued in pendingExits
        try await Task.sleep(for: .milliseconds(800))

        // Switch back to live — should drain pendingExits
        client.switchToLive()
        try await Task.sleep(for: .milliseconds(500))

        exitLock.lock()
        let exited = exitedSessions
        exitLock.unlock()

        #expect(exited.contains("zombie-1"), "Expected pending exit for zombie-1 to be delivered")
        #expect(client.sessionCount == 0, "Zombie session should be removed after pending exit delivery")

        client.disconnect()
        server.shutdown()
    }

    @Test("explicit destroy clears pending exit")
    func destroyClearsPendingExit() async throws {
        let (dir, sock) = makeTempSocketPath()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let server = HelperServer(socketPath: sock, workDir: "/tmp")
        server.exitOnIdle = false
        try server.start()

        let client = HelperClient()
        var exitedSessions: [String] = []
        let exitLock = NSLock()
        client.onSessionExited = { sid in
            exitLock.lock()
            exitedSessions.append(sid)
            exitLock.unlock()
        }
        try client.connect(socketPath: sock)
        client.switchToLive()

        client.createSession(sessionId: "destroy-1", name: "zsh", cols: 80, rows: 24,
                              sessionWorkDir: nil, sessionType: .normal,
                              parentSessionId: nil, branchName: nil,
                              parentRepoPath: nil, parentBranchName: nil)

        try await Task.sleep(for: .milliseconds(200))

        // Switch to buffer-only, then exit shell → queued in pendingExits
        client.switchToBufferOnly()
        try await Task.sleep(for: .milliseconds(100))
        client.write(Data("exit\n".utf8), to: "destroy-1")
        try await Task.sleep(for: .milliseconds(800))

        // Explicitly destroy the session before switchToLive
        client.destroy(sessionId: "destroy-1")
        client.switchToLive()

        try await Task.sleep(for: .milliseconds(500))

        exitLock.lock()
        let exited = exitedSessions
        exitLock.unlock()

        #expect(!exited.contains("destroy-1"), "Explicitly destroyed session should not fire pending exit")
        #expect(client.sessionCount == 0)

        client.disconnect()
        server.shutdown()
    }

    @Test("idle shutdown not blocked by zombie sessions")
    func idleShutdownWithZombies() async throws {
        let (dir, sock) = makeTempSocketPath()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let server = HelperServer(socketPath: sock, workDir: "/tmp", idleTimeout: 1)
        server.exitOnIdle = false
        var shutdownCalled = false
        let shutdownLock = NSLock()
        server.onShutdown = {
            shutdownLock.lock()
            shutdownCalled = true
            shutdownLock.unlock()
        }
        try server.start()

        let client = HelperClient()
        try client.connect(socketPath: sock)
        client.switchToLive()

        client.createSession(sessionId: "idle-1", name: "zsh", cols: 80, rows: 24,
                             sessionWorkDir: nil, sessionType: .normal,
                             parentSessionId: nil, branchName: nil,
                             parentRepoPath: nil, parentBranchName: nil)

        try await Task.sleep(for: .milliseconds(200))

        // Switch to buffer-only first, then exit shell → queued in pendingExits
        client.switchToBufferOnly()
        try await Task.sleep(for: .milliseconds(100))
        client.write(Data("exit\n".utf8), to: "idle-1")
        try await Task.sleep(for: .milliseconds(800))

        // Disconnect → zombie session, no clients
        client.disconnect()

        // Wait for idle timeout (1s) + margin
        try await Task.sleep(for: .seconds(3))

        shutdownLock.lock()
        let didShutdown = shutdownCalled
        shutdownLock.unlock()

        #expect(didShutdown, "Server should auto-shutdown even with zombie sessions pending")
    }
}

} // IPCTests

// MARK: - fd passing tests

@Suite("FdPassing")
struct FdPassingTests {

    @Test("c_sendfd and c_recvfd round-trip a pipe fd")
    func fdPassingRoundTrip() throws {
        let (sockA, sockB) = makeSocketPair()
        defer { close(sockA); close(sockB) }

        // Create a pipe to pass
        var pipeFDs: [Int32] = [0, 0]
        #expect(pipe(&pipeFDs) == 0)
        let pipeRead = pipeFDs[0]
        let pipeWrite = pipeFDs[1]
        defer { close(pipeWrite) }

        // Send the read end of the pipe via sockA
        #expect(c_sendfd(sockA, pipeRead) == 0)
        close(pipeRead)  // close our copy — the other side has the fd now

        // Receive it on sockB
        let receivedFD = c_recvfd(sockB)
        #expect(receivedFD >= 0)
        defer { close(receivedFD) }

        // Verify: write to pipe, read from the passed fd
        let message = "hello from fd passing"
        message.withCString { ptr in
            _ = Darwin.write(pipeWrite, ptr, message.utf8.count)
        }
        var buf = [UInt8](repeating: 0, count: 256)
        let n = Darwin.read(receivedFD, &buf, buf.count)
        #expect(n == message.utf8.count)
        #expect(String(bytes: buf[0..<n], encoding: .utf8) == message)
    }

    @Test("teeOutput message round-trips through IPC framing")
    func teeOutputRoundTrip() throws {
        let (r, w) = makeSocketPair()
        defer { close(r); close(w) }

        let payload = Data([0x1B, 0x5B, 0x48])  // ESC[H
        let request = IPCRequest(id: 42, request: .teeOutput(sessionId: "s1", data: payload, offset: 1024))

        try IPCFraming.writeFrame(request, to: w)
        let decoded = try IPCFraming.readFrame(IPCRequest.self, from: r)
        #expect(decoded != nil)
        if case .teeOutput(let sid, let data, let offset) = decoded!.request {
            #expect(sid == "s1")
            #expect(data == payload)
            #expect(offset == 1024)
        } else {
            Issue.record("Expected teeOutput")
        }
    }

    @Test("requestPtyFd and releasePtyFd messages encode/decode")
    func fdPassingMessagesRoundTrip() throws {
        let (r, w) = makeSocketPair()
        defer { close(r); close(w) }

        // requestPtyFd
        try IPCFraming.writeFrame(IPCRequest(id: 1, request: .requestPtyFd(sessionId: "s1")), to: w)
        let req = try IPCFraming.readFrame(IPCRequest.self, from: r)
        if case .requestPtyFd(let sid) = req!.request {
            #expect(sid == "s1")
        } else {
            Issue.record("Expected requestPtyFd")
        }

        // ptyFdReady
        try IPCFraming.writeFrame(IPCResponse(id: 1, message: .ptyFdReady(sessionId: "s1")), to: w)
        let resp = try IPCFraming.readFrame(IPCResponse.self, from: r)
        if case .ptyFdReady(let sid) = resp!.message {
            #expect(sid == "s1")
        } else {
            Issue.record("Expected ptyFdReady")
        }

        // releasePtyFd
        try IPCFraming.writeFrame(IPCRequest(id: 2, request: .releasePtyFd(sessionId: "s1")), to: w)
        let req2 = try IPCFraming.readFrame(IPCRequest.self, from: r)
        if case .releasePtyFd(let sid) = req2!.request {
            #expect(sid == "s1")
        } else {
            Issue.record("Expected releasePtyFd")
        }
    }
}

#endif
