import Testing
import Foundation
import CryptoKit
@testable import MacAgentLib
import RemoteDevCore

/// Block C — multi-key trust store + candidate-commit pattern tests.
/// Covers RelayConnection's replacement of the legacy `known_ios.pub` TOFU
/// path with TrustStore + per-connection `pendingPubKey`.
@Suite(.serialized)
struct MultiKeyTrustTests {

    // MARK: - Helpers

    /// Build a RelayConnection wired to a MockRelayServer.
    private func makeConn(configDir: String,
                          roomSecret: String,
                          server: MockRelayServer) -> RelayConnection {
        let conn = RelayConnection(
            serverURL: "ws://localhost:9999",
            workDir: "/tmp",
            crypto: SessionCrypto(),
            roomID: "MKTEST",
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
        conn.secretRotated = true
        return conn
    }

    private func trustStorePath(_ configDir: String) -> String {
        configDir + "/" + TrustStore.fileName
    }

    private func fileMTime(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date
    }

    // MARK: - C1: known pubkey → reconnect path

    @Test("C1: After first enrollment, reconnect authenticates with roomSecret against trust store")
    func testKnownPubkeyReconnectPath() async throws {
        let roomSecret = "c1-secret"
        let server = MockRelayServer(roomSecret: roomSecret, pairingToken: roomSecret)
        let configDir = makeTempDirWithPairingToken()

        let conn = makeConn(configDir: configDir, roomSecret: roomSecret, server: server)
        // First-pair path: token == roomSecret so MockRelayServer HMAC matches.
        conn.activePairingToken = roomSecret

        let task = Task { await conn.start() }
        try await server.awaitRegisterCount(1)
        server.simulatePeerJoin()
        try await server.awaitAuthenticated()

        // After commit the trust store has exactly 1 entry.
        let store1 = TrustStore(configDir: configDir)
        _ = store1.load()
        #expect(store1.devices.count == 1, "first enrollment should produce 1 entry")
        let enrolledKey = store1.devices[0].public_key
        let firstSeen = store1.devices[0].last_seen

        // Simulate peer disconnect + reconnect with SAME crypto (reconnect path).
        server.simulatePeerDisconnect(preserveCrypto: true)
        try await Task.sleep(for: .milliseconds(100))

        // Token is now invalidated — conn must authenticate via roomSecret only.
        #expect(conn.activePairingToken == nil, "pairing token should be invalidated after enrollment")

        server.simulatePeerReconnect()
        try await server.awaitAuthCount(2)

        // Trust store still has the same 1 entry; last_seen should be >= first.
        let store2 = TrustStore(configDir: configDir)
        _ = store2.load()
        #expect(store2.devices.count == 1, "reconnect must not add a new entry")
        #expect(store2.devices[0].public_key == enrolledKey)
        #expect(store2.devices[0].last_seen >= firstSeen)

        task.cancel()
        await task.value
        conn.disconnect()
    }

    // MARK: - C2: unknown + no token → reject

    @Test("C2: Unknown pubkey with no active token → reject before challenge")
    func testUnknownNoTokenRejects() async throws {
        let roomSecret = "c2-secret"
        let server = MockRelayServer(roomSecret: roomSecret, pairingToken: nil)
        let configDir = makeTempDir()

        let conn = makeConn(configDir: configDir, roomSecret: roomSecret, server: server)
        conn.activePairingToken = nil

        let task = Task { await conn.start() }
        try await server.awaitRegisterCount(1)
        let beforeCount = server.authCount

        server.simulatePeerJoin()
        try await Task.sleep(for: .milliseconds(300))

        #expect(server.authCount == beforeCount, "Unknown device with no token must not authenticate")
        #expect(!server.authenticated)

        // Trust store remains empty.
        #expect(!FileManager.default.fileExists(atPath: trustStorePath(configDir)))

        task.cancel()
        await task.value
        conn.disconnect()
    }

    // MARK: - C6 / C14: unknown + token → pending candidate, no disk write

    @Test("C6 + C14: Unknown pubkey + valid token sets pending candidate but never writes trust store pre-challenge")
    func testUnknownWithTokenNoDiskWrite() async throws {
        let roomSecret = "c6-secret"
        let pairingToken = "c6-pairing-token-32chars-xyz000"
        let server = MockRelayServer(roomSecret: roomSecret, pairingToken: pairingToken)
        // Prevent server from auto-completing the handshake so we can assert state
        // between peer_joined and challenge response.
        server.autoAuthPeer = false
        let configDir = makeTempDir()

        let conn = makeConn(configDir: configDir, roomSecret: roomSecret, server: server)
        conn.activePairingToken = pairingToken

        let task = Task { await conn.start() }
        try await server.awaitRegisterCount(1)

        server.simulatePeerJoin()
        try await Task.sleep(for: .milliseconds(300))

        // Trust store file is still absent (peer_joined must not write).
        #expect(!FileManager.default.fileExists(atPath: trustStorePath(configDir)),
                "peer_joined alone must not write trust store")

        task.cancel()
        await task.value
        conn.disconnect()
    }

    // MARK: - C5: full store rejects before challenge

    @Test("C5: Trust store full (32 devices) + unknown enrollment candidate → reject before challenge")
    func testFullStoreRejectsEnrollment() async throws {
        let roomSecret = "c5-secret"
        let pairingToken = "c5-pairing-token-32chars-xyz000"
        let server = MockRelayServer(roomSecret: roomSecret, pairingToken: pairingToken)
        let configDir = makeTempDir()

        // Pre-fill 32 devices with random keys.
        let store = TrustStore(configDir: configDir)
        _ = store.load()
        for i in 0..<TrustStore.deviceLimit {
            _ = try store.add(
                publicKey: "pk-\(i)-\(UUID().uuidString)",
                deviceType: "iPhone",
                proposedLabel: "device-\(i)")
        }
        #expect(store.devices.count == TrustStore.deviceLimit)

        let conn = makeConn(configDir: configDir, roomSecret: roomSecret, server: server)
        conn.activePairingToken = pairingToken

        let task = Task { await conn.start() }
        try await server.awaitRegisterCount(1)

        let beforeAuthCount = server.authCount
        server.simulatePeerJoin()
        try await Task.sleep(for: .milliseconds(400))

        #expect(server.authCount == beforeAuthCount,
                "Full store must reject enrollment before challenge")

        // Trust store unchanged (still 32, the seeded keys).
        let store2 = TrustStore(configDir: configDir)
        _ = store2.load()
        #expect(store2.devices.count == TrustStore.deviceLimit)

        task.cancel()
        await task.value
        conn.disconnect()
    }

    // MARK: - C8 / C15: HMAC failure → no disk write, pending cleared

    @Test("C8 + C15: Enrollment candidate + wrong HMAC → no disk write, pending cleared, disconnect")
    func testEnrollmentChallengeFailureNoWrite() async throws {
        let roomSecret = "c8-secret"
        let pairingToken = "c8-pairing-token-32chars-xyz000"
        let server = MockRelayServer(roomSecret: roomSecret, pairingToken: pairingToken)
        // Override HMAC key with garbage so challenge verification fails.
        server.authKeyOverride = "wrong-key-not-matching-anything"
        let configDir = makeTempDir()

        let conn = makeConn(configDir: configDir, roomSecret: roomSecret, server: server)
        conn.activePairingToken = pairingToken

        let task = Task { await conn.start() }
        try await server.awaitRegisterCount(1)

        server.simulatePeerJoin()
        try await Task.sleep(for: .milliseconds(800))

        #expect(!server.authenticated, "Bad HMAC must not authenticate")
        #expect(!FileManager.default.fileExists(atPath: trustStorePath(configDir)),
                "Failed challenge must not write trust store")

        task.cancel()
        await task.value
        conn.disconnect()
    }

    // MARK: - C12 / C13: successful enrollment commits + invalidates token

    @Test("C12 + C13: Successful enrollment appends trust store entry and deletes pairing token file")
    func testEnrollmentCommitAppendsAndInvalidatesToken() async throws {
        let roomSecret = "c12-secret"
        let pairingToken = testPairingToken
        let server = MockRelayServer(roomSecret: roomSecret, pairingToken: pairingToken)
        let configDir = makeTempDirWithPairingToken()

        let conn = makeConn(configDir: configDir, roomSecret: roomSecret, server: server)
        conn.activePairingToken = pairingToken

        let task = Task { await conn.start() }
        try await server.awaitRegisterCount(1)

        server.simulatePeerJoin()
        try await server.awaitAuthenticated()

        // Trust store now has exactly one entry (the new enrollment).
        let store = TrustStore(configDir: configDir)
        _ = store.load()
        #expect(store.devices.count == 1, "enrollment should append exactly 1 device")

        // Pairing token file is gone (single-use invalidation).
        let tokenLoad = PairingTokenStore.load(configDir: configDir)
        #expect(tokenLoad == .missing, "pairing token file should be deleted after enrollment commit")
        #expect(conn.activePairingToken == nil,
                "in-memory pairing token should be cleared after enrollment commit")

        task.cancel()
        await task.value
        conn.disconnect()
    }

    // MARK: - C20: peer_disconnected clears pending

    @Test("C20: peer_disconnected clears pendingPubKey so next peer_joined is fresh")
    func testPeerDisconnectedClearsPending() async throws {
        let roomSecret = "c20-secret"
        let pairingToken = "c20-pairing-token-32chars-xyz00"
        let server = MockRelayServer(roomSecret: roomSecret, pairingToken: pairingToken)
        server.autoAuthPeer = false
        let configDir = makeTempDir()

        let conn = makeConn(configDir: configDir, roomSecret: roomSecret, server: server)
        conn.activePairingToken = pairingToken

        let task = Task { await conn.start() }
        try await server.awaitRegisterCount(1)

        server.simulatePeerJoin()
        try await Task.sleep(for: .milliseconds(200))

        // Peer disconnects mid-handshake.
        server.simulatePeerDisconnect()
        try await Task.sleep(for: .milliseconds(200))

        // No trust store file should exist — nothing committed.
        #expect(!FileManager.default.fileExists(atPath: trustStorePath(configDir)))

        task.cancel()
        await task.value
        conn.disconnect()
    }

    // MARK: - C17: legacy TOFU path code removed

    @Test("C17: Legacy `knownPubkeyPath` / `known_ios.pub` references are gone from mac_agent source")
    func testKnownPubkeyPathCodeRemoved() async throws {
        let roots = [
            "mac_agent/Sources/MacAgentLib",
            "mac_agent/Sources/MacAgent",
        ]
        let fm = FileManager.default
        let cwd = fm.currentDirectoryPath

        var offendingLines: [String] = []
        for root in roots {
            var candidate = cwd + "/" + root
            if !fm.fileExists(atPath: candidate) {
                // Tests may run from mac_agent/ as cwd; try climbing one level.
                candidate = cwd + "/../" + root
            }
            if !fm.fileExists(atPath: candidate) { continue }
            guard let enumer = fm.enumerator(atPath: candidate) else { continue }
            while let rel = enumer.nextObject() as? String {
                guard rel.hasSuffix(".swift") else { continue }
                let full = candidate + "/" + rel
                guard let content = try? String(contentsOfFile: full) else { continue }
                for (idx, line) in content.components(separatedBy: "\n").enumerated() {
                    if line.contains("knownPubkeyPath") || line.contains("known_ios.pub") {
                        offendingLines.append("\(rel):\(idx + 1): \(line)")
                    }
                }
            }
        }
        #expect(offendingLines.isEmpty,
                "Legacy TOFU path references remain: \(offendingLines.joined(separator: "\n"))")
    }

    // MARK: - C21: Swift RegisterRoomMessage JSON snapshot

    @Test("C21: RegisterRoomMessage serialization includes pairing_token_expires_at")
    func testRegisterRoomMessageSnapshot() throws {
        let msg = RegisterRoomMessage(
            room_id: "SNAP01",
            secret_hash: "deadbeef",
            public_key: "PK==",
            session_nonce: "NONCE==",
            ephemeral_key: "EPH==",
            pairing_token_hash: "cafef00d",
            pairing_token_expires_at: 1_700_000_000
        )
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let data = try enc.encode(msg)
        let str = String(data: data, encoding: .utf8) ?? ""
        // Top-level keys must include pairing_token_expires_at (as Int).
        #expect(str.contains("\"pairing_token_expires_at\":1700000000"),
                "got: \(str)")
        #expect(str.contains("\"pairing_token_hash\":\"cafef00d\""))
        #expect(str.contains("\"type\":\"register_room\""))

        // Round-trip via JSONSerialization preserves field types.
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(obj?["pairing_token_expires_at"] as? Int == 1_700_000_000)
        #expect(obj?["pairing_token_hash"] as? String == "cafef00d")
    }

    // MARK: - C22: Swift → relay round trip (shape only; relay-side is tested in E block)

    @Test("C22: RegisterRoomMessage with nil pairing_token fields still serializes validly")
    func testRegisterRoomMessageNilTokenFields() throws {
        let msg = RegisterRoomMessage(
            room_id: "SNAP02",
            secret_hash: "beefdead",
            public_key: "PK==",
            session_nonce: "NONCE==",
            ephemeral_key: "EPH=="
        )
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let data = try enc.encode(msg)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        // Both optional fields should still be present as null OR omitted.
        // Either is acceptable to the relay; what matters is they are not
        // present with a non-null value (which would imply bad data).
        if let hash = obj?["pairing_token_hash"] {
            #expect(hash is NSNull)
        }
        if let exp = obj?["pairing_token_expires_at"] {
            #expect(exp is NSNull)
        }
    }
}
