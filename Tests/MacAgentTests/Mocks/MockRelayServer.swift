import Foundation
import RemoteDevCore

/// In-process mock relay server that wraps MockWebSocket.
///
/// Intercepts messages sent by RelayConnection via `onMessageSent` and
/// auto-responds with relay protocol messages (register, heartbeat, auth).
/// Provides fault injection APIs for testing disconnect/reconnect scenarios.
final class MockRelayServer: @unchecked Sendable {

    // MARK: - Configuration (thread-safe via lock)

    private let lock = NSLock()
    private var _autoRespondRoomRegistered = true
    private var _autoRespondHeartbeatAck = true
    private var _autoAuthPeer = true
    private var _enforceQuota = false

    var autoRespondRoomRegistered: Bool {
        get { lock.withLock { _autoRespondRoomRegistered } }
        set { lock.withLock { _autoRespondRoomRegistered = newValue } }
    }
    var autoRespondHeartbeatAck: Bool {
        get { lock.withLock { _autoRespondHeartbeatAck } }
        set { lock.withLock { _autoRespondHeartbeatAck = newValue } }
    }
    var autoAuthPeer: Bool {
        get { lock.withLock { _autoAuthPeer } }
        set { lock.withLock { _autoAuthPeer = newValue } }
    }
    /// When true, automatically sends quota_exceeded after room_registered.
    /// Simulates a user whose tier limit is exceeded.
    var enforceQuota: Bool {
        get { lock.withLock { _enforceQuota } }
        set { lock.withLock { _enforceQuota = newValue } }
    }

    // MARK: - Observable state

    private var _registerCount = 0
    private var _heartbeatCount = 0
    private var _authCount = 0
    private var _authenticated = false
    private var _connectionCount = 0

    var registerCount: Int { lock.withLock { _registerCount } }
    var heartbeatCount: Int { lock.withLock { _heartbeatCount } }
    var authCount: Int { lock.withLock { _authCount } }
    var authenticated: Bool { lock.withLock { _authenticated } }
    /// Number of WebSocket connections (incremented on each attach).
    var connectionCount: Int { lock.withLock { _connectionCount } }

    // MARK: - Internal state

    private var roomSecret: String
    /// Pairing token used for initial pairing auth (first peer join).
    private var _pairingToken: String?
    var pairingToken: String? {
        get { lock.withLock { _pairingToken } }
        set { lock.withLock { _pairingToken = newValue } }
    }
    /// Override auth key for challenge HMAC (e.g. pairing token instead of roomSecret).
    private var _authKeyOverride: String?
    var authKeyOverride: String? {
        get { lock.withLock { _authKeyOverride } }
        set { lock.withLock { _authKeyOverride = newValue } }
    }
    private var peerCrypto: SessionCrypto?
    private var macPublicKey: String = ""
    private var macSessionNonce: String = ""
    private var currentWS: MockWebSocket?
    private var reverseChallengeSent = false
    /// Whether this peer has been authenticated at least once (TOFU established).
    private var _hasAuthenticatedBefore = false
    /// Persistent peer identity. Never cleared once established,
    /// so TOFU verification passes on subsequent simulatePeerJoin() calls.
    private var _peerIdentityCrypto: SessionCrypto?

    // MARK: - Init

    init(roomSecret: String, pairingToken: String? = nil) {
        self.roomSecret = roomSecret
        self._pairingToken = pairingToken
    }

    // MARK: - Attach to MockWebSocket

    /// Hook into a MockWebSocket to intercept messages.
    /// Call this from the wsFactory closure for each new connection.
    func attach(to ws: MockWebSocket) {
        lock.withLock {
            currentWS = ws
            _connectionCount += 1
            _authenticated = false
            reverseChallengeSent = false
        }
        ws.onMessageSent = { [weak self] msg in
            self?.handleSentMessage(msg, on: ws)
        }
    }

    // MARK: - Message interception

    private func handleSentMessage(_ message: String, on ws: MockWebSocket) {
        guard let data = message.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }

        switch type {
        case "register_room":
            let shouldRespond: Bool = lock.withLock {
                _registerCount += 1
                macPublicKey = json["public_key"] as? String ?? ""
                macSessionNonce = json["session_nonce"] as? String ?? ""
                return _autoRespondRoomRegistered
            }
            if shouldRespond {
                let roomId = json["room_id"] as? String ?? ""
                ws.simulateReceive("""
                {"type":"room_registered","room_id":"\(roomId)"}
                """)
                if enforceQuota {
                    sendQuotaExceeded()
                }
            }

        case "heartbeat":
            let shouldAck: Bool = lock.withLock {
                _heartbeatCount += 1
                return _autoRespondHeartbeatAck
            }
            if shouldAck {
                ws.simulateReceive("""
                {"type":"heartbeat_ack","mac_connected":true}
                """)
            }

        case "relay":
            guard let payload = json["payload"] as? String else { return }
            let (crypto, shouldAuth): (SessionCrypto?, Bool) = lock.withLock {
                (peerCrypto, _autoAuthPeer)
            }
            guard shouldAuth, let crypto else { return }
            guard let cipherData = Data(base64Encoded: payload),
                  let plain = try? crypto.decrypt(cipherData),
                  let appMsg = try? JSONDecoder().decode(AppMessage.self, from: plain) else { return }
            handleDecryptedAppMessage(appMsg, on: ws, crypto: crypto)

        default:
            break
        }
    }

    private func handleDecryptedAppMessage(_ msg: AppMessage, on ws: MockWebSocket, crypto: SessionCrypto) {
        switch msg {
        case .challenge(let nonce):
            // Mac sent challenge → compute HMAC → send challengeResponse
            guard let nonceData = Data(base64Encoded: nonce) else { return }
            let key: String = lock.withLock {
                if let override = _authKeyOverride { return override }
                // First auth uses pairing token (matching RelayConnection's logic)
                if !_hasAuthenticatedBefore, let token = _pairingToken { return token }
                return roomSecret
            }
            let hmac = SessionCrypto.hmacSHA256(data: nonceData, key: Data(key.utf8))
            let response = AppMessage.challengeResponse(hmac: hmac.base64EncodedString())
            sendEncrypted(response, on: ws, crypto: crypto)

        case .authOk:
            // Mac verified our challengeResponse → send reverse challenge
            let reverseNonce = SessionCrypto.randomBytes(32).base64EncodedString()
            let challenge = AppMessage.challenge(nonce: reverseNonce)
            sendEncrypted(challenge, on: ws, crypto: crypto)
            lock.withLock { reverseChallengeSent = true }

        case .challengeResponse(_):
            // Mac answered our reverse challenge → auth complete
            let isReverse = lock.withLock { reverseChallengeSent }
            if isReverse {
                lock.withLock {
                    _authenticated = true
                    _authCount += 1
                    _hasAuthenticatedBefore = true
                    _peerIdentityCrypto = peerCrypto
                    reverseChallengeSent = false
                }
            }

        case .rotateSecret(let newSecret):
            // Auto-respond with rotateSecretAck and adopt the new secret
            lock.withLock { self.roomSecret = newSecret }
            sendEncrypted(.rotateSecretAck, on: ws, crypto: crypto)

        default:
            break
        }
    }

    private func sendEncrypted(_ msg: AppMessage, on ws: MockWebSocket, crypto: SessionCrypto) {
        guard let json = try? JSONEncoder().encode(msg),
              let encrypted = try? crypto.encrypt(json) else { return }
        ws.simulateReceive("""
        {"type":"relay","payload":"\(encrypted.base64EncodedString())"}
        """)
    }

    // MARK: - Fault injection

    func stopHeartbeatAcks() {
        autoRespondHeartbeatAck = false
    }

    func resumeHeartbeatAcks() {
        autoRespondHeartbeatAck = true
    }

    /// Pre-set the peer crypto (for tests that need a specific identity key, e.g. TOFU tests).
    func setPeerCrypto(_ crypto: SessionCrypto) {
        lock.withLock { peerCrypto = crypto }
    }

    /// Simulate a peer reconnecting with the same identity key (TOFU match).
    /// Reuses the existing peerCrypto's identity but derives a fresh session key.
    func simulatePeerReconnect() {
        let (ws, macPK, macNonce, existingCrypto): (MockWebSocket?, String, String, SessionCrypto?) = lock.withLock {
            (currentWS, macPublicKey, macSessionNonce, peerCrypto)
        }
        guard let ws, let crypto = existingCrypto else { return }

        let nonce = SessionCrypto.randomBytes(32).base64EncodedString()

        // Re-derive session key with fresh nonces (same identity key)
        if !macNonce.isEmpty {
            try? crypto.deriveSessionKey(peerPublicKeyBase64: macPK, localNonce: nonce, remoteNonce: macNonce)
        } else {
            try? crypto.deriveSessionKey(peerPublicKeyBase64: macPK)
        }

        lock.withLock {
            _authenticated = false
            reverseChallengeSent = false
        }

        ws.simulateReceive("""
        {"type":"peer_joined","public_key":"\(crypto.publicKeyBase64)","session_nonce":"\(nonce)"}
        """)
    }

    /// Simulate a peer joining the room. Sends `peer_joined` and (if autoAuthPeer)
    /// automatically completes the mutual auth handshake.
    /// On first call creates a new identity; on subsequent calls reuses the same
    /// identity (public key) so TOFU verification passes.
    func simulatePeerJoin() {
        let (ws, macPK, macNonce, existing): (MockWebSocket?, String, String, SessionCrypto?) = lock.withLock {
            (currentWS, macPublicKey, macSessionNonce, _peerIdentityCrypto)
        }
        guard let ws else { return }

        let crypto = existing ?? SessionCrypto()
        let nonce = SessionCrypto.randomBytes(32).base64EncodedString()

        // Derive session key (must match what Mac will compute)
        if !macNonce.isEmpty {
            try? crypto.deriveSessionKey(peerPublicKeyBase64: macPK, localNonce: nonce, remoteNonce: macNonce)
        } else {
            try? crypto.deriveSessionKey(peerPublicKeyBase64: macPK)
        }

        lock.withLock {
            peerCrypto = crypto
            if _peerIdentityCrypto == nil { _peerIdentityCrypto = crypto }
            _authenticated = false
            reverseChallengeSent = false
        }

        ws.simulateReceive("""
        {"type":"peer_joined","public_key":"\(crypto.publicKeyBase64)","session_nonce":"\(nonce)"}
        """)
    }

    func simulatePeerDisconnect(reason: String = "client_left", preserveCrypto: Bool = false) {
        let ws: MockWebSocket? = lock.withLock {
            _authenticated = false
            if !preserveCrypto { peerCrypto = nil }
            return currentWS
        }
        ws?.simulateReceive("""
        {"type":"peer_disconnected","reason":"\(reason)"}
        """)
    }

    func sendError(code: String, message: String) {
        guard let ws = lock.withLock({ currentWS }) else { return }
        ws.simulateReceive("""
        {"type":"error","code":"\(code)","message":"\(message)"}
        """)
    }

    func sendQuotaExceeded(usage: Int = 100, limit: Int = 100, period: String = "hourly", resetsAt: String = "2099-01-01T00:00:00Z") {
        guard let ws = lock.withLock({ currentWS }) else { return }
        ws.simulateReceive("""
        {"type":"quota_exceeded","usage":\(usage),"limit":\(limit),"period":"\(period)","resets_at":"\(resetsAt)"}
        """)
    }

    /// Force-disconnect the WebSocket (simulates network-level failure).
    func forceDisconnect() {
        guard let ws = lock.withLock({ currentWS }) else { return }
        ws.simulateError(MockWebSocket.MockError.connectionFailed)
    }

    /// Close the WebSocket with a close code (simulates server/DO-initiated close).
    func closeWebSocket(code: Int, reason: String = "") {
        guard let ws = lock.withLock({ currentWS }) else { return }
        ws.simulateServerClose(code: code, reason: reason)
    }

    // MARK: - Await helpers

    func awaitRegisterCount(_ n: Int, timeout: TimeInterval = 5) async throws {
        try await awaitCondition(timeout: timeout) { [self] in registerCount >= n }
    }

    func awaitConnectionCount(_ n: Int, timeout: TimeInterval = 5) async throws {
        try await awaitCondition(timeout: timeout) { [self] in connectionCount >= n }
    }

    func awaitAuthenticated(timeout: TimeInterval = 5) async throws {
        try await awaitCondition(timeout: timeout) { [self] in authenticated }
    }

    func awaitAuthCount(_ n: Int, timeout: TimeInterval = 5) async throws {
        try await awaitCondition(timeout: timeout) { [self] in authCount >= n }
    }
}
