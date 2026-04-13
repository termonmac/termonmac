import Testing
import Foundation
import AppKit
@testable import MacAgentLib
import RemoteDevCore

@Suite(.serialized)
struct ConnectionRobustnessTests {

    // MARK: - P1: Full reconnect cycle

    @Test("Heartbeat timeout triggers reconnect and re-register")
    func testHeartbeatTimeoutReconnectReRegister() async throws {
        let server = MockRelayServer(roomSecret: "secret", pairingToken: testPairingToken)
        let registered = Counter()

        let conn = RelayConnection(
            serverURL: "ws://localhost:9999",
            workDir: "/tmp",
            crypto: SessionCrypto(),
            roomID: "TEST01",
            roomSecret: "secret",
            configDir: makeTempDirWithPairingToken(),
            wsFactory: {
                let ws = MockWebSocket()
                server.attach(to: ws)
                return ws
            },
            heartbeatInterval: 0.3,
            heartbeatAckTimeout: 0.8
        )

        conn.onRoomRegistered = { registered.increment() }

        let task = Task { await conn.start() }

        // Wait for first registration
        try await awaitCondition(timeout: 3) { registered.value >= 1 }

        // Stop heartbeat ACKs → timeout → disconnect → reconnect
        server.stopHeartbeatAcks()

        // Wait for reconnect and second registration
        try await awaitCondition(timeout: 5) { registered.value >= 2 }

        #expect(server.registerCount >= 2, "Should have re-registered after heartbeat timeout")

        // Resume ACKs so test tears down cleanly
        server.resumeHeartbeatAcks()

        task.cancel()
        await task.value
        conn.disconnect()
    }

    @Test("Register timeout triggers reconnect, second attempt succeeds")
    func testRegisterTimeoutReconnect() async throws {
        let server = MockRelayServer(roomSecret: "secret", pairingToken: testPairingToken)
        server.autoRespondRoomRegistered = false

        let registered = Flag()

        let conn = RelayConnection(
            serverURL: "ws://localhost:9999",
            workDir: "/tmp",
            crypto: SessionCrypto(),
            roomID: "TEST01",
            roomSecret: "secret",
            configDir: makeTempDirWithPairingToken(),
            wsFactory: {
                let ws = MockWebSocket()
                server.attach(to: ws)
                return ws
            },
            heartbeatInterval: 30,
            heartbeatAckTimeout: 60,
            registerTimeout: 1
        )

        conn.onRoomRegistered = { registered.value = true }

        let task = Task { await conn.start() }

        // Wait for first register attempt (server won't respond)
        try await server.awaitRegisterCount(1, timeout: 3)

        // Enable auto-respond for the next attempt
        server.autoRespondRoomRegistered = true

        // Wait for second attempt to succeed
        try await awaitCondition(timeout: 5) { registered.value }

        #expect(server.registerCount >= 2,
                "Should have re-registered after timeout, count=\(server.registerCount)")

        task.cancel()
        await task.value
        conn.disconnect()
    }

    @Test("Server error HEARTBEAT_TIMEOUT triggers reconnect")
    func testServerErrorHeartbeatTimeout() async throws {
        let server = MockRelayServer(roomSecret: "secret", pairingToken: testPairingToken)
        let registered = Counter()

        let conn = RelayConnection(
            serverURL: "ws://localhost:9999",
            workDir: "/tmp",
            crypto: SessionCrypto(),
            roomID: "TEST01",
            roomSecret: "secret",
            configDir: makeTempDirWithPairingToken(),
            wsFactory: {
                let ws = MockWebSocket()
                server.attach(to: ws)
                return ws
            },
            heartbeatInterval: 30,
            heartbeatAckTimeout: 60
        )

        conn.onRoomRegistered = { registered.increment() }

        let task = Task { await conn.start() }

        // Wait for first registration
        try await awaitCondition(timeout: 3) { registered.value >= 1 }

        // Server sends error + force disconnect (simulates relay-side heartbeat timeout)
        server.sendError(code: "HEARTBEAT_TIMEOUT", message: "No heartbeat received")
        try await Task.sleep(for: .milliseconds(100))
        server.forceDisconnect()

        // Wait for reconnect and re-register
        try await awaitCondition(timeout: 5) { registered.value >= 2 }

        #expect(server.registerCount >= 2, "Should have re-registered after server error")

        task.cancel()
        await task.value
        conn.disconnect()
    }

    @Test("Server close 1001 (Going Away / DO restart) triggers immediate reconnect")
    func testServerCloseGoingAwayReconnects() async throws {
        let server = MockRelayServer(roomSecret: "secret", pairingToken: testPairingToken)
        let registered = Counter()

        let conn = RelayConnection(
            serverURL: "ws://localhost:9999",
            workDir: "/tmp",
            crypto: SessionCrypto(),
            roomID: "TEST01",
            roomSecret: "secret",
            configDir: makeTempDirWithPairingToken(),
            wsFactory: {
                let ws = MockWebSocket()
                server.attach(to: ws)
                return ws
            },
            heartbeatInterval: 30,
            heartbeatAckTimeout: 60
        )

        conn.onRoomRegistered = { registered.increment() }

        let task = Task { await conn.start() }

        try await awaitCondition(timeout: 3) { registered.value >= 1 }

        // DO restarts → sends close(1001) — should reconnect immediately (delay=0)
        let closeTime = Date()
        server.closeWebSocket(code: 1001, reason: "Durable Object restarting")

        try await awaitCondition(timeout: 5) { registered.value >= 2 }
        let reconnectTime = Date().timeIntervalSince(closeTime)
        #expect(reconnectTime < 2.0,
                "close(1001) should reconnect immediately, took \(reconnectTime)s")
        #expect(server.registerCount >= 2,
                "Should reconnect after server close 1001")

        task.cancel()
        await task.value
        conn.disconnect()
    }

    @Test("DO heartbeat timeout close(4000) triggers reconnect and re-auth")
    func testDOHeartbeatTimeoutCloseReconnectsAndReAuths() async throws {
        let server = MockRelayServer(roomSecret: "secret", pairingToken: testPairingToken)
        let authCount = Counter()
        let registered = Counter()

        let conn = RelayConnection(
            serverURL: "ws://localhost:9999",
            workDir: "/tmp",
            crypto: SessionCrypto(),
            roomID: "TEST01",
            roomSecret: "secret",
            configDir: makeTempDirWithPairingToken(),
            wsFactory: {
                let ws = MockWebSocket()
                server.attach(to: ws)
                return ws
            },
            heartbeatInterval: 30,
            heartbeatAckTimeout: 60
        )

        conn.onRoomRegistered = { registered.increment() }
        conn.secretRotated = true
        conn.onPeerAuthenticated = { authCount.increment() }

        let task = Task { await conn.start() }

        // Wait for registration, then peer join + auth
        try await server.awaitRegisterCount(1, timeout: 3)
        try await Task.sleep(for: .milliseconds(200))
        server.simulatePeerJoin()
        try await awaitCondition(timeout: 5) { authCount.value >= 1 }

        // DO alarm detects 45s no message → close(4000) — should reconnect immediately (delay=0)
        let closeTime = Date()
        server.closeWebSocket(code: 4000, reason: "heartbeat timeout")

        // Wait for reconnect → re-register → peer join → re-auth
        try await server.awaitConnectionCount(3, timeout: 5)
        let reconnectTime = Date().timeIntervalSince(closeTime)
        #expect(reconnectTime < 2.0,
                "close(4000) should reconnect immediately, took \(reconnectTime)s")
        try await Task.sleep(for: .milliseconds(200))
        server.simulatePeerJoin()
        try await awaitCondition(timeout: 5) { authCount.value >= 2 }

        #expect(registered.value >= 2,
                "Should re-register after close(4000), count=\(registered.value)")
        #expect(authCount.value >= 2,
                "Should re-auth after close(4000), count=\(authCount.value)")

        task.cancel()
        await task.value
        conn.disconnect()
    }

    @Test("Server close 1011 during auth triggers clean re-auth")
    func testServerCloseDuringAuthReconnectsAndReAuths() async throws {
        let server = MockRelayServer(roomSecret: "secret", pairingToken: testPairingToken)
        server.autoAuthPeer = false
        let authCount = Counter()

        let conn = RelayConnection(
            serverURL: "ws://localhost:9999",
            workDir: "/tmp",
            crypto: SessionCrypto(),
            roomID: "TEST01",
            roomSecret: "secret",
            configDir: makeTempDirWithPairingToken(),
            wsFactory: {
                let ws = MockWebSocket()
                server.attach(to: ws)
                return ws
            },
            heartbeatInterval: 30,
            heartbeatAckTimeout: 60
        )

        conn.secretRotated = true
        conn.onPeerAuthenticated = { authCount.increment() }

        let task = Task { await conn.start() }

        // First connection: start auth but don't complete
        try await server.awaitRegisterCount(1, timeout: 3)
        try await Task.sleep(for: .milliseconds(200))
        server.simulatePeerJoin()
        try await Task.sleep(for: .milliseconds(300))
        #expect(authCount.value == 0, "Auth should not complete without server responding")

        // DO hits unexpected error → close(1011)
        server.closeWebSocket(code: 1011, reason: "Internal error")

        // Reconnect, enable auto-auth, complete auth
        try await server.awaitConnectionCount(3, timeout: 5)
        server.autoAuthPeer = true
        try await Task.sleep(for: .milliseconds(200))
        server.simulatePeerJoin()

        try await awaitCondition(timeout: 5) { authCount.value >= 1 }
        #expect(authCount.value == 1, "Auth should complete after server close recovery")

        task.cancel()
        await task.value
        conn.disconnect()
    }

    // MARK: - P2: Auth cycle

    @Test("Disconnect → reconnect → re-authenticate")
    func testDisconnectReconnectReAuth() async throws {
        let server = MockRelayServer(roomSecret: "secret", pairingToken: testPairingToken)
        let authCount = Counter()

        let conn = RelayConnection(
            serverURL: "ws://localhost:9999",
            workDir: "/tmp",
            crypto: SessionCrypto(),
            roomID: "TEST01",
            roomSecret: "secret",
            configDir: makeTempDirWithPairingToken(),
            wsFactory: {
                let ws = MockWebSocket()
                server.attach(to: ws)
                return ws
            },
            heartbeatInterval: 30,
            heartbeatAckTimeout: 60
        )

        conn.secretRotated = true
        conn.onPeerAuthenticated = { authCount.increment() }

        let task = Task { await conn.start() }

        // Wait for registration, then peer join + auth
        try await server.awaitRegisterCount(1, timeout: 3)
        try await Task.sleep(for: .milliseconds(200))
        server.simulatePeerJoin()
        try await awaitCondition(timeout: 5) { authCount.value >= 1 }

        // Force disconnect → reconnect
        server.forceDisconnect()
        try await server.awaitConnectionCount(3, timeout: 5)

        // Second peer join + auth
        try await Task.sleep(for: .milliseconds(200))
        server.simulatePeerJoin()
        try await awaitCondition(timeout: 5) { authCount.value >= 2 }

        #expect(authCount.value >= 2, "onPeerAuthenticated should fire twice")

        task.cancel()
        await task.value
        conn.disconnect()
    }

    @Test("Disconnect mid-auth → reconnect → complete auth without stale state")
    func testMidAuthDisconnect() async throws {
        let server = MockRelayServer(roomSecret: "secret", pairingToken: testPairingToken)
        server.autoAuthPeer = false  // Don't auto-complete auth on first attempt

        let authCount = Counter()

        let conn = RelayConnection(
            serverURL: "ws://localhost:9999",
            workDir: "/tmp",
            crypto: SessionCrypto(),
            roomID: "TEST01",
            roomSecret: "secret",
            configDir: makeTempDirWithPairingToken(),
            wsFactory: {
                let ws = MockWebSocket()
                server.attach(to: ws)
                return ws
            },
            heartbeatInterval: 30,
            heartbeatAckTimeout: 60
        )

        conn.secretRotated = true
        conn.onPeerAuthenticated = { authCount.increment() }

        let task = Task { await conn.start() }

        // Wait for registration, then peer join (auth will start but not complete)
        try await server.awaitRegisterCount(1, timeout: 3)
        try await Task.sleep(for: .milliseconds(200))
        server.simulatePeerJoin()
        try await Task.sleep(for: .milliseconds(500))

        // Auth should NOT have completed
        #expect(authCount.value == 0, "Auth should not complete without server responding")

        // Force disconnect mid-auth
        server.forceDisconnect()
        try await server.awaitConnectionCount(3, timeout: 5)

        // Enable auto-auth for the second attempt
        server.autoAuthPeer = true
        try await Task.sleep(for: .milliseconds(200))
        server.simulatePeerJoin()

        try await awaitCondition(timeout: 5) { authCount.value >= 1 }
        #expect(authCount.value == 1, "Auth should complete on second attempt")

        task.cancel()
        await task.value
        conn.disconnect()
    }

    @Test("Peer disconnect → peer rejoin → re-auth (WS stays connected)")
    func testPeerDisconnectReconnectReAuth() async throws {
        let server = MockRelayServer(roomSecret: "secret", pairingToken: testPairingToken)
        let authCount = Counter()
        let peerDisconnected = Counter()

        let conn = RelayConnection(
            serverURL: "ws://localhost:9999",
            workDir: "/tmp",
            crypto: SessionCrypto(),
            roomID: "TEST01",
            roomSecret: "secret",
            configDir: makeTempDirWithPairingToken(),
            wsFactory: {
                let ws = MockWebSocket()
                server.attach(to: ws)
                return ws
            },
            heartbeatInterval: 30,
            heartbeatAckTimeout: 60
        )

        conn.secretRotated = true
        conn.onPeerAuthenticated = { authCount.increment() }
        conn.onPeerDisconnected = { peerDisconnected.increment() }

        let task = Task { await conn.start() }

        // First auth
        try await server.awaitRegisterCount(1, timeout: 3)
        try await Task.sleep(for: .milliseconds(200))
        server.simulatePeerJoin()
        try await awaitCondition(timeout: 5) { authCount.value >= 1 }

        // Peer disconnects (WS stays up)
        server.simulatePeerDisconnect()
        try await awaitCondition(timeout: 2) { peerDisconnected.value >= 1 }

        // Peer rejoins — same WS connection, new auth
        try await Task.sleep(for: .milliseconds(200))
        server.simulatePeerJoin()
        try await awaitCondition(timeout: 5) { authCount.value >= 2 }

        // WS should NOT have reconnected (only 1 register)
        // connectionCount == 2 means: 1 from init + 1 from connectAndRun (no extra reconnect)
        #expect(server.connectionCount == 2,
                "WS should stay connected (no reconnect), connectionCount=\(server.connectionCount)")
        #expect(authCount.value >= 2, "onPeerAuthenticated should fire twice")

        task.cancel()
        await task.value
        conn.disconnect()
    }

    // MARK: - P3: Stability

    @Test("Multiple rapid reconnect cycles with re-auth")
    func testMultipleRapidReconnectCycles() async throws {
        let server = MockRelayServer(roomSecret: "secret", pairingToken: testPairingToken)
        let authCount = Counter()

        let conn = RelayConnection(
            serverURL: "ws://localhost:9999",
            workDir: "/tmp",
            crypto: SessionCrypto(),
            roomID: "TEST01",
            roomSecret: "secret",
            configDir: makeTempDirWithPairingToken(),
            wsFactory: {
                let ws = MockWebSocket()
                server.attach(to: ws)
                return ws
            },
            heartbeatInterval: 30,
            heartbeatAckTimeout: 60
        )

        conn.secretRotated = true
        conn.onPeerAuthenticated = { authCount.increment() }

        let task = Task { await conn.start() }

        // connectionCount starts at 2 (1 from init + 1 from first connectAndRun)
        for cycle in 1...3 {
            try await server.awaitConnectionCount(cycle + 1, timeout: 5)
            try await Task.sleep(for: .milliseconds(200))
            server.simulatePeerJoin()
            try await awaitCondition(timeout: 5) { authCount.value >= cycle }
            server.forceDisconnect()
        }

        // Final cycle: auth without disconnect
        try await server.awaitConnectionCount(5, timeout: 5)
        try await Task.sleep(for: .milliseconds(200))
        server.simulatePeerJoin()
        try await awaitCondition(timeout: 5) { authCount.value >= 4 }

        #expect(authCount.value == 4, "Should auth 4 times, got \(authCount.value)")

        task.cancel()
        await task.value
        conn.disconnect()
    }

    @Test("Consecutive register failures then recovery")
    func testConsecutiveFailuresThenRecovery() async throws {
        let server = MockRelayServer(roomSecret: "secret", pairingToken: testPairingToken)
        server.autoRespondRoomRegistered = false

        let registered = Flag()
        let times = TimestampList()

        let conn = RelayConnection(
            serverURL: "ws://localhost:9999",
            workDir: "/tmp",
            crypto: SessionCrypto(),
            roomID: "TEST01",
            roomSecret: "secret",
            configDir: makeTempDirWithPairingToken(),
            wsFactory: {
                times.append(Date())
                let ws = MockWebSocket()
                server.attach(to: ws)
                return ws
            },
            heartbeatInterval: 30,
            heartbeatAckTimeout: 60,
            registerTimeout: 0.5
        )

        conn.onRoomRegistered = { registered.value = true }

        let task = Task { await conn.start() }

        // Wait for 3 failed register attempts
        try await server.awaitRegisterCount(3, timeout: 10)

        // Verify backoff is growing
        let all = times.values
        if all.count >= 4 {
            // times[0] is from init wsFactory, times[1..] are from reconnect loop
            let delay1 = all[2].timeIntervalSince(all[1])
            let delay2 = all[3].timeIntervalSince(all[2])
            #expect(delay2 > delay1 * 0.8,
                    "Backoff should grow: delay1=\(delay1), delay2=\(delay2)")
        }

        // Enable auto-respond → next attempt should succeed
        server.autoRespondRoomRegistered = true
        try await awaitCondition(timeout: 10) { registered.value }

        #expect(registered.value, "Should eventually register after recovery")

        task.cancel()
        await task.value
        conn.disconnect()
    }

    // MARK: - Tier rejection recovery

    @Test("HTTP 403 retries with long backoff, then recovers after tier upgrade")
    func testHTTP403RetriesWithLongBackoffThenRecovers() async throws {
        let server = MockRelayServer(roomSecret: "secret", pairingToken: testPairingToken)
        let registered = Counter()
        let connectTimes = TimestampList()
        let httpError = Counter() // tracks how many 403 connect attempts

        // Track whether to fail with 403 (thread-safe via Flag)
        let shouldFail403 = Flag()
        shouldFail403.value = true

        let conn = RelayConnection(
            serverURL: "ws://localhost:9999",
            workDir: "/tmp",
            crypto: SessionCrypto(),
            roomID: "TEST01",
            roomSecret: "secret",
            configDir: makeTempDirWithPairingToken(),
            wsFactory: {
                let ws = MockWebSocket()
                if shouldFail403.value {
                    ws.httpErrorOnConnect = 403
                }
                server.attach(to: ws)
                return ws
            },
            heartbeatInterval: 30,
            heartbeatAckTimeout: 60,
            tierRetryInterval: 1.0  // 1s for fast tests
        )

        conn.onRoomRegistered = { registered.increment() }

        let startTime = Date()
        let task = Task { await conn.start() }

        // Wait for the tier retry delay to pass (~1s) — the second attempt should take ≥0.8s from start
        try await Task.sleep(for: .seconds(0.5))
        // At 0.5s, agent should still be waiting (not yet retried) since tierRetryInterval=1s
        #expect(registered.value == 0, "Should not have connected yet during tier backoff")

        // "Upgrade tier" — clear the 403 error
        shouldFail403.value = false

        // Should eventually connect and register (after the remaining ~0.5s of the backoff)
        try await awaitCondition(timeout: 5) { registered.value >= 1 }

        let totalDelay = Date().timeIntervalSince(startTime)
        #expect(totalDelay >= 0.8, "Should wait ~1s (tierRetryInterval) before retrying, took \(totalDelay)s")
        #expect(registered.value >= 1, "Should register after tier upgrade")

        task.cancel()
        await task.value
        conn.disconnect()
    }

    @Test("quota_exceeded triggers long backoff then recovers")
    func testQuotaExceededLongBackoffThenRecovers() async throws {
        let server = MockRelayServer(roomSecret: "secret", pairingToken: testPairingToken)
        let registered = Counter()
        let connectTimes = TimestampList()

        let conn = RelayConnection(
            serverURL: "ws://localhost:9999",
            workDir: "/tmp",
            crypto: SessionCrypto(),
            roomID: "TEST01",
            roomSecret: "secret",
            configDir: makeTempDirWithPairingToken(),
            wsFactory: {
                connectTimes.append(Date())
                let ws = MockWebSocket()
                server.attach(to: ws)
                return ws
            },
            heartbeatInterval: 30,
            heartbeatAckTimeout: 60,
            tierRetryInterval: 1.0  // 1s for fast tests
        )

        conn.onRoomRegistered = { registered.increment() }

        let task = Task { await conn.start() }

        // Wait for first registration
        try await awaitCondition(timeout: 3) { registered.value >= 1 }

        let countBefore = connectTimes.values.count
        let timeBefore = Date()

        // Server sends quota_exceeded → should disconnect and retry with long backoff
        server.sendQuotaExceeded()

        // Wait for reconnect attempt
        try await awaitCondition(timeout: 5) { connectTimes.values.count > countBefore }

        // Verify the delay was ~1s (tierRetryInterval), not the normal 0.5s backoff
        let delay = Date().timeIntervalSince(timeBefore)
        #expect(delay >= 0.8, "Should use tierRetryInterval (~1s), got \(delay)s")

        // Should re-register on reconnect
        try await awaitCondition(timeout: 3) { registered.value >= 2 }
        #expect(registered.value >= 2, "Should re-register after quota_exceeded recovery")

        task.cancel()
        await task.value
        conn.disconnect()
    }

    @Test("Multiple consecutive quota_exceeded keeps retrying with long backoff")
    func testMultipleQuotaExceededKeepsRetrying() async throws {
        let server = MockRelayServer(roomSecret: "secret", pairingToken: testPairingToken)
        let registered = Counter()
        let connectTimes = TimestampList()

        let conn = RelayConnection(
            serverURL: "ws://localhost:9999",
            workDir: "/tmp",
            crypto: SessionCrypto(),
            roomID: "TEST01",
            roomSecret: "secret",
            configDir: makeTempDirWithPairingToken(),
            wsFactory: {
                connectTimes.append(Date())
                let ws = MockWebSocket()
                server.attach(to: ws)
                return ws
            },
            heartbeatInterval: 30,
            heartbeatAckTimeout: 60,
            tierRetryInterval: 1.0  // 1s for fast tests
        )

        conn.onRoomRegistered = { registered.increment() }

        let task = Task { await conn.start() }

        // Wait for first registration
        try await awaitCondition(timeout: 3) { registered.value >= 1 }

        // First quota_exceeded
        let time1 = Date()
        server.sendQuotaExceeded()

        // Wait for reconnect
        try await awaitCondition(timeout: 5) { registered.value >= 2 }
        let delay1 = Date().timeIntervalSince(time1)
        #expect(delay1 >= 0.8, "First retry should use tierRetryInterval (~1s), got \(delay1)s")

        // Second quota_exceeded
        let time2 = Date()
        server.sendQuotaExceeded()

        // Wait for second reconnect
        try await awaitCondition(timeout: 5) { registered.value >= 3 }
        let delay2 = Date().timeIntervalSince(time2)
        #expect(delay2 >= 0.8, "Second retry should also use tierRetryInterval (~1s), got \(delay2)s")

        // Third connect succeeds (no quota_exceeded) — verify stable
        #expect(registered.value >= 3, "Should have registered 3 times after 2 quota_exceeded + recovery")

        task.cancel()
        await task.value
        conn.disconnect()
    }

    @Test("Quota enforced → set-tier upgrade during backoff → recovers with full peer auth")
    func testQuotaEnforcedThenTierUpgradeRecoversWithAuth() async throws {
        let server = MockRelayServer(roomSecret: "secret", pairingToken: testPairingToken)
        server.enforceQuota = true // auto quota_exceeded after registration

        let registered = Counter()
        let authCount = Counter()

        let conn = RelayConnection(
            serverURL: "ws://localhost:9999",
            workDir: "/tmp",
            crypto: SessionCrypto(),
            roomID: "TEST01",
            roomSecret: "secret",
            configDir: makeTempDirWithPairingToken(),
            wsFactory: {
                let ws = MockWebSocket()
                server.attach(to: ws)
                return ws
            },
            heartbeatInterval: 30,
            heartbeatAckTimeout: 60,
            tierRetryInterval: 1.0
        )

        conn.secretRotated = true
        conn.onRoomRegistered = { registered.increment() }
        conn.onPeerAuthenticated = { authCount.increment() }

        let startTime = Date()
        let task = Task { await conn.start() }

        // Agent connects → registers → gets quota_exceeded → disconnects
        try await awaitCondition(timeout: 3) { registered.value >= 1 }

        // "Admin runs set-tier to upgrade" — clear quota enforcement during backoff
        try await Task.sleep(for: .seconds(0.3))
        server.enforceQuota = false

        // Agent retries after tierRetryInterval (~1s), now succeeds
        try await awaitCondition(timeout: 5) { registered.value >= 2 }

        let recoveryTime = Date().timeIntervalSince(startTime)
        #expect(recoveryTime >= 0.8,
                "Recovery should take ~tierRetryInterval (1s), got \(recoveryTime)s")

        // Verify full operational recovery: peer join + mutual auth
        try await Task.sleep(for: .seconds(0.2))
        server.simulatePeerJoin()
        try await awaitCondition(timeout: 5) { authCount.value >= 1 }

        #expect(authCount.value >= 1,
                "Peer auth should work after quota recovery")

        task.cancel()
        await task.value
        conn.disconnect()
    }

    @Test("HTTP 403 room limit → set-tier upgrade during backoff → recovers with full peer auth")
    func testRoomLimitThenTierUpgradeRecoversWithAuth() async throws {
        let server = MockRelayServer(roomSecret: "secret", pairingToken: testPairingToken)
        let registered = Counter()
        let authCount = Counter()
        let shouldFail403 = Flag()
        shouldFail403.value = true

        let conn = RelayConnection(
            serverURL: "ws://localhost:9999",
            workDir: "/tmp",
            crypto: SessionCrypto(),
            roomID: "TEST01",
            roomSecret: "secret",
            configDir: makeTempDirWithPairingToken(),
            wsFactory: {
                let ws = MockWebSocket()
                if shouldFail403.value {
                    ws.httpErrorOnConnect = 403
                }
                server.attach(to: ws)
                return ws
            },
            heartbeatInterval: 30,
            heartbeatAckTimeout: 60,
            tierRetryInterval: 1.0
        )

        conn.secretRotated = true
        conn.onRoomRegistered = { registered.increment() }
        conn.onPeerAuthenticated = { authCount.increment() }

        let startTime = Date()
        let task = Task { await conn.start() }

        // "Admin runs set-tier to raise room limit" — clear 403 during backoff
        try await Task.sleep(for: .seconds(0.3))
        shouldFail403.value = false

        // Agent retries after tierRetryInterval (~1s), now succeeds
        try await awaitCondition(timeout: 5) { registered.value >= 1 }

        let recoveryTime = Date().timeIntervalSince(startTime)
        #expect(recoveryTime >= 0.8,
                "Recovery should take ~tierRetryInterval (1s), got \(recoveryTime)s")

        // Verify full operational recovery: peer join + mutual auth
        try await Task.sleep(for: .seconds(0.2))
        server.simulatePeerJoin()
        try await awaitCondition(timeout: 5) { authCount.value >= 1 }

        #expect(authCount.value >= 1,
                "Peer auth should work after room limit recovery")

        task.cancel()
        await task.value
        conn.disconnect()
    }

    @Test("HTTP 401 retries 3 times then fires onTokenInvalid")
    func testHTTP401InvalidTokenExitsLoop() async throws {
        let server = MockRelayServer(roomSecret: "secret", pairingToken: testPairingToken)
        let tokenInvalid = Flag()
        let connectCount = Counter()

        let conn = RelayConnection(
            serverURL: "ws://localhost:9999",
            workDir: "/tmp",
            crypto: SessionCrypto(),
            roomID: "TEST01",
            roomSecret: "secret",
            configDir: makeTempDirWithPairingToken(),
            wsFactory: {
                connectCount.increment()
                let ws = MockWebSocket()
                ws.httpErrorOnConnect = 401
                server.attach(to: ws)
                return ws
            },
            heartbeatInterval: 30,
            heartbeatAckTimeout: 60,
            auth401RetryDelay: 0.1
        )

        conn.onTokenInvalid = { tokenInvalid.value = true }

        // start() should return after 3 transient retries + 1 final 401
        let task = Task { await conn.start() }

        try await awaitCondition(timeout: 5) { tokenInvalid.value }

        #expect(tokenInvalid.value, "onTokenInvalid should fire after 3 transient 401 retries")
        // wsFactory: 1 init + 4 in loop (3 retries + 1 final) = 5 total
        #expect(connectCount.value == 5, "Should attempt 4 connects in loop (3 retries + 1 final), got \(connectCount.value)")

        task.cancel()
        await task.value
        conn.disconnect()
    }

    @Test("Transient 401 recovers without firing onTokenInvalid")
    func testHTTP401TransientRecovery() async throws {
        let server = MockRelayServer(roomSecret: "secret", pairingToken: testPairingToken)
        let tokenInvalid = Flag()
        let registered = Counter()
        var callIndex = 0
        let callLock = NSLock()

        let conn = RelayConnection(
            serverURL: "ws://localhost:9999",
            workDir: "/tmp",
            crypto: SessionCrypto(),
            roomID: "TEST01",
            roomSecret: "secret",
            configDir: makeTempDirWithPairingToken(),
            wsFactory: {
                callLock.lock()
                callIndex += 1
                let idx = callIndex
                callLock.unlock()
                let ws = MockWebSocket()
                // First call is init (idx=1), second is first connect attempt (idx=2) → 401
                // Third is retry (idx=3) → success
                if idx == 2 {
                    ws.httpErrorOnConnect = 401
                }
                server.attach(to: ws)
                return ws
            },
            heartbeatInterval: 30,
            heartbeatAckTimeout: 60,
            auth401RetryDelay: 0.1
        )

        conn.onTokenInvalid = { tokenInvalid.value = true }
        conn.onRoomRegistered = { registered.increment() }

        let task = Task { await conn.start() }

        // Should recover and register successfully
        try await awaitCondition(timeout: 5) { registered.value >= 1 }
        #expect(!tokenInvalid.value, "onTokenInvalid should NOT fire on transient 401")
        #expect(registered.value >= 1, "Should register after recovery")

        task.cancel()
        await task.value
        conn.disconnect()
    }

    @Test("Heartbeat resumes after reconnect — no second timeout")
    func testHeartbeatResumesAfterReconnect() async throws {
        let server = MockRelayServer(roomSecret: "secret", pairingToken: testPairingToken)
        let registered = Counter()

        let conn = RelayConnection(
            serverURL: "ws://localhost:9999",
            workDir: "/tmp",
            crypto: SessionCrypto(),
            roomID: "TEST01",
            roomSecret: "secret",
            configDir: makeTempDirWithPairingToken(),
            wsFactory: {
                let ws = MockWebSocket()
                server.attach(to: ws)
                return ws
            },
            heartbeatInterval: 0.3,
            heartbeatAckTimeout: 0.8
        )

        conn.onRoomRegistered = { registered.increment() }

        let task = Task { await conn.start() }

        // Wait for first registration
        try await awaitCondition(timeout: 3) { registered.value >= 1 }

        // Stop ACKs → timeout → reconnect
        server.stopHeartbeatAcks()
        try await awaitCondition(timeout: 5) { registered.value >= 2 }

        // Resume ACKs — connection should stabilize
        server.resumeHeartbeatAcks()
        let regAfterResume = registered.value

        // Wait long enough for another potential timeout cycle
        try await Task.sleep(for: .seconds(2))

        #expect(registered.value == regAfterResume,
                "Should not reconnect again after ACKs resume, got \(registered.value) vs \(regAfterResume)")

        task.cancel()
        await task.value
        conn.disconnect()
    }

    // MARK: - Dynamic heartbeat interval

    @Test("touchUserActivity triggers 1s heartbeat instead of default")
    func testTouchUserActivityTriggers1sHeartbeat() async throws {
        let server = MockRelayServer(roomSecret: "secret", pairingToken: testPairingToken)
        let registered = Counter()

        let conn = RelayConnection(
            serverURL: "ws://localhost:9999",
            workDir: "/tmp",
            crypto: SessionCrypto(),
            roomID: "TEST01",
            roomSecret: "secret",
            configDir: makeTempDirWithPairingToken(),
            wsFactory: {
                let ws = MockWebSocket()
                server.attach(to: ws)
                return ws
            },
            heartbeatInterval: 30,
            heartbeatAckTimeout: 60
        )

        conn.onRoomRegistered = { registered.increment() }

        // Set activity BEFORE start so the first heartbeat iteration uses 1s
        conn.touchUserActivity()

        let task = Task { await conn.start() }

        // Wait for registration
        try await awaitCondition(timeout: 3) { registered.value >= 1 }
        let hbAfterRegister = server.heartbeatCount

        // Wait 3s — with 1s active interval, expect ≥2 heartbeats
        try await Task.sleep(for: .seconds(3))

        let newHeartbeats = server.heartbeatCount - hbAfterRegister
        #expect(newHeartbeats >= 2,
                "Active heartbeat should use 1s interval, got \(newHeartbeats) heartbeats in 3s")

        task.cancel()
        await task.value
        conn.disconnect()
    }

    @Test("Peer authenticated triggers 1s heartbeat instead of default")
    func testPeerAuthenticatedTriggers1sHeartbeat() async throws {
        let server = MockRelayServer(roomSecret: "secret", pairingToken: testPairingToken)
        let registered = Counter()
        let authCount = Counter()

        let conn = RelayConnection(
            serverURL: "ws://localhost:9999",
            workDir: "/tmp",
            crypto: SessionCrypto(),
            roomID: "TEST01",
            roomSecret: "secret",
            configDir: makeTempDirWithPairingToken(),
            wsFactory: {
                let ws = MockWebSocket()
                server.attach(to: ws)
                return ws
            },
            heartbeatInterval: 3,
            heartbeatAckTimeout: 60
        )

        conn.onRoomRegistered = { registered.increment() }
        conn.secretRotated = true
        conn.onPeerAuthenticated = { authCount.increment() }

        let task = Task { await conn.start() }

        // Wait for registration, then peer join + auth
        try await awaitCondition(timeout: 3) { registered.value >= 1 }
        try await Task.sleep(for: .milliseconds(200))
        server.simulatePeerJoin()
        try await awaitCondition(timeout: 5) { authCount.value >= 1 }

        // Record heartbeat count after auth
        let hbAfterAuth = server.heartbeatCount

        // Wait 5s — first iteration may still be on 3s sleep, but subsequent ones at 1s.
        // With peer auth (1s): expect heartbeats at ~T+remaining, T+1, T+2, ... → ≥3
        // Without (3s): at ~T+remaining, T+3 → ≤2
        try await Task.sleep(for: .seconds(5))

        let newHeartbeats = server.heartbeatCount - hbAfterAuth
        #expect(newHeartbeats >= 3,
                "Peer connected should use 1s heartbeat, got \(newHeartbeats) heartbeats in 5s")

        task.cancel()
        await task.value
        conn.disconnect()
    }

    // MARK: - Pairing: peerIsReconnecting uses roomSecret for auth

    @Test("Reconnecting peer (TOFU match) authenticates with roomSecret, not activePairingToken")
    func testReconnectingPeerUsesRoomSecret() async throws {
        let roomSecret = "reconnect-secret"
        let server = MockRelayServer(roomSecret: roomSecret, pairingToken: roomSecret)
        let authCount = Counter()
        let configDir = makeTempDirWithPairingToken()

        let conn = RelayConnection(
            serverURL: "ws://localhost:9999",
            workDir: "/tmp",
            crypto: SessionCrypto(),
            roomID: "RECONN1",
            roomSecret: roomSecret,
            configDir: configDir,
            wsFactory: {
                let ws = MockWebSocket()
                server.attach(to: ws)
                return ws
            },
            heartbeatInterval: 30,
            heartbeatAckTimeout: 60
        )
        // Pre-set activePairingToken to roomSecret so MockRelayServer's HMAC matches for first pairing
        conn.activePairingToken = roomSecret
        // Skip secret rotation so roomSecret stays unchanged (MockRelayServer uses it for HMAC)
        conn.secretRotated = true
        conn.onPeerAuthenticated = { authCount.increment() }

        let task = Task { await conn.start() }

        // Wait for registration and first pairing (writes known_ios.pub via TOFU)
        try await server.awaitRegisterCount(1)
        server.simulatePeerJoin()
        try await server.awaitAuthenticated()
        #expect(authCount.value >= 1)

        // Simulate peer disconnect (preserve crypto for reconnect with same identity)
        server.simulatePeerDisconnect(preserveCrypto: true)
        try await Task.sleep(for: .milliseconds(100))

        // Set activePairingToken to a DIFFERENT value (simulating refreshPairingToken)
        conn.activePairingToken = "completely-different-token-T2"

        // Reconnect with SAME crypto (TOFU match) — should auth with roomSecret, not T2
        server.simulatePeerReconnect()
        try await server.awaitAuthCount(2)
        #expect(authCount.value >= 2, "Reconnecting peer should authenticate using roomSecret")

        task.cancel()
        await task.value
        conn.disconnect()
    }

    @Test("Re-pairing same device (TOFU match) with new pairing token succeeds")
    func testRePairingSameDeviceWithNewPairingToken() async throws {
        let roomSecret = "re-pair-secret"
        let pairingToken1 = "pairing-token-1"
        let pairingToken2 = "pairing-token-2"
        let server = MockRelayServer(roomSecret: roomSecret, pairingToken: testPairingToken)
        let authCount = Counter()
        let configDir = makeTempDirWithPairingToken()

        let conn = RelayConnection(
            serverURL: "ws://localhost:9999",
            workDir: "/tmp",
            crypto: SessionCrypto(),
            roomID: "REPAIR1",
            roomSecret: roomSecret,
            configDir: configDir,
            wsFactory: {
                let ws = MockWebSocket()
                server.attach(to: ws)
                return ws
            },
            heartbeatInterval: 30,
            heartbeatAckTimeout: 60
        )
        // First pairing with token1
        conn.activePairingToken = pairingToken1
        server.authKeyOverride = pairingToken1
        conn.secretRotated = true
        conn.onPeerAuthenticated = { authCount.increment() }

        let task = Task { await conn.start() }

        // Wait for registration and first pairing (writes known_ios.pub via TOFU)
        try await server.awaitRegisterCount(1)
        server.simulatePeerJoin()
        try await server.awaitAuthenticated()
        #expect(authCount.value >= 1, "First pairing should succeed")

        // Simulate peer disconnect
        server.simulatePeerDisconnect(preserveCrypto: true)
        try await Task.sleep(for: .milliseconds(100))

        // Now re-pair with a DIFFERENT pairing token (simulates new QR code scan)
        conn.activePairingToken = pairingToken2
        server.authKeyOverride = pairingToken2

        // Reconnect with SAME crypto (TOFU match) but using new pairing token
        server.simulatePeerReconnect()
        try await server.awaitAuthCount(2)
        #expect(authCount.value >= 2, "Re-pairing same device with new pairing token should succeed")

        task.cancel()
        await task.value
        conn.disconnect()
    }

    // MARK: - Pairing: deferred secret rotation until ack

    @Test("Secret rotation deferred until rotateSecretAck — onPairingComplete fires")
    func testDeferredSecretRotation() async throws {
        let roomSecret = "rotate-secret"
        let server = MockRelayServer(roomSecret: roomSecret, pairingToken: roomSecret)
        let pairingComplete = Flag()
        let secretRotated = Flag()

        let conn = RelayConnection(
            serverURL: "ws://localhost:9999",
            workDir: "/tmp",
            crypto: SessionCrypto(),
            roomID: "ROTATE1",
            roomSecret: roomSecret,
            configDir: makeTempDirWithPairingToken(),
            wsFactory: {
                let ws = MockWebSocket()
                server.attach(to: ws)
                return ws
            },
            heartbeatInterval: 30,
            heartbeatAckTimeout: 60
        )
        // Pre-set activePairingToken to roomSecret so first pairing auth succeeds
        conn.activePairingToken = roomSecret
        conn.onPeerAuthenticated = {}
        conn.onPairingComplete = { pairingComplete.value = true }
        conn.onSecretRotated = { _ in secretRotated.value = true }

        let task = Task { await conn.start() }

        // Wait for registration
        try await server.awaitRegisterCount(1)

        // Initial pairing — MockRelayServer auto-responds to rotateSecret with rotateSecretAck
        server.simulatePeerJoin()
        try await server.awaitAuthenticated()

        // Wait for the full rotation cycle (rotateSecret → rotateSecretAck → commit)
        try await awaitCondition(timeout: 5) { pairingComplete.value }

        #expect(secretRotated.value, "onSecretRotated should fire after ack")
        #expect(conn.roomSecret != roomSecret, "roomSecret should change after ack")
        #expect(conn.secretRotated, "secretRotated should be true after ack")

        task.cancel()
        await task.value
        conn.disconnect()
    }
}
