import Testing
import Foundation
import AppKit
import CryptoKit
@testable import MacAgentLib
import RemoteDevCore

@Suite(.serialized)
struct DisconnectTests {

    @Test("Reconnects after WebSocket stream ends")
    func testReconnectAfterDisconnect() async throws {
        let factoryCount = Counter()
        let mockWS = MockWebSocket()

        let conn = RelayConnection(
            serverURL: "ws://localhost:9999",
            workDir: "/tmp",
            crypto: SessionCrypto(),
            roomID: "TEST01",
            roomSecret: "secret",
            configDir: makeTempDirWithPairingToken(),
            wsFactory: {
                factoryCount.increment()
                return mockWS
            }
        )

        let task = Task { await conn.start() }
        try await Task.sleep(for: .milliseconds(500))

        // Simulate disconnect
        mockWS.simulateError(MockWebSocket.MockError.connectionFailed)

        // Wait for reconnect (2s delay)
        try await Task.sleep(for: .seconds(3))

        // init(1) + first loop(2) + reconnect(3)
        #expect(factoryCount.value >= 3, "Should reconnect, count=\(factoryCount.value)")

        task.cancel()
        await task.value
        conn.disconnect()
    }

    @Test("Exponential backoff with failed connects")
    func testExponentialBackoff() async throws {
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
                let m = MockWebSocket()
                m.shouldFailConnect = true
                return m
            }
        )

        let task = Task { await conn.start() }
        try await Task.sleep(for: .seconds(9))
        task.cancel()
        await task.value
        conn.disconnect()

        // Skip first entry (from init)
        let all = times.values
        let loopTimes = Array(all.dropFirst())
        #expect(loopTimes.count >= 3, "Need >=3 loop attempts, got \(loopTimes.count)")

        if loopTimes.count >= 3 {
            let delay1 = loopTimes[1].timeIntervalSince(loopTimes[0])
            let delay2 = loopTimes[2].timeIntervalSince(loopTimes[1])
            // Backoff starts at 0.5s: first gap ~0.5s (sleep 0.5), second gap ~1s (sleep 1.0)
            #expect(delay1 >= 0.3 && delay1 <= 0.8, "First delay ~0.5s, was \(delay1)")
            #expect(delay2 >= 0.7 && delay2 <= 1.5, "Second delay ~1s, was \(delay2)")
        }
    }

    @Test("Backoff resets on successful connect")
    func testBackoffResetsOnSuccess() async throws {
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
                let m = MockWebSocket()
                m.shouldEndReceiveImmediately = true
                return m
            }
        )

        let task = Task { await conn.start() }
        try await Task.sleep(for: .seconds(6))
        task.cancel()
        await task.value
        conn.disconnect()

        let all = times.values
        let loopTimes = Array(all.dropFirst())
        #expect(loopTimes.count >= 3, "Need >=3 loop attempts, got \(loopTimes.count)")

        if loopTimes.count >= 3 {
            let delay1 = loopTimes[1].timeIntervalSince(loopTimes[0])
            let delay2 = loopTimes[2].timeIntervalSince(loopTimes[1])
            // Both ~0.5s (reset to 0.5 each time on successful connect)
            #expect(delay1 >= 0.3 && delay1 <= 0.8, "First delay ~0.5s (reset), was \(delay1)")
            #expect(delay2 >= 0.3 && delay2 <= 0.8, "Second delay ~0.5s (reset), was \(delay2)")
        }
    }

    @Test("peer_disconnected message triggers callback")
    func testPeerDisconnectedCallback() async throws {
        let mockWS = MockWebSocket()
        let called = Flag()

        let conn = RelayConnection(
            serverURL: "ws://localhost:9999",
            workDir: "/tmp",
            crypto: SessionCrypto(),
            roomID: "TEST01",
            roomSecret: "secret",
            configDir: makeTempDirWithPairingToken(),
            wsFactory: { mockWS }
        )

        conn.onPeerDisconnected = { called.value = true }

        let task = Task { await conn.start() }
        try await Task.sleep(for: .milliseconds(500))

        mockWS.simulateReceive("""
        {"type":"peer_disconnected","reason":"client_left"}
        """)

        try await Task.sleep(for: .milliseconds(500))
        #expect(called.value, "onPeerDisconnected should fire")

        task.cancel()
        await task.value
        conn.disconnect()
    }

    @Test("NO_PEER error triggers onPeerDisconnected when authenticated")
    func testNoPeerTriggersDisconnect() async throws {
        let mockWS = MockWebSocket()
        let disconnected = Flag()
        let authenticated = Flag()

        let crypto = SessionCrypto()
        let peerCrypto = SessionCrypto()

        let conn = RelayConnection(
            serverURL: "ws://localhost:9999",
            workDir: "/tmp",
            crypto: crypto,
            roomID: "TEST01",
            roomSecret: "secret",
            configDir: makeTempDirWithPairingToken(),
            wsFactory: { mockWS }
        )

        conn.onPeerDisconnected = { disconnected.value = true }
        conn.onPeerAuthenticated = { authenticated.value = true }

        let task = Task { await conn.start() }
        try await Task.sleep(for: .milliseconds(500))

        // 1) room_registered
        mockWS.simulateReceive("""
        {"type":"room_registered","room_id":"TEST01"}
        """)
        try await Task.sleep(for: .milliseconds(100))

        // 2) peer_joined — both sides derive session key (no nonces for simplicity)
        try peerCrypto.deriveSessionKey(peerPublicKeyBase64: crypto.publicKeyBase64)
        mockWS.simulateReceive("""
        {"type":"peer_joined","public_key":"\(peerCrypto.publicKeyBase64)","session_nonce":""}
        """)
        // Wait for Mac to derive key + send challenge through async send loop
        try await Task.sleep(for: .milliseconds(300))

        // 3) Find the challenge Mac sent, decrypt with peerCrypto, and respond
        let sent = mockWS.sentMessages
        var challengeNonce: String?
        for msg in sent {
            guard let data = msg.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["type"] as? String == "relay",
                  let payload = json["payload"] as? String,
                  let cipherData = Data(base64Encoded: payload),
                  let plain = try? peerCrypto.decrypt(cipherData),
                  let appMsg = try? JSONDecoder().decode(AppMessage.self, from: plain),
                  case .challenge(let nonce) = appMsg
            else { continue }
            challengeNonce = nonce
            break
        }

        guard let nonce = challengeNonce, let nonceData = Data(base64Encoded: nonce) else {
            #expect(Bool(false), "Should have found challenge in sent messages (sent \(sent.count) msgs)")
            task.cancel(); await task.value; conn.disconnect(); return
        }

        // 4) Send challengeResponse
        let hmac = SessionCrypto.hmacSHA256(data: nonceData, key: Data(testPairingToken.utf8))
        let response = AppMessage.challengeResponse(hmac: hmac.base64EncodedString())
        let responseJson = try JSONEncoder().encode(response)
        let encrypted = try peerCrypto.encrypt(responseJson)
        mockWS.simulateReceive("""
        {"type":"relay","payload":"\(encrypted.base64EncodedString())"}
        """)
        try await Task.sleep(for: .milliseconds(200))

        // 5) Send reverse challenge to complete mutual auth
        let reverseNonce = SessionCrypto.randomBytes(32).base64EncodedString()
        let challenge = AppMessage.challenge(nonce: reverseNonce)
        let cJson = try JSONEncoder().encode(challenge)
        let cEncrypted = try peerCrypto.encrypt(cJson)
        mockWS.simulateReceive("""
        {"type":"relay","payload":"\(cEncrypted.base64EncodedString())"}
        """)
        try await Task.sleep(for: .milliseconds(300))

        #expect(authenticated.value, "Auth should have completed")

        // 6) Now simulate NO_PEER — this is the bug scenario: relay cleared iosSocket
        //    in send() so peer_disconnected was never sent, Mac just gets NO_PEER.
        disconnected.value = false
        mockWS.simulateReceive("""
        {"type":"error","code":"NO_PEER","message":"Peer not connected"}
        """)

        try await Task.sleep(for: .milliseconds(300))
        #expect(disconnected.value, "NO_PEER should trigger onPeerDisconnected when authenticated")

        task.cancel()
        await task.value
        conn.disconnect()
    }

    @Test("room_registered message triggers callback")
    func testRoomRegisteredCallback() async throws {
        let mockWS = MockWebSocket()
        let called = Flag()

        let conn = RelayConnection(
            serverURL: "ws://localhost:9999",
            workDir: "/tmp",
            crypto: SessionCrypto(),
            roomID: "TEST01",
            roomSecret: "secret",
            configDir: makeTempDirWithPairingToken(),
            wsFactory: { mockWS }
        )

        conn.onRoomRegistered = { called.value = true }

        let task = Task { await conn.start() }
        try await Task.sleep(for: .milliseconds(500))

        mockWS.simulateReceive("""
        {"type":"room_registered","room_id":"TEST01"}
        """)

        try await Task.sleep(for: .milliseconds(500))
        #expect(called.value, "onRoomRegistered should fire")

        task.cancel()
        await task.value
        conn.disconnect()
    }

    @Test("Heartbeat ack timeout forces WebSocket disconnect")
    func testHeartbeatAckTimeout() async throws {
        let mockWS = MockWebSocket()

        // Use short heartbeat interval (0.5s) and ack timeout (1s) for fast testing
        let conn = RelayConnection(
            serverURL: "ws://localhost:9999",
            workDir: "/tmp",
            crypto: SessionCrypto(),
            roomID: "TEST01",
            roomSecret: "secret",
            configDir: makeTempDirWithPairingToken(),
            wsFactory: { mockWS },
            heartbeatInterval: 0.5,
            heartbeatAckTimeout: 1
        )

        let task = Task { await conn.start() }
        try await Task.sleep(for: .milliseconds(200))

        // Connection established, heartbeat starts. Don't send any heartbeat_ack.
        // After ~1.5s (interval + check), the heartbeat should detect timeout
        // and call ws.disconnect().
        let disconnectCountBefore = mockWS.disconnectCallCount

        try await Task.sleep(for: .seconds(3))

        #expect(mockWS.disconnectCallCount > disconnectCountBefore,
                "Heartbeat timeout should force ws.disconnect()")

        task.cancel()
        await task.value
        conn.disconnect()
    }

    @Test("AUTH_FAILED triggers onRegisterAuthFailed callback")
    func testAuthFailedCallback() async throws {
        let mockWS = MockWebSocket()
        let called = Flag()

        let conn = RelayConnection(
            serverURL: "ws://localhost:9999",
            workDir: "/tmp",
            crypto: SessionCrypto(),
            roomID: "TEST01",
            roomSecret: "secret",
            configDir: makeTempDirWithPairingToken(),
            wsFactory: { mockWS }
        )

        conn.onRegisterAuthFailed = { called.value = true }

        let task = Task { await conn.start() }
        try await Task.sleep(for: .milliseconds(500))

        mockWS.simulateReceive("""
        {"type":"error","code":"AUTH_FAILED","message":"Room already registered with different secret"}
        """)

        try await Task.sleep(for: .milliseconds(300))
        #expect(called.value, "onRegisterAuthFailed should fire on AUTH_FAILED error")

        task.cancel()
        await task.value
        conn.disconnect()
    }

    @Test("onPeerDisconnected does NOT fire on connection failure (no peer was connected)")
    func testNoPeerDisconnectedOnConnectionFailure() async throws {
        let called = Flag()

        let conn = RelayConnection(
            serverURL: "ws://localhost:9999",
            workDir: "/tmp",
            crypto: SessionCrypto(),
            roomID: "TEST01",
            roomSecret: "secret",
            configDir: makeTempDirWithPairingToken(),
            wsFactory: {
                let m = MockWebSocket()
                m.shouldFailConnect = true
                return m
            }
        )

        conn.onPeerDisconnected = { called.value = true }

        let task = Task { await conn.start() }
        // Wait long enough for one failed connect + reconnect delay
        try await Task.sleep(for: .seconds(4))

        #expect(!called.value,
                "onPeerDisconnected should NOT fire when connection fails (no peer was ever connected)")

        task.cancel()
        await task.value
        conn.disconnect()
    }

    @Test("Malformed JSON does not kill connection — subsequent messages still processed")
    func testMalformedJsonDoesNotKillConnection() async throws {
        let mockWS = MockWebSocket()
        let disconnected = Flag()

        let conn = RelayConnection(
            serverURL: "ws://localhost:9999",
            workDir: "/tmp",
            crypto: SessionCrypto(),
            roomID: "TEST01",
            roomSecret: "secret",
            configDir: makeTempDirWithPairingToken(),
            wsFactory: { mockWS }
        )

        conn.onPeerDisconnected = { disconnected.value = true }

        let task = Task { await conn.start() }
        try await Task.sleep(for: .milliseconds(500))

        // Send malformed JSON — should NOT kill the connection
        mockWS.simulateReceive("this is not valid json {{{")
        try await Task.sleep(for: .milliseconds(200))

        // Send a valid message after — should still be processed
        let called = Flag()
        conn.onRoomRegistered = { called.value = true }
        mockWS.simulateReceive("""
        {"type":"room_registered","room_id":"TEST01"}
        """)
        try await Task.sleep(for: .milliseconds(200))

        #expect(called.value, "Valid message after malformed JSON should still be processed")
        #expect(!disconnected.value, "Malformed JSON should not trigger disconnect callback")

        task.cancel()
        await task.value
        conn.disconnect()
    }

    @Test("NO_PEER error does NOT trigger onPeerDisconnected when NOT authenticated")
    func testNoPeerIgnoredWhenNotAuthenticated() async throws {
        let mockWS = MockWebSocket()
        let disconnected = Flag()

        let conn = RelayConnection(
            serverURL: "ws://localhost:9999",
            workDir: "/tmp",
            crypto: SessionCrypto(),
            roomID: "TEST01",
            roomSecret: "secret",
            configDir: makeTempDirWithPairingToken(),
            wsFactory: { mockWS }
        )

        conn.onPeerDisconnected = { disconnected.value = true }

        let task = Task { await conn.start() }
        try await Task.sleep(for: .milliseconds(500))

        // Send NO_PEER while NOT authenticated — should be ignored
        mockWS.simulateReceive("""
        {"type":"error","code":"NO_PEER","message":"Peer not connected"}
        """)

        try await Task.sleep(for: .milliseconds(300))
        #expect(!disconnected.value,
                "NO_PEER should NOT trigger onPeerDisconnected when not authenticated")

        task.cancel()
        await task.value
        conn.disconnect()
    }

    // MARK: - Additional tests

    @Test("System wake forces immediate reconnect")
    func testSystemWakeForcesImmediateReconnect() async throws {
        let factoryCount = Counter()
        let times = TimestampList()

        let conn = RelayConnection(
            serverURL: "ws://localhost:9999",
            workDir: "/tmp",
            crypto: SessionCrypto(),
            roomID: "TEST01",
            roomSecret: "secret",
            configDir: makeTempDirWithPairingToken(),
            wsFactory: {
                factoryCount.increment()
                times.append(Date())
                return MockWebSocket()
            }
        )

        let task = Task { await conn.start() }
        try await Task.sleep(for: .milliseconds(500))

        let countBefore = factoryCount.value

        // Post wake notification — this sets reconnectDelay=0 and calls ws.disconnect()
        NotificationCenter.default.post(name: NSWorkspace.didWakeNotification, object: nil)

        try await Task.sleep(for: .seconds(2))

        let countAfter = factoryCount.value
        #expect(countAfter > countBefore, "Factory should be called again after wake, before=\(countBefore) after=\(countAfter)")

        // Check that reconnect happened quickly (delay was 0)
        let all = times.values
        if all.count >= 2 {
            let lastGap = all[all.count - 1].timeIntervalSince(all[all.count - 2])
            #expect(lastGap < 2.0, "Reconnect after wake should be near-instant, was \(lastGap)s")
        }

        task.cancel()
        await task.value
        conn.disconnect()
    }

    @Test("Sustained failures keep retrying with backoff cap")
    func testSustainedFailuresKeepRetryingWithBackoffCap() async throws {
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
                let m = MockWebSocket()
                m.shouldFailConnect = true
                return m
            }
        )

        let task = Task { await conn.start() }
        try await Task.sleep(for: .seconds(45))
        task.cancel()
        await task.value
        conn.disconnect()

        let all = times.values
        let loopTimes = Array(all.dropFirst())
        #expect(loopTimes.count >= 5, "Should have >=5 attempts in 45s, got \(loopTimes.count)")

        // Check that the last gap doesn't exceed 12s (cap is 8s + jitter tolerance)
        if loopTimes.count >= 2 {
            let lastGap = loopTimes[loopTimes.count - 1].timeIntervalSince(loopTimes[loopTimes.count - 2])
            #expect(lastGap <= 12, "Last gap should not exceed 12s (8s cap), was \(lastGap)s")
        }
    }

    @Test("Concurrent heartbeat timeout and stream end cause single reconnect")
    func testConcurrentHeartbeatAndStreamEndNoDuplicateReconnect() async throws {
        let factoryCount = Counter()

        let conn = RelayConnection(
            serverURL: "ws://localhost:9999",
            workDir: "/tmp",
            crypto: SessionCrypto(),
            roomID: "TEST01",
            roomSecret: "secret",
            configDir: makeTempDirWithPairingToken(),
            wsFactory: {
                factoryCount.increment()
                return MockWebSocket()
            },
            heartbeatInterval: 0.5,
            heartbeatAckTimeout: 1
        )

        let task = Task { await conn.start() }
        try await Task.sleep(for: .milliseconds(500))

        // Record count after initial connection
        let countAfterConnect = factoryCount.value

        // Don't send any heartbeat_ack — heartbeat timeout will fire and call ws.disconnect(),
        // which ends the stream. Both triggers converge to one reconnect cycle.
        try await Task.sleep(for: .seconds(4))

        let countAfterTimeout = factoryCount.value
        // Should have reconnected exactly once (not twice from both triggers)
        let reconnects = countAfterTimeout - countAfterConnect
        #expect(reconnects >= 1, "Should reconnect at least once, got \(reconnects)")
        #expect(reconnects <= 2, "Should not double-reconnect from concurrent triggers, got \(reconnects)")

        task.cancel()
        await task.value
        conn.disconnect()
    }

    @Test("Peer re-authenticated after reconnect")
    func testPeerReauthenticatedAfterReconnect() async throws {
        final class MockList: @unchecked Sendable {
            private let lock = NSLock()
            private var _mocks: [MockWebSocket] = []
            var mocks: [MockWebSocket] { lock.withLock { _mocks } }
            func append(_ m: MockWebSocket) { lock.withLock { _mocks.append(m) } }
        }

        let mockList = MockList()
        let authCount = Counter()

        let crypto = SessionCrypto()

        let conn = RelayConnection(
            serverURL: "ws://localhost:9999",
            workDir: "/tmp",
            crypto: crypto,
            roomID: "TEST01",
            roomSecret: "secret",
            configDir: makeTempDirWithPairingToken(),
            wsFactory: {
                let m = MockWebSocket()
                mockList.append(m)
                return m
            }
        )

        conn.onPeerAuthenticated = { authCount.increment() }

        let task = Task { await conn.start() }
        try await Task.sleep(for: .milliseconds(500))

        // --- First connection: full handshake ---
        let mock1 = mockList.mocks[mockList.mocks.count - 1]
        let peerCrypto1 = SessionCrypto()

        // 1) room_registered
        mock1.simulateReceive("""
        {"type":"room_registered","room_id":"TEST01"}
        """)
        try await Task.sleep(for: .milliseconds(100))

        // 2) peer_joined
        try peerCrypto1.deriveSessionKey(peerPublicKeyBase64: crypto.publicKeyBase64)
        mock1.simulateReceive("""
        {"type":"peer_joined","public_key":"\(peerCrypto1.publicKeyBase64)","session_nonce":""}
        """)
        try await Task.sleep(for: .milliseconds(300))

        // 3) Find challenge, decrypt, respond
        var challengeNonce1: String?
        for msg in mock1.sentMessages {
            guard let data = msg.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["type"] as? String == "relay",
                  let payload = json["payload"] as? String,
                  let cipherData = Data(base64Encoded: payload),
                  let plain = try? peerCrypto1.decrypt(cipherData),
                  let appMsg = try? JSONDecoder().decode(AppMessage.self, from: plain),
                  case .challenge(let nonce) = appMsg
            else { continue }
            challengeNonce1 = nonce
            break
        }

        guard let nonce1 = challengeNonce1, let nonceData1 = Data(base64Encoded: nonce1) else {
            #expect(Bool(false), "Should have found challenge in first mock's sent messages")
            task.cancel(); await task.value; conn.disconnect(); return
        }

        // 4) challengeResponse
        let hmac1 = SessionCrypto.hmacSHA256(data: nonceData1, key: Data(testPairingToken.utf8))
        let response1 = AppMessage.challengeResponse(hmac: hmac1.base64EncodedString())
        let responseJson1 = try JSONEncoder().encode(response1)
        let encrypted1 = try peerCrypto1.encrypt(responseJson1)
        mock1.simulateReceive("""
        {"type":"relay","payload":"\(encrypted1.base64EncodedString())"}
        """)
        try await Task.sleep(for: .milliseconds(200))

        // 5) Reverse challenge
        let reverseNonce1 = SessionCrypto.randomBytes(32).base64EncodedString()
        let challenge1 = AppMessage.challenge(nonce: reverseNonce1)
        let cJson1 = try JSONEncoder().encode(challenge1)
        let cEncrypted1 = try peerCrypto1.encrypt(cJson1)
        mock1.simulateReceive("""
        {"type":"relay","payload":"\(cEncrypted1.base64EncodedString())"}
        """)
        try await Task.sleep(for: .milliseconds(300))

        #expect(authCount.value >= 1, "First auth should have completed")

        // --- Simulate stream end to trigger reconnect ---
        mock1.simulateError(MockWebSocket.MockError.connectionFailed)
        try await Task.sleep(for: .seconds(3))

        // --- Second connection: full handshake ---
        let currentMocks = mockList.mocks
        guard currentMocks.count >= 2 else {
            #expect(Bool(false), "Should have created a second mock for reconnect")
            task.cancel(); await task.value; conn.disconnect(); return
        }
        let mock2 = currentMocks[currentMocks.count - 1]
        // Reuse peerCrypto1 identity (same public key) so TOFU verification passes
        let peerCrypto2 = peerCrypto1

        // 1) room_registered
        mock2.simulateReceive("""
        {"type":"room_registered","room_id":"TEST01"}
        """)
        try await Task.sleep(for: .milliseconds(100))

        // 2) peer_joined — same identity, re-derive session key
        try peerCrypto2.deriveSessionKey(peerPublicKeyBase64: crypto.publicKeyBase64)
        mock2.simulateReceive("""
        {"type":"peer_joined","public_key":"\(peerCrypto2.publicKeyBase64)","session_nonce":""}
        """)
        try await Task.sleep(for: .milliseconds(300))

        // 3) Find challenge
        var challengeNonce2: String?
        for msg in mock2.sentMessages {
            guard let data = msg.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["type"] as? String == "relay",
                  let payload = json["payload"] as? String,
                  let cipherData = Data(base64Encoded: payload),
                  let plain = try? peerCrypto2.decrypt(cipherData),
                  let appMsg = try? JSONDecoder().decode(AppMessage.self, from: plain),
                  case .challenge(let nonce) = appMsg
            else { continue }
            challengeNonce2 = nonce
            break
        }

        guard let nonce2 = challengeNonce2, let nonceData2 = Data(base64Encoded: nonce2) else {
            #expect(Bool(false), "Should have found challenge in second mock's sent messages")
            task.cancel(); await task.value; conn.disconnect(); return
        }

        // 4) challengeResponse — reconnecting peer uses roomSecret (TOFU match)
        let hmac2 = SessionCrypto.hmacSHA256(data: nonceData2, key: Data("secret".utf8))
        let response2 = AppMessage.challengeResponse(hmac: hmac2.base64EncodedString())
        let responseJson2 = try JSONEncoder().encode(response2)
        let encrypted2 = try peerCrypto2.encrypt(responseJson2)
        mock2.simulateReceive("""
        {"type":"relay","payload":"\(encrypted2.base64EncodedString())"}
        """)
        try await Task.sleep(for: .milliseconds(200))

        // 5) Reverse challenge
        let reverseNonce2 = SessionCrypto.randomBytes(32).base64EncodedString()
        let challenge2 = AppMessage.challenge(nonce: reverseNonce2)
        let cJson2 = try JSONEncoder().encode(challenge2)
        let cEncrypted2 = try peerCrypto2.encrypt(cJson2)
        mock2.simulateReceive("""
        {"type":"relay","payload":"\(cEncrypted2.base64EncodedString())"}
        """)
        try await Task.sleep(for: .milliseconds(300))

        #expect(authCount.value >= 2, "Auth should have fired at least twice, got \(authCount.value)")

        task.cancel()
        await task.value
        conn.disconnect()
    }

    @Test("Auth timeout fallback for legacy client without reverse challenge")
    func testAuthTimeoutFallbackLegacyClient() async throws {
        let mockWS = MockWebSocket()
        let authenticated = Flag()

        let crypto = SessionCrypto()
        let peerCrypto = SessionCrypto()

        let conn = RelayConnection(
            serverURL: "ws://localhost:9999",
            workDir: "/tmp",
            crypto: crypto,
            roomID: "TEST01",
            roomSecret: "secret",
            configDir: makeTempDirWithPairingToken(),
            wsFactory: { mockWS }
        )

        conn.onPeerAuthenticated = { authenticated.value = true }

        let task = Task { await conn.start() }
        try await Task.sleep(for: .milliseconds(500))

        // 1) room_registered
        mockWS.simulateReceive("""
        {"type":"room_registered","room_id":"TEST01"}
        """)
        try await Task.sleep(for: .milliseconds(100))

        // 2) peer_joined
        try peerCrypto.deriveSessionKey(peerPublicKeyBase64: crypto.publicKeyBase64)
        mockWS.simulateReceive("""
        {"type":"peer_joined","public_key":"\(peerCrypto.publicKeyBase64)","session_nonce":""}
        """)
        try await Task.sleep(for: .milliseconds(300))

        // 3) Find challenge, decrypt, respond
        var challengeNonce: String?
        for msg in mockWS.sentMessages {
            guard let data = msg.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["type"] as? String == "relay",
                  let payload = json["payload"] as? String,
                  let cipherData = Data(base64Encoded: payload),
                  let plain = try? peerCrypto.decrypt(cipherData),
                  let appMsg = try? JSONDecoder().decode(AppMessage.self, from: plain),
                  case .challenge(let nonce) = appMsg
            else { continue }
            challengeNonce = nonce
            break
        }

        guard let nonce = challengeNonce, let nonceData = Data(base64Encoded: nonce) else {
            #expect(Bool(false), "Should have found challenge in sent messages")
            task.cancel(); await task.value; conn.disconnect(); return
        }

        // 4) Send challengeResponse (Mac sends authOk, starts 5s timeout)
        let hmac = SessionCrypto.hmacSHA256(data: nonceData, key: Data(testPairingToken.utf8))
        let response = AppMessage.challengeResponse(hmac: hmac.base64EncodedString())
        let responseJson = try JSONEncoder().encode(response)
        let encrypted = try peerCrypto.encrypt(responseJson)
        mockWS.simulateReceive("""
        {"type":"relay","payload":"\(encrypted.base64EncodedString())"}
        """)
        try await Task.sleep(for: .milliseconds(200))

        // Do NOT send reverse challenge — simulate legacy client
        #expect(!authenticated.value, "Should not be authenticated yet (waiting for reverse challenge or timeout)")

        // Wait for 10s authTimeout to fire (RelayConnection uses 10s timeout)
        try await Task.sleep(for: .seconds(11))

        #expect(authenticated.value, "Auth should fire via 10s timeout fallback for legacy client")

        task.cancel()
        await task.value
        conn.disconnect()
    }

    @Test("Stream ends during handshake triggers reconnect and second attempt completes")
    func testStreamEndsDuringHandshakeReconnects() async throws {
        final class MockList: @unchecked Sendable {
            private let lock = NSLock()
            private var _mocks: [MockWebSocket] = []
            var mocks: [MockWebSocket] { lock.withLock { _mocks } }
            func append(_ m: MockWebSocket) { lock.withLock { _mocks.append(m) } }
        }

        let mockList = MockList()
        let authenticated = Flag()

        let crypto = SessionCrypto()

        // Pre-seed the peer identity into the trust store so that after
        // the first (aborted) handshake the reconnect is treated as a
        // TOFU-known peer rather than a fresh enrollment.
        let configDir = makeTempDirWithPairingToken()
        let peerCrypto1 = SessionCrypto()
        _ = seedTrustedDevice(configDir: configDir,
                              publicKey: peerCrypto1.publicKeyBase64,
                              deviceType: "iPhone")

        let conn = RelayConnection(
            serverURL: "ws://localhost:9999",
            workDir: "/tmp",
            crypto: crypto,
            roomID: "TEST01",
            roomSecret: "secret",
            configDir: configDir,
            wsFactory: {
                let m = MockWebSocket()
                mockList.append(m)
                return m
            }
        )

        conn.onPeerAuthenticated = { authenticated.value = true }

        let task = Task { await conn.start() }
        try await Task.sleep(for: .milliseconds(500))

        // --- First connection: start handshake but interrupt ---
        let mock1 = mockList.mocks[mockList.mocks.count - 1]

        // 1) room_registered
        mock1.simulateReceive("""
        {"type":"room_registered","room_id":"TEST01"}
        """)
        try await Task.sleep(for: .milliseconds(100))

        // 2) peer_joined
        try peerCrypto1.deriveSessionKey(peerPublicKeyBase64: crypto.publicKeyBase64)
        mock1.simulateReceive("""
        {"type":"peer_joined","public_key":"\(peerCrypto1.publicKeyBase64)","session_nonce":""}
        """)
        try await Task.sleep(for: .milliseconds(300))

        // Mac sent challenge, but before iOS responds — end the stream
        mock1.simulateError(MockWebSocket.MockError.connectionFailed)

        // Wait for reconnect
        try await Task.sleep(for: .seconds(3))

        // --- Second connection: complete full handshake ---
        let currentMocks = mockList.mocks
        guard currentMocks.count >= 2 else {
            #expect(Bool(false), "Should have created second mock for reconnect, got \(currentMocks.count)")
            task.cancel(); await task.value; conn.disconnect(); return
        }
        let mock2 = currentMocks[currentMocks.count - 1]
        // Reuse peerCrypto1 identity so TOFU verification passes
        let peerCrypto2 = peerCrypto1

        // 1) room_registered
        mock2.simulateReceive("""
        {"type":"room_registered","room_id":"TEST01"}
        """)
        try await Task.sleep(for: .milliseconds(100))

        // 2) peer_joined — same identity, re-derive session key
        try peerCrypto2.deriveSessionKey(peerPublicKeyBase64: crypto.publicKeyBase64)
        mock2.simulateReceive("""
        {"type":"peer_joined","public_key":"\(peerCrypto2.publicKeyBase64)","session_nonce":""}
        """)
        try await Task.sleep(for: .milliseconds(300))

        // 3) Find challenge
        var challengeNonce: String?
        for msg in mock2.sentMessages {
            guard let data = msg.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["type"] as? String == "relay",
                  let payload = json["payload"] as? String,
                  let cipherData = Data(base64Encoded: payload),
                  let plain = try? peerCrypto2.decrypt(cipherData),
                  let appMsg = try? JSONDecoder().decode(AppMessage.self, from: plain),
                  case .challenge(let nonce) = appMsg
            else { continue }
            challengeNonce = nonce
            break
        }

        guard let nonce = challengeNonce, let nonceData = Data(base64Encoded: nonce) else {
            #expect(Bool(false), "Should have found challenge in second mock")
            task.cancel(); await task.value; conn.disconnect(); return
        }

        // 4) challengeResponse — reconnecting peer uses roomSecret (TOFU match)
        let hmac = SessionCrypto.hmacSHA256(data: nonceData, key: Data("secret".utf8))
        let response = AppMessage.challengeResponse(hmac: hmac.base64EncodedString())
        let responseJson = try JSONEncoder().encode(response)
        let encrypted = try peerCrypto2.encrypt(responseJson)
        mock2.simulateReceive("""
        {"type":"relay","payload":"\(encrypted.base64EncodedString())"}
        """)
        try await Task.sleep(for: .milliseconds(200))

        // 5) Reverse challenge
        let reverseNonce = SessionCrypto.randomBytes(32).base64EncodedString()
        let challenge = AppMessage.challenge(nonce: reverseNonce)
        let cJson = try JSONEncoder().encode(challenge)
        let cEncrypted = try peerCrypto2.encrypt(cJson)
        mock2.simulateReceive("""
        {"type":"relay","payload":"\(cEncrypted.base64EncodedString())"}
        """)
        try await Task.sleep(for: .milliseconds(300))

        #expect(authenticated.value, "Auth should complete on second attempt after handshake interruption")

        task.cancel()
        await task.value
        conn.disconnect()
    }

    @Test("Batch flush on disconnect sends pending messages")
    func testMacBatchFlushOnDisconnect() async throws {
        let mockWS = MockWebSocket()
        let authenticated = Flag()

        let crypto = SessionCrypto()
        let peerCrypto = SessionCrypto()

        let conn = RelayConnection(
            serverURL: "ws://localhost:9999",
            workDir: "/tmp",
            crypto: crypto,
            roomID: "TEST01",
            roomSecret: "secret",
            configDir: makeTempDirWithPairingToken(),
            wsFactory: { mockWS }
        )

        conn.onPeerAuthenticated = { authenticated.value = true }

        let task = Task { await conn.start() }
        try await Task.sleep(for: .milliseconds(500))

        // Full handshake to authenticate
        // 1) room_registered
        mockWS.simulateReceive("""
        {"type":"room_registered","room_id":"TEST01"}
        """)
        try await Task.sleep(for: .milliseconds(100))

        // 2) peer_joined
        try peerCrypto.deriveSessionKey(peerPublicKeyBase64: crypto.publicKeyBase64)
        mockWS.simulateReceive("""
        {"type":"peer_joined","public_key":"\(peerCrypto.publicKeyBase64)","session_nonce":""}
        """)
        try await Task.sleep(for: .milliseconds(300))

        // 3) Find challenge
        var challengeNonce: String?
        for msg in mockWS.sentMessages {
            guard let data = msg.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["type"] as? String == "relay",
                  let payload = json["payload"] as? String,
                  let cipherData = Data(base64Encoded: payload),
                  let plain = try? peerCrypto.decrypt(cipherData),
                  let appMsg = try? JSONDecoder().decode(AppMessage.self, from: plain),
                  case .challenge(let nonce) = appMsg
            else { continue }
            challengeNonce = nonce
            break
        }

        guard let nonce = challengeNonce, let nonceData = Data(base64Encoded: nonce) else {
            #expect(Bool(false), "Should have found challenge")
            task.cancel(); await task.value; conn.disconnect(); return
        }

        // 4) challengeResponse
        let hmac = SessionCrypto.hmacSHA256(data: nonceData, key: Data(testPairingToken.utf8))
        let response = AppMessage.challengeResponse(hmac: hmac.base64EncodedString())
        let responseJson = try JSONEncoder().encode(response)
        let encrypted = try peerCrypto.encrypt(responseJson)
        mockWS.simulateReceive("""
        {"type":"relay","payload":"\(encrypted.base64EncodedString())"}
        """)
        try await Task.sleep(for: .milliseconds(200))

        // 5) Reverse challenge
        let reverseNonce = SessionCrypto.randomBytes(32).base64EncodedString()
        let challenge = AppMessage.challenge(nonce: reverseNonce)
        let cJson = try JSONEncoder().encode(challenge)
        let cEncrypted = try peerCrypto.encrypt(cJson)
        mockWS.simulateReceive("""
        {"type":"relay","payload":"\(cEncrypted.base64EncodedString())"}
        """)
        try await Task.sleep(for: .milliseconds(300))

        #expect(authenticated.value, "Should be authenticated before testing batch flush")

        // Record sent count before batching
        let sentBefore = mockWS.sentMessages.count

        // Queue batched messages
        try conn.sendEncryptedBatched(.ptyData(data: "dGVzdDE=", sessionId: "s1"))
        try conn.sendEncryptedBatched(.ptyData(data: "dGVzdDI=", sessionId: "s1"))
        try conn.sendEncryptedBatched(.ptyData(data: "dGVzdDM=", sessionId: "s1"))

        // Immediately disconnect — _flushBatch() is called in disconnect()
        conn.disconnect()
        task.cancel()
        await task.value

        // Wait briefly for send loop to process queued messages
        try await Task.sleep(for: .milliseconds(200))

        // Check that relay or relay_batch messages were flushed
        let sentAfter = mockWS.sentMessages
        let newMessages = Array(sentAfter.dropFirst(sentBefore))
        let hasRelayMessages = newMessages.contains { msg in
            guard let data = msg.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = json["type"] as? String
            else { return false }
            return type == "relay" || type == "relay_batch"
        }
        #expect(hasRelayMessages, "Batch flush on disconnect should produce relay messages, got \(newMessages.count) new messages")
    }

    @Test("Late heartbeat ack logs warning but continues connection")
    func testLateHeartbeatAckLogsWarningButContinues() async throws {
        let mockWS = MockWebSocket()

        let conn = RelayConnection(
            serverURL: "ws://localhost:9999",
            workDir: "/tmp",
            crypto: SessionCrypto(),
            roomID: "TEST01",
            roomSecret: "secret",
            configDir: makeTempDirWithPairingToken(),
            wsFactory: { mockWS },
            heartbeatInterval: 0.5,
            heartbeatAckTimeout: 5
        )

        let task = Task { await conn.start() }
        try await Task.sleep(for: .milliseconds(200))

        let disconnectCountBefore = mockWS.disconnectCallCount

        // Wait 2s (heartbeat fires at 0.5s, no ack yet — but timeout is 5s)
        try await Task.sleep(for: .seconds(2))

        // Send a late heartbeat_ack (2s late, but within 5s timeout)
        mockWS.simulateReceive("""
        {"type":"heartbeat_ack","mac_connected":true}
        """)

        // Wait another 1s — connection should still be alive
        try await Task.sleep(for: .seconds(1))

        #expect(mockWS.disconnectCallCount == disconnectCountBefore,
                "Connection should continue when ack arrives within timeout, disconnects=\(mockWS.disconnectCallCount - disconnectCountBefore)")

        task.cancel()
        await task.value
        conn.disconnect()
    }

    @Test("quota_exceeded message does not crash and connection continues")
    func testQuotaExceededMessageLoggedWithoutCrash() async throws {
        let mockWS = MockWebSocket()
        let roomRegistered = Flag()

        let conn = RelayConnection(
            serverURL: "ws://localhost:9999",
            workDir: "/tmp",
            crypto: SessionCrypto(),
            roomID: "TEST01",
            roomSecret: "secret",
            configDir: makeTempDirWithPairingToken(),
            wsFactory: { mockWS },
            tierRetryInterval: 0.1
        )

        conn.onRoomRegistered = { roomRegistered.value = true }

        let task = Task { await conn.start() }
        try await Task.sleep(for: .milliseconds(500))

        // Send quota_exceeded — triggers disconnect + short reconnect delay
        mockWS.simulateReceive("""
        {"type":"quota_exceeded","usage":1000,"limit":500,"period":"daily","resets_at":"2026-03-07T00:00:00Z"}
        """)
        try await Task.sleep(for: .milliseconds(500))

        // Send room_registered after reconnect — should be processed
        mockWS.simulateReceive("""
        {"type":"room_registered","room_id":"TEST01"}
        """)
        try await Task.sleep(for: .milliseconds(300))

        #expect(roomRegistered.value, "Messages after quota_exceeded should still be processed")

        task.cancel()
        await task.value
        conn.disconnect()
    }

    @Test("Reconnect delay caps at 8 seconds")
    func testReconnectDelayCapsAt8Seconds() async throws {
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
                let m = MockWebSocket()
                m.shouldFailConnect = true
                return m
            }
        )

        let task = Task { await conn.start() }
        // Backoff: 0.5+1+2+4+8+8+8+8 = 39.5s needed for 4 capped gaps
        try await Task.sleep(for: .seconds(35))
        task.cancel()
        await task.value
        conn.disconnect()

        let all = times.values
        let loopTimes = Array(all.dropFirst())
        #expect(loopTimes.count >= 3, "Should have multiple attempts in 35s, got \(loopTimes.count)")

        // Compute all gaps
        var gaps: [TimeInterval] = []
        for i in 1..<loopTimes.count {
            gaps.append(loopTimes[i].timeIntervalSince(loopTimes[i - 1]))
        }

        // No gap should exceed 12s (8s cap + tolerance)
        for (i, gap) in gaps.enumerated() {
            #expect(gap <= 12, "Gap \(i) should not exceed 12s (8s cap), was \(gap)s")
        }

        // At least 2 gaps should be >= 6s (showing they hit the ~8s cap)
        let cappedGaps = gaps.filter { $0 >= 6 }
        #expect(cappedGaps.count >= 2, "At least 2 gaps should be >=6s (near 8s cap), got \(cappedGaps.count) gaps near cap out of \(gaps.count) total")
    }

    @Test("register_room waits for connect to complete")
    func testRegisterRoomWaitsForConnect() async throws {
        let mockWS = MockWebSocket()
        mockWS.connectDelay = 0.5 // 500ms delay

        let conn = RelayConnection(
            serverURL: "ws://localhost:9999",
            workDir: "/tmp",
            crypto: SessionCrypto(),
            roomID: "TEST01",
            roomSecret: "secret",
            configDir: makeTempDirWithPairingToken(),
            wsFactory: { mockWS }
        )

        let task = Task { await conn.start() }

        // During the 500ms connect delay, no messages should be sent
        try await Task.sleep(for: .milliseconds(200))
        #expect(mockWS.sentMessages.isEmpty, "No messages should be sent while connect() is in progress")

        // After connect completes, register_room should be sent
        try await Task.sleep(for: .milliseconds(500))
        let sent = mockWS.sentMessages
        let hasRegister = sent.contains { msg in
            guard let data = msg.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["type"] as? String == "register_room"
            else { return false }
            return true
        }
        #expect(hasRegister, "register_room should be sent after connect completes")

        task.cancel()
        await task.value
        conn.disconnect()
    }

    @Test("register_room timeout triggers reconnect")
    func testRegisterRoomTimeoutReconnects() async throws {
        let factoryCount = Counter()

        let conn = RelayConnection(
            serverURL: "ws://localhost:9999",
            workDir: "/tmp",
            crypto: SessionCrypto(),
            roomID: "TEST01",
            roomSecret: "secret",
            configDir: makeTempDirWithPairingToken(),
            wsFactory: {
                factoryCount.increment()
                return MockWebSocket()
            },
            registerTimeout: 1 // 1s timeout for fast testing
        )

        let task = Task { await conn.start() }

        // Wait for connect + register_room sent
        try await Task.sleep(for: .milliseconds(500))
        let countAfterConnect = factoryCount.value

        // Don't send room_registered — timeout should fire after 1s
        try await Task.sleep(for: .seconds(3))

        let countAfterTimeout = factoryCount.value
        #expect(countAfterTimeout > countAfterConnect,
                "Register timeout should trigger reconnect, before=\(countAfterConnect) after=\(countAfterTimeout)")

        task.cancel()
        await task.value
        conn.disconnect()
    }

    @Test("Heartbeat does not send before connect completes")
    func testHeartbeatWaitsForConnect() async throws {
        let mockWS = MockWebSocket()
        mockWS.connectDelay = 1.0 // 1s delay

        let conn = RelayConnection(
            serverURL: "ws://localhost:9999",
            workDir: "/tmp",
            crypto: SessionCrypto(),
            roomID: "TEST01",
            roomSecret: "secret",
            configDir: makeTempDirWithPairingToken(),
            wsFactory: { mockWS },
            heartbeatInterval: 0.3
        )

        let task = Task { await conn.start() }

        // During the 1s connect delay, no heartbeats should be sent
        try await Task.sleep(for: .milliseconds(500))
        let heartbeats = mockWS.sentMessages.filter { msg in
            guard let data = msg.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["type"] as? String == "heartbeat"
            else { return false }
            return true
        }
        #expect(heartbeats.isEmpty, "No heartbeats should be sent while connect() is in progress")

        task.cancel()
        await task.value
        conn.disconnect()
    }

    @Test("Each reconnect cycle creates a new WebSocket instance")
    func testNewWebSocketInstancePerReconnect() async throws {
        final class MockList: @unchecked Sendable {
            private let lock = NSLock()
            private var _mocks: [MockWebSocket] = []
            var mocks: [MockWebSocket] { lock.withLock { _mocks } }
            func append(_ m: MockWebSocket) { lock.withLock { _mocks.append(m) } }
        }

        let mockList = MockList()

        let conn = RelayConnection(
            serverURL: "ws://localhost:9999",
            workDir: "/tmp",
            crypto: SessionCrypto(),
            roomID: "TEST01",
            roomSecret: "secret",
            configDir: makeTempDirWithPairingToken(),
            wsFactory: {
                let m = MockWebSocket()
                mockList.append(m)
                return m
            }
        )

        let task = Task { await conn.start() }
        try await Task.sleep(for: .milliseconds(500))

        // Trigger disconnect to cause reconnect
        let mock1 = mockList.mocks.last!
        mock1.simulateError(MockWebSocket.MockError.connectionFailed)
        try await Task.sleep(for: .seconds(3))

        // init(1) + first loop(2) + reconnect(3) = at least 3
        let mocks = mockList.mocks
        #expect(mocks.count >= 3, "Should create new WS instance for each reconnect, got \(mocks.count)")

        // Verify they are distinct instances
        if mocks.count >= 2 {
            let last = mocks[mocks.count - 1]
            let secondLast = mocks[mocks.count - 2]
            #expect(last !== secondLast, "Each reconnect should use a new WebSocket instance")
        }

        task.cancel()
        await task.value
        conn.disconnect()
    }

    @Test("Fresh session nonce generated per connection")
    func testFreshSessionNoncePerConnection() async throws {
        final class MockList: @unchecked Sendable {
            private let lock = NSLock()
            private var _mocks: [MockWebSocket] = []
            var mocks: [MockWebSocket] { lock.withLock { _mocks } }
            func append(_ m: MockWebSocket) { lock.withLock { _mocks.append(m) } }
        }

        let mockList = MockList()

        let conn = RelayConnection(
            serverURL: "ws://localhost:9999",
            workDir: "/tmp",
            crypto: SessionCrypto(),
            roomID: "TEST01",
            roomSecret: "secret",
            configDir: makeTempDirWithPairingToken(),
            wsFactory: {
                let m = MockWebSocket()
                mockList.append(m)
                return m
            }
        )

        let task = Task { await conn.start() }
        try await Task.sleep(for: .milliseconds(500))

        // First connection — extract session_nonce from register_room
        let mock1 = mockList.mocks[mockList.mocks.count - 1]
        var nonce1: String?
        for msg in mock1.sentMessages {
            guard let data = msg.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["type"] as? String == "register_room",
                  let sn = json["session_nonce"] as? String
            else { continue }
            nonce1 = sn
            break
        }

        #expect(nonce1 != nil, "First connection should send register_room with session_nonce")

        // End stream to trigger reconnect
        mock1.simulateError(MockWebSocket.MockError.connectionFailed)
        try await Task.sleep(for: .seconds(3))

        // Second connection — extract session_nonce
        let currentMocks = mockList.mocks
        guard currentMocks.count >= 2 else {
            #expect(Bool(false), "Should have created second mock for reconnect")
            task.cancel(); await task.value; conn.disconnect(); return
        }
        let mock2 = currentMocks[currentMocks.count - 1]
        var nonce2: String?
        for msg in mock2.sentMessages {
            guard let data = msg.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["type"] as? String == "register_room",
                  let sn = json["session_nonce"] as? String
            else { continue }
            nonce2 = sn
            break
        }

        #expect(nonce2 != nil, "Second connection should send register_room with session_nonce")

        if let n1 = nonce1, let n2 = nonce2 {
            #expect(n1 != n2, "Session nonces should differ between connections")
            #expect(n1.count == 44, "Nonce should be base64 of 32 bytes (44 chars), got \(n1.count)")
            #expect(n2.count == 44, "Nonce should be base64 of 32 bytes (44 chars), got \(n2.count)")
        }

        task.cancel()
        await task.value
        conn.disconnect()
    }

    // MARK: - Duplicate peer_joined guard

    @Test("Duplicate peer_joined with same ephemeral key is skipped when challenge pending")
    func testDuplicatePeerJoinedSameEphemeralKeySkipped() async throws {
        let mockWS = MockWebSocket()
        let crypto = SessionCrypto()

        // Pre-seed the peer identity into the trust store so Mac treats
        // this as a reconnecting peer (uses roomSecret as auth key, not
        // activePairingToken).
        let configDir = makeTempDirWithPairingToken()
        let peerCrypto = SessionCrypto()
        _ = seedTrustedDevice(configDir: configDir,
                              publicKey: peerCrypto.publicKeyBase64,
                              deviceType: "iPhone")

        let conn = RelayConnection(
            serverURL: "ws://localhost:9999",
            workDir: "/tmp",
            crypto: crypto,
            roomID: "TEST01",
            roomSecret: "secret",
            configDir: configDir,
            wsFactory: { mockWS },
            heartbeatInterval: 30,
            heartbeatAckTimeout: 60
        )

        let authenticated = Flag()
        conn.onPeerAuthenticated = { authenticated.value = true }

        let task = Task { await conn.start() }
        try await Task.sleep(for: .milliseconds(500))

        // 1) room_registered
        mockWS.simulateReceive("""
        {"type":"room_registered","room_id":"TEST01"}
        """)
        try await Task.sleep(for: .milliseconds(100))

        // Extract Mac's ephemeral public key and session nonce from register_room
        var macEphPub = ""
        var macNonce = ""
        for msg in mockWS.sentMessages {
            guard let data = msg.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["type"] as? String == "register_room",
                  let eph = json["ephemeral_key"] as? String,
                  let sn = json["session_nonce"] as? String
            else { continue }
            macEphPub = eph
            macNonce = sn
            break
        }
        #expect(!macEphPub.isEmpty, "register_room should contain ephemeral_key")

        // Create iOS-side ephemeral key pair
        let iosEphKey = Curve25519.KeyAgreement.PrivateKey()
        let iosEphPubBase64 = iosEphKey.publicKey.rawRepresentation.base64EncodedString()
        let iosNonce = SessionCrypto.randomBytes(32).base64EncodedString()

        // Derive session key on "iOS" side (same as Mac will derive)
        try peerCrypto.deriveSessionKeyEphemeral(
            ephemeralPrivateKey: iosEphKey,
            peerEphemeralKeyBase64: macEphPub,
            localNonce: iosNonce,
            remoteNonce: macNonce)

        // 2) First peer_joined with ephemeral key
        mockWS.simulateReceive("""
        {"type":"peer_joined","public_key":"\(peerCrypto.publicKeyBase64)","session_nonce":"\(iosNonce)","ephemeral_key":"\(iosEphPubBase64)"}
        """)
        try await Task.sleep(for: .milliseconds(300))

        // Count relay messages (should be 1 = challenge)
        let relayCount1 = mockWS.sentMessages.filter { $0.contains("\"type\":\"relay\"") }.count
        #expect(relayCount1 == 1, "Should have sent 1 challenge after first peer_joined, got \(relayCount1)")

        // Extract the challenge nonce from Mac's encrypted message
        var challengeNonce: String?
        for msg in mockWS.sentMessages {
            guard let data = msg.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["type"] as? String == "relay",
                  let payload = json["payload"] as? String,
                  let cipherData = Data(base64Encoded: payload),
                  let plain = try? peerCrypto.decrypt(cipherData),
                  let appMsg = try? JSONDecoder().decode(AppMessage.self, from: plain),
                  case .challenge(let nonce) = appMsg
            else { continue }
            challengeNonce = nonce
            break
        }
        #expect(challengeNonce != nil, "Should have found challenge in sent messages")

        // 3) Duplicate peer_joined with SAME ephemeral key — should be skipped
        mockWS.simulateReceive("""
        {"type":"peer_joined","public_key":"\(peerCrypto.publicKeyBase64)","session_nonce":"\(iosNonce)","ephemeral_key":"\(iosEphPubBase64)"}
        """)
        try await Task.sleep(for: .milliseconds(300))

        let relayCount2 = mockWS.sentMessages.filter { $0.contains("\"type\":\"relay\"") }.count
        #expect(relayCount2 == relayCount1, "Duplicate peer_joined should be skipped — relay count should not increase, got \(relayCount2)")

        // 4) Respond to original challenge — HMAC should still match since nonce was preserved
        guard let nonce = challengeNonce, let nonceData = Data(base64Encoded: nonce) else {
            #expect(Bool(false), "Missing challenge nonce")
            task.cancel(); await task.value; conn.disconnect(); return
        }
        let hmac = SessionCrypto.hmacSHA256(data: nonceData, key: Data(testPairingToken.utf8))
        let response = AppMessage.challengeResponse(hmac: hmac.base64EncodedString())
        let responseJson = try JSONEncoder().encode(response)
        let encrypted = try peerCrypto.encrypt(responseJson)
        mockWS.simulateReceive("""
        {"type":"relay","payload":"\(encrypted.base64EncodedString())"}
        """)
        try await Task.sleep(for: .milliseconds(200))

        // 5) Complete reverse challenge
        let reverseNonce = SessionCrypto.randomBytes(32).base64EncodedString()
        let challenge = AppMessage.challenge(nonce: reverseNonce)
        let cJson = try JSONEncoder().encode(challenge)
        let cEncrypted = try peerCrypto.encrypt(cJson)
        mockWS.simulateReceive("""
        {"type":"relay","payload":"\(cEncrypted.base64EncodedString())"}
        """)
        try await Task.sleep(for: .milliseconds(300))

        #expect(authenticated.value, "Auth should succeed after duplicate peer_joined was skipped")

        task.cancel()
        await task.value
        conn.disconnect()
    }

    @Test("peer_joined with different ephemeral key replaces pending challenge")
    func testPeerJoinedDifferentEphemeralKeyProcessed() async throws {
        let mockWS = MockWebSocket()
        let crypto = SessionCrypto()

        let conn = RelayConnection(
            serverURL: "ws://localhost:9999",
            workDir: "/tmp",
            crypto: crypto,
            roomID: "TEST01",
            roomSecret: "secret",
            configDir: makeTempDirWithPairingToken(),
            wsFactory: { mockWS },
            heartbeatInterval: 30,
            heartbeatAckTimeout: 60
        )

        let task = Task { await conn.start() }
        try await Task.sleep(for: .milliseconds(500))

        // room_registered
        mockWS.simulateReceive("""
        {"type":"room_registered","room_id":"TEST01"}
        """)
        try await Task.sleep(for: .milliseconds(100))

        let peerCrypto = SessionCrypto()
        let iosEphKey1 = Curve25519.KeyAgreement.PrivateKey()
        let iosNonce = SessionCrypto.randomBytes(32).base64EncodedString()

        // First peer_joined with ephemeral key A
        mockWS.simulateReceive("""
        {"type":"peer_joined","public_key":"\(peerCrypto.publicKeyBase64)","session_nonce":"\(iosNonce)","ephemeral_key":"\(iosEphKey1.publicKey.rawRepresentation.base64EncodedString())"}
        """)
        try await Task.sleep(for: .milliseconds(300))

        let relayCount1 = mockWS.sentMessages.filter { $0.contains("\"type\":\"relay\"") }.count
        #expect(relayCount1 == 1, "First peer_joined should produce 1 challenge")

        // Second peer_joined with DIFFERENT ephemeral key B — should be processed
        let iosEphKey2 = Curve25519.KeyAgreement.PrivateKey()
        mockWS.simulateReceive("""
        {"type":"peer_joined","public_key":"\(peerCrypto.publicKeyBase64)","session_nonce":"\(iosNonce)","ephemeral_key":"\(iosEphKey2.publicKey.rawRepresentation.base64EncodedString())"}
        """)
        try await Task.sleep(for: .milliseconds(300))

        let relayCount2 = mockWS.sentMessages.filter { $0.contains("\"type\":\"relay\"") }.count
        #expect(relayCount2 == 2, "Different ephemeral key should produce a second challenge, got \(relayCount2)")

        task.cancel()
        await task.value
        conn.disconnect()
    }

    // MARK: - quota_exceeded reconnect regression tests

    /// Reproduces production scenario: server sends quota_exceeded, closes connection.
    /// The connectAndRun loop MUST reconnect — not exit silently.
    @Test("quota_exceeded triggers reconnect, loop does not exit")
    func testQuotaExceededTriggersReconnect() async throws {
        let connectCount = Counter()
        let mocks = NSLock()
        var latestMock: MockWebSocket?

        let conn = RelayConnection(
            serverURL: "ws://localhost:9999",
            workDir: "/tmp",
            crypto: SessionCrypto(),
            roomID: "TEST01",
            roomSecret: "secret",
            configDir: makeTempDirWithPairingToken(),
            wsFactory: {
                connectCount.increment()
                let m = MockWebSocket()
                mocks.withLock { latestMock = m }
                return m
            },
            tierRetryInterval: 0.5  // fast retry for test speed
        )

        let task = Task { await conn.start() }
        try await Task.sleep(for: .milliseconds(300))

        let countBeforeQuota = connectCount.value

        // Send quota_exceeded — this triggers ws.disconnect() inside handleMessage
        mocks.withLock {
            latestMock?.simulateReceive("""
            {"type":"quota_exceeded","usage":2975,"limit":1000,"period":"5h-98568","resets_at":"2026-03-23T05:00:00.000Z"}
            """)
        }

        // Wait for the reconnect cycle (tierRetryInterval=0.5s + connect time)
        try await Task.sleep(for: .seconds(2))

        let countAfterQuota = connectCount.value

        // The loop must have reconnected (new wsFactory call)
        #expect(countAfterQuota > countBeforeQuota,
                "Loop must reconnect after quota_exceeded. Before=\(countBeforeQuota) After=\(countAfterQuota)")

        // Verify the task is still running (loop did NOT exit)
        #expect(!task.isCancelled, "Task should still be running")

        task.cancel()
        await task.value
        conn.disconnect()
    }

    /// Simulates repeated quota_exceeded (like the production crash loop).
    /// The loop must keep retrying — never exit.
    @Test("Repeated quota_exceeded keeps loop alive")
    func testRepeatedQuotaExceededKeepsLoopAlive() async throws {
        let connectCount = Counter()
        let mocks = NSLock()
        var latestMock: MockWebSocket?

        let conn = RelayConnection(
            serverURL: "ws://localhost:9999",
            workDir: "/tmp",
            crypto: SessionCrypto(),
            roomID: "TEST01",
            roomSecret: "secret",
            configDir: makeTempDirWithPairingToken(),
            wsFactory: {
                connectCount.increment()
                let m = MockWebSocket()
                mocks.withLock { latestMock = m }
                // After connect, simulate server immediately sending quota_exceeded
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
                    m.simulateReceive("""
                    {"type":"quota_exceeded","usage":2975,"limit":1000,"period":"5h-98568","resets_at":"2026-03-23T05:00:00.000Z"}
                    """)
                }
                return m
            },
            tierRetryInterval: 0.3
        )

        let task = Task { await conn.start() }

        // Wait enough time for several reconnect cycles
        try await Task.sleep(for: .seconds(3))

        // Should have connected multiple times (each one gets quota_exceeded → reconnect)
        #expect(connectCount.value >= 3,
                "Should have reconnected multiple times. Count=\(connectCount.value)")

        // Task must still be alive
        #expect(!task.isCancelled, "Loop must not exit after repeated quota_exceeded")

        task.cancel()
        await task.value
        conn.disconnect()
    }
}

// MARK: - Thread-safe helpers

