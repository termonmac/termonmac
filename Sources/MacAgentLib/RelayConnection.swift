import Foundation
import CryptoKit
import RemoteDevCore
#if os(macOS)
import AppKit
import Network
#endif

public final class RelayConnection: @unchecked Sendable {
    public let serverURL: String
    public let roomID: String
    public private(set) var roomSecret: String
    public let crypto: SessionCrypto
    public let workDir: String

    private var ws: WebSocketProtocol
    private var heartbeatTask: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?
    private var sendTask: Task<Void, Never>?

    private var sendContinuation: AsyncStream<String>.Continuation?
    private var peerAuthenticated = false
    private var challengeNonce: String?
    private var reconnectDelay: TimeInterval = 0.5
    private var authTimeoutTask: Task<Void, Never>?
    private var lastHeartbeatAckTime: Date?
    private var lastUserActivityTime: Date?

    /// Fresh 32-byte nonce generated per connection for unique session keys.
    private var localSessionNonce: String = ""

    /// Ephemeral key pair generated per connection for forward secrecy.
    private var ephemeralPrivateKey: Curve25519.KeyAgreement.PrivateKey?

    /// Ephemeral public keys (base64) for channel binding in challenge HMAC.
    private var localEphemeralPubKey = ""
    private var peerEphemeralPubKey = ""

    private let configDir: String

    /// Short-lived pairing token for initial QR pairing (not stored long-term).
    /// When set, auth handshake uses this instead of roomSecret, and on success
    /// the roomSecret is sent to iOS via pairingCredentials message.
    public var activePairingToken: String?

    /// Wall-clock expiry (unix seconds) corresponding to `activePairingToken`.
    /// Relay enforces the deadline; Mac only forwards it. `nil` when no token.
    public var activePairingTokenExpiresAt: Int?

    /// Per-connection candidate: public key claimed in the most recent
    /// `peer_joined`, held in memory until the challenge handshake commits it
    /// to the trust store. Never written to disk from `peer_joined` alone.
    private var pendingPubKey: String?
    /// Whether the pending candidate represents a new-device enrollment
    /// (true → `TrustStore.add`) or a reconnect touch (false → `TrustStore.touch`).
    private var pendingIsEnrollment: Bool = false
    /// Device type reported by iOS for an enrollment candidate (e.g. "iPhone",
    /// "iPad"). `nil` when unknown; TrustStore normalizes to "unknown".
    private var pendingDeviceType: String?

    /// Suppresses onRoomRegistered callback (e.g. during token-refresh re-registration).
    private var suppressNextRoomRegistered = false

    public var onPeerAuthenticated: (() -> Void)?
    public var onEncryptedMessage: ((AppMessage) -> Void)?
    public var onPeerDisconnected: (() -> Void)?
    /// Called when secret is rotated after first pairing; caller should persist the new secret.
    public var onSecretRotated: ((String) -> Void)?

    /// Whether the secret has already been rotated (set by caller based on persisted state).
    public var secretRotated = false

    // Batching: coalesce high-throughput encrypted payloads into relay_batch
    private let batchQueue = DispatchQueue(label: "relay.batch")
    private var batchBuffer: [String] = []
    private var batchTimer: DispatchWorkItem?
    private static let batchFlushInterval: TimeInterval = 0.05 // 50ms
    private static let batchMaxSize = 20

    /// Called when pairing is fully confirmed (rotateSecretAck received).
    public var onPairingComplete: (() -> Void)?
    /// Called when secret rotation times out (iOS didn't acknowledge).
    public var onPairingFailed: (() -> Void)?

    public var onRoomRegistered: (() -> Void)?
    public var onMaxSessionsUpdated: ((Int) -> Void)?
    /// Called when relay returns AUTH_FAILED on register_room (room_id collision).
    public var onRegisterAuthFailed: (() -> Void)?
    /// Called when HTTP 401 indicates the API key is invalid/expired.
    public var onTokenInvalid: (() -> Void)?
    /// Called when HTTP 410 indicates the account has been deleted.
    public var onAccountDeleted: (() -> Void)?
    private let apiKey: String?
    private let sandboxKey: String?
    private let wsFactory: () -> WebSocketProtocol

    private let heartbeatInterval: TimeInterval
    private let heartbeatAckTimeout: TimeInterval
    private let registerTimeout: TimeInterval
    private let tierRetryInterval: TimeInterval
    private let auth401RetryDelay: TimeInterval
    private var roomRegistered = false
    private var registrationTimeoutTask: Task<Void, Never>?
    private var lastTierRejection = false

    /// Whether the current peer is a reconnecting device (TOFU-verified pubkey).
    private var peerIsReconnecting = false

    /// Tracks whether the current peer authenticated via pairing token (re-pairing)
    /// vs room secret (normal reconnect). Used for the reverse challenge response.
    private var peerUsedPairingToken = false

    /// Pending secret rotation: newSecret waiting for iOS ack before committing.
    private var pendingRotationSecret: String?
    private var rotationTimeoutTask: Task<Void, Never>?

    public init(serverURL: String, workDir: String, apiKey: String? = nil, sandboxKey: String? = nil,
                crypto: SessionCrypto,
                roomID: String, roomSecret: String, configDir: String,
                wsFactory: @escaping () -> WebSocketProtocol = { WebSocketClient() },
                heartbeatInterval: TimeInterval = 30,
                heartbeatAckTimeout: TimeInterval = 60,
                registerTimeout: TimeInterval = 10,
                tierRetryInterval: TimeInterval = 8,
                auth401RetryDelay: TimeInterval = 10) {
        self.serverURL = serverURL
        self.workDir = workDir
        self.apiKey = apiKey
        self.sandboxKey = sandboxKey
        self.roomID = roomID
        self.roomSecret = roomSecret
        self.crypto = crypto
        self.wsFactory = wsFactory
        self.ws = wsFactory()
        self.configDir = configDir
        self.heartbeatInterval = heartbeatInterval
        self.heartbeatAckTimeout = heartbeatAckTimeout
        self.registerTimeout = registerTimeout
        self.tierRetryInterval = tierRetryInterval
        self.auth401RetryDelay = auth401RetryDelay
        let fm = FileManager.default
        if !fm.fileExists(atPath: configDir) {
            try? fm.createDirectory(atPath: configDir, withIntermediateDirectories: true)
        }
    }

    public func start() async {
        log("[relay] start() — entering connectAndRun loop")
        await connectAndRun()
        log("[relay] start() — connectAndRun returned, relay is stopped")
    }

    /// Mark user activity so heartbeat uses 1s interval for the next 15 minutes.
    public func touchUserActivity() {
        lastUserActivityTime = Date()
    }

    public func disconnect() {
        // Flush pending batch before closing
        batchQueue.sync { _flushBatch() }
        heartbeatTask?.cancel()
        registrationTimeoutTask?.cancel()
        receiveTask?.cancel()
        sendTask?.cancel()
        authTimeoutTask?.cancel()
        rotationTimeoutTask?.cancel()
        rotationTimeoutTask = nil
        pendingRotationSecret = nil
        sendContinuation?.finish()
        ws.disconnect()
        crypto.clearSessionKey()
    }

    private func connectAndRun() async {
        #if os(macOS)
        let wakeObserver = NotificationCenter.default.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            log("[relay] Mac woke from sleep — forcing immediate reconnect")
            self?.reconnectDelay = 0
            self?.ws.disconnect()
        }
        let sleepObserver = NotificationCenter.default.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil, queue: .main
        ) { _ in
            log("[relay] Mac going to sleep")
        }

        // Monitor network path changes (WiFi reconnect, IP change)
        let monitor = NWPathMonitor()
        let pathState = PathState()
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            guard let prev = pathState.current else {
                pathState.current = path
                return
            }
            if path.status != prev.status ||
               Set(path.availableInterfaces.map(\.name)) != Set(prev.availableInterfaces.map(\.name)) {
                log("[relay] network path changed — forcing reconnect")
                self.reconnectDelay = 0
                self.ws.disconnect()
            }
            pathState.current = path
        }
        monitor.start(queue: DispatchQueue(label: "net-monitor"))

        defer {
            NotificationCenter.default.removeObserver(wakeObserver)
            NotificationCenter.default.removeObserver(sleepObserver)
            monitor.cancel()
        }
        #endif

        var consecutive401Count = 0
        connectLoop: while !Task.isCancelled {
            lastTierRejection = false
            do {
                ws = wsFactory()
                lastHeartbeatAckTime = nil
                let connectStart = Date()
                var components = URLComponents(string: "\(serverURL)/ws")!
                components.queryItems = [
                    URLQueryItem(name: "room_id", value: roomID),
                    URLQueryItem(name: "role", value: "mac"),
                ]
                let url = components.url!
                var request = URLRequest(url: url)
                if let apiKey {
                    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                }
                if let sandboxKey, !sandboxKey.isEmpty {
                    request.setValue(sandboxKey, forHTTPHeaderField: "X-Sandbox-Key")
                }
                try await ws.connect(request: request)

                let connectMs = Int(Date().timeIntervalSince(connectStart) * 1000)
                log("[relay] connected to relay (attempt took \(connectMs)ms)")

                // Generate fresh session nonce and ephemeral key per connection
                localSessionNonce = SessionCrypto.randomBytes(32).base64EncodedString()
                let ephKey = Curve25519.KeyAgreement.PrivateKey()
                ephemeralPrivateKey = ephKey
                localEphemeralPubKey = ephKey.publicKey.rawRepresentation.base64EncodedString()
                peerEphemeralPubKey = ""

                // Load a pairing token only if the `pair` CLI already wrote one.
                // The daemon never auto-generates; absent token → registration
                // proceeds without `pairing_token_hash` and only TOFU-known
                // devices can (re)authenticate.
                if activePairingToken == nil {
                    switch PairingTokenStore.load(configDir: configDir) {
                    case .ok(let file):
                        activePairingToken = file.token
                        activePairingTokenExpiresAt = file.expires_at
                    case .missing, .expired, .unsupportedVersion, .corrupted:
                        break
                    }
                }

                // Register room
                roomRegistered = false
                let pairingHash = activePairingToken.map { SessionCrypto.sha256Hex($0) }
                let registerMsg = RegisterRoomMessage(
                    room_id: roomID,
                    secret_hash: SessionCrypto.sha256Hex(roomSecret),
                    public_key: crypto.publicKeyBase64,
                    session_nonce: localSessionNonce,
                    ephemeral_key: ephKey.publicKey.rawRepresentation.base64EncodedString(),
                    pairing_token_hash: pairingHash,
                    pairing_token_expires_at: pairingHash != nil ? activePairingTokenExpiresAt : nil
                )
                try await ws.send(jsonEncode(registerMsg))

                // Start registration timeout
                registrationTimeoutTask?.cancel()
                let regTimeout = registerTimeout
                registrationTimeoutTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(regTimeout))
                    guard !Task.isCancelled, let self, !self.roomRegistered else { return }
                    log("[relay] register_room timeout — forcing reconnect")
                    self.ws.disconnect()
                }

                consecutive401Count = 0
                reconnectDelay = 0.5 // reset on successful connect
                lastHeartbeatAckTime = Date() // initial grace period
                peerAuthenticated = false
                challengeNonce = nil
                authTimeoutTask?.cancel()
                startSendLoop()
                startHeartbeat()

                for try await text in ws.receive() {
                    do {
                        try handleMessage(text)
                    } catch {
                        log("[relay] failed to handle message, skipping: \(error)")
                        continue
                    }
                }
            } catch let wsError as WebSocketClient.WebSocketError {
                switch wsError {
                case .httpUpgradeFailed(let statusCode) where statusCode == 401:
                    consecutive401Count += 1
                    if consecutive401Count <= 3 {
                        let delay = auth401RetryDelay * Double(consecutive401Count)
                        log("[relay] API key rejected (HTTP 401) — transient retry \(consecutive401Count)/3 in \(Int(delay))s")
                        reconnectDelay = delay
                    } else {
                        log("[relay] API key invalid or expired (HTTP 401) — requires re-authentication")
                        onTokenInvalid?()
                        log("[relay] connectAndRun exiting: HTTP 401")
                        return  // exit the reconnect loop
                    }
                case .httpUpgradeFailed(let statusCode) where statusCode == 410:
                    log("[relay] account deleted (HTTP 410) — stopping reconnect")
                    onAccountDeleted?()
                    log("[relay] connectAndRun exiting: HTTP 410")
                    return  // exit the reconnect loop
                case .httpUpgradeFailed(let statusCode) where statusCode == 403:
                    log("[relay] room limit reached (HTTP 403) — retrying in \(Int(tierRetryInterval))s. Upgrade your plan for more concurrent connections.")
                    reconnectDelay = tierRetryInterval
                case .serverClose(let code, _) where code == 1001 || code == 4000:
                    // DO restart (1001) or DO heartbeat timeout (4000) — relay will recover quickly
                    log("[relay] reconnecting (reason: server_close/\(code)) — \(wsError). Delay: 0s")
                    reconnectDelay = 0
                default:
                    let reason = reconnectDelay == 0 ? "wake/network_change" : "error"
                    log("[relay] reconnecting (reason: \(reason)) — \(wsError). Delay: \(Int(reconnectDelay))s")
                }
            } catch {
                let reason = reconnectDelay == 0 ? "wake/network_change" : "error"
                log("[relay] reconnecting (reason: \(reason)) — \(error). Delay: \(Int(reconnectDelay))s")
            }

            let wasPeerAuthenticated = peerAuthenticated
            heartbeatTask?.cancel()
            registrationTimeoutTask?.cancel()
            rotationTimeoutTask?.cancel()
            rotationTimeoutTask = nil
            pendingRotationSecret = nil
            receiveTask?.cancel()
            sendTask?.cancel()
            sendContinuation?.finish()
            ws.disconnect()
            crypto.clearSessionKey()
            if wasPeerAuthenticated {
                onPeerDisconnected?()
            }

            if Task.isCancelled {
                log("[relay] connectAndRun exiting: Task cancelled")
                break
            }
            if lastTierRejection {
                reconnectDelay = tierRetryInterval
            }
            log("[relay] sleeping \(String(format: "%.1f", reconnectDelay))s before reconnect")
            try? await Task.sleep(for: .seconds(reconnectDelay))
            log("[relay] sleep done, reconnecting")
            reconnectDelay = max(0.5, min(reconnectDelay * 2, 8))
        }
        log("[relay] connectAndRun loop ended — isCancelled=\(Task.isCancelled)")
    }

    private func handleMessage(_ text: String) throws {
        let msg = try JSONDecoder().decode(ServerMessage.self, from: Data(text.utf8))
        switch msg {
        case .roomRegistered(_, let maxSessions):
            roomRegistered = true
            registrationTimeoutTask?.cancel()
            if let max = maxSessions {
                onMaxSessionsUpdated?(max)
            }
            if suppressNextRoomRegistered {
                suppressNextRoomRegistered = false
                log("[relay] pairing token refreshed on relay")
            } else {
                printConnectionInfo()
                onRoomRegistered?()
            }

        case .peerJoined(let publicKey, let remoteNonce, let ephemeralKey):
            // Guard: if a challenge is already pending for the same iOS connection
            // (same ephemeral key), this is a duplicate peer_joined caused by iOS
            // re-sending join_room or relay re-notifying after Mac register_room.
            // Skip to avoid overwriting the challenge nonce — the iOS response to
            // the first challenge would fail HMAC verification against the new nonce.
            if challengeNonce != nil && !ephemeralKey.isEmpty && ephemeralKey == peerEphemeralPubKey {
                log("[relay] duplicate peer_joined (same ephemeral key, challenge pending) — skipping")
                return
            }
            lastUserActivityTime = Date()
            peerAuthenticated = false
            peerIsReconnecting = false
            peerUsedPairingToken = false
            peerEphemeralPubKey = ephemeralKey
            pendingPubKey = nil
            pendingIsEnrollment = false
            pendingDeviceType = nil

            // Multi-key trust store lookup: known → reconnect; unknown + valid
            // pairing token → enrollment candidate (held in memory, committed
            // only after challenge success); otherwise reject before challenge.
            let trustStore = TrustStore(configDir: configDir)
            _ = trustStore.load()
            if trustStore.contains(publicKey: publicKey) {
                log("[security] iOS public key verified (trust store hit)")
                peerIsReconnecting = true
                pendingPubKey = publicKey
                pendingIsEnrollment = false
            } else if activePairingToken != nil {
                if trustStore.devices.count >= TrustStore.deviceLimit {
                    log("[security] trust store full (\(TrustStore.deviceLimit)) — rejecting new device before challenge")
                    ws.disconnect()
                    return
                }
                log("[security] unknown iOS public key with active pairing token — enrollment candidate (no disk write yet)")
                pendingPubKey = publicKey
                pendingIsEnrollment = true
            } else {
                log("[security] unknown device and no active pairing token — rejecting")
                ws.disconnect()
                return
            }

            // Forward secrecy: use ephemeral keys for ECDH when both sides support it
            if !ephemeralKey.isEmpty, let ephPriv = ephemeralPrivateKey,
               !remoteNonce.isEmpty && !localSessionNonce.isEmpty {
                try crypto.deriveSessionKeyEphemeral(
                    ephemeralPrivateKey: ephPriv,
                    peerEphemeralKeyBase64: ephemeralKey,
                    localNonce: localSessionNonce,
                    remoteNonce: remoteNonce)
                log("[security] session key derived with forward secrecy (ephemeral ECDH)")
            } else if !remoteNonce.isEmpty && !localSessionNonce.isEmpty {
                try crypto.deriveSessionKey(peerPublicKeyBase64: publicKey, localNonce: localSessionNonce, remoteNonce: remoteNonce)
                log("[security] session key derived (legacy, no forward secrecy)")
            } else {
                try crypto.deriveSessionKey(peerPublicKeyBase64: publicKey)
                log("[security] session key derived (legacy v1, no nonces)")
            }
            // Send challenge
            let nonce = SessionCrypto.randomBytes(32).base64EncodedString()
            challengeNonce = nonce
            try sendEncrypted(.challenge(nonce: nonce))
            log("[relay] peer joined, challenge sent")

        case .relay(let payload):
            lastUserActivityTime = Date()
            guard let cipherData = Data(base64Encoded: payload) else { return }
            let plain = try crypto.decrypt(cipherData)
            let appMsg = try JSONDecoder().decode(AppMessage.self, from: plain)
            handleAppMessage(appMsg)

        case .relayBatch(let payloads):
            lastUserActivityTime = Date()
            for payload in payloads {
                guard let cipherData = Data(base64Encoded: payload) else { continue }
                let plain = try crypto.decrypt(cipherData)
                let appMsg = try JSONDecoder().decode(AppMessage.self, from: plain)
                handleAppMessage(appMsg)
            }

        case .peerDisconnected(let reason):
            log("[relay] peer disconnected: \(reason)")
            lastUserActivityTime = Date()
            peerAuthenticated = false
            challengeNonce = nil
            pendingPubKey = nil
            pendingIsEnrollment = false
            pendingDeviceType = nil
            crypto.clearSessionKey()
            onPeerDisconnected?()

        case .heartbeatAck(_, _, _):
            if let prevAck = lastHeartbeatAckTime {
                let gap = Date().timeIntervalSince(prevAck)
                if gap > 35 {
                    log("[heartbeat] late ack: \(Int(gap))s since last")
                }
            }
            lastHeartbeatAckTime = Date()

        case .error(let code, let message, _, _):
            log("[relay] error: \(code) — \(message)")
            if code == "AUTH_FAILED" {
                onRegisterAuthFailed?()
            } else if code == "NO_PEER" && peerAuthenticated {
                // Relay says peer is gone — treat as peer_disconnected so Mac
                // stops sending and switches PTY to buffer mode.
                peerAuthenticated = false
                challengeNonce = nil
                onPeerDisconnected?()
            }

        case .quotaExceeded(let usage, let limit, let period, let resetsAt, let extraUsed, let extraLimit, _):
            let extraInfo = extraLimit != nil ? " (extra quota: \(extraUsed ?? 0)/\(extraLimit!))" : ""
            log("[relay] quota exceeded: \(usage)/\(limit) in \(period), resets at \(resetsAt)\(extraInfo) — will retry in \(Int(tierRetryInterval))s")
            lastTierRejection = true
            ws.disconnect()
        }
    }

    private func handleAppMessage(_ msg: AppMessage) {
        switch msg {
        case .challengeResponse(let hmac):
            guard let nonce = challengeNonce,
                  let nonceData = Data(base64Encoded: nonce) else {
                log("[auth] no pending challenge")
                return
            }
            // Determine which auth key the peer used.
            // New peer: uses activePairingToken (initial pairing).
            // Known peer (TOFU-verified): normally uses roomSecret (reconnect),
            // but may use activePairingToken if re-pairing via new QR code scan.
            let authKey: String
            if peerIsReconnecting, let token = activePairingToken,
               let hd = Data(base64Encoded: hmac),
               hd == SessionCrypto.hmacSHA256(data: nonceData, key: Data(token.utf8)) {
                // Known device re-pairing with a new QR code
                authKey = token
                peerUsedPairingToken = true
            } else {
                authKey = peerIsReconnecting ? roomSecret : (activePairingToken ?? roomSecret)
                peerUsedPairingToken = !peerIsReconnecting && activePairingToken != nil
            }
            let expected = SessionCrypto.hmacSHA256(data: nonceData, key: Data(authKey.utf8))
            guard let hmacData = Data(base64Encoded: hmac), hmacData == expected else {
                log("[auth] challenge-response failed — disconnecting")
                pendingPubKey = nil
                pendingIsEnrollment = false
                ws.disconnect()
                return
            }
            challengeNonce = nil
            let isPairing = peerUsedPairingToken || (!peerIsReconnecting && activePairingToken != nil)
            if isPairing {
                log("[pairing] iOS challenge-response verified — sending pairing credentials")
            } else {
                log("[auth] iOS challenge-response verified, sending authOk")
            }
            // Commit the candidate pubkey now that HMAC has passed. For
            // enrollment we append to the trust store and invalidate the
            // one-time pairing token; for reconnect we re-check the store
            // (D-I1 guard against concurrent `devices remove`) and `touch`.
            if !commitPendingPubKey() {
                log("[security] commit failed — disconnecting")
                ws.disconnect()
                return
            }
            // Send authOk to iOS, then wait for reverse challenge
            try? sendEncrypted(.authOk)
            // If pairing, send room secret over the encrypted channel
            if isPairing {
                try? sendEncrypted(.pairingCredentials(secret: roomSecret))
                log("[pairing] room secret sent to iOS")
            }
            authTimeoutTask?.cancel()
            authTimeoutTask = Task {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled, !self.peerAuthenticated else { return }
                log("[auth] reverse challenge timeout — assuming legacy client, proceeding")
                self.peerAuthenticated = true
                self.onPeerAuthenticated?()
            }

        case .challenge(let nonce):
            // Reverse challenge from iOS — use the same key that was verified
            // in the challengeResponse handler (pairing token for re-pairing,
            // room secret for normal reconnect).
            guard let nonceData = Data(base64Encoded: nonce) else {
                log("[auth] failed to decode reverse challenge nonce")
                return
            }
            let authKey = peerUsedPairingToken ? (activePairingToken ?? roomSecret) :
                          (peerIsReconnecting ? roomSecret : (activePairingToken ?? roomSecret))
            let hmac = SessionCrypto.hmacSHA256(data: nonceData, key: Data(authKey.utf8))
            try? sendEncrypted(.challengeResponse(hmac: hmac.base64EncodedString()))
            log("[auth] reverse challenge answered, setting peerAuthenticated")
            authTimeoutTask?.cancel()
            peerAuthenticated = true
            onPeerAuthenticated?()
            initiateSecretRotation()

        case .rotateSecretAck:
            log("[auth] secret rotation acknowledged by iOS")
            rotationTimeoutTask?.cancel()
            rotationTimeoutTask = nil
            if let newSecret = pendingRotationSecret {
                roomSecret = newSecret
                secretRotated = true
                onSecretRotated?(newSecret)

                // Now safe to update relay with the new secret_hash
                let registerMsg = RegisterRoomMessage(
                    room_id: roomID,
                    secret_hash: SessionCrypto.sha256Hex(newSecret),
                    public_key: crypto.publicKeyBase64,
                    session_nonce: localSessionNonce
                )
                if let text = try? jsonEncode(registerMsg) {
                    sendRaw(text)
                    log("[auth] re-registered with relay (updated secret_hash after ack)")
                }

                // Update room_info.txt
                let infoPath = configDir + "/room_info.txt"
                let info = "\(roomID)\n\(newSecret)\n"
                FileManager.default.createFile(atPath: infoPath, contents: Data(info.utf8), attributes: [.posixPermissions: 0o600])

                pendingRotationSecret = nil
                log("[pairing] secret exchange confirmed — pairing complete")
                onPairingComplete?()
            }

        default:
            guard peerAuthenticated else {
                log("[relay] ignoring message from unauthenticated peer")
                return
            }
            onEncryptedMessage?(msg)
        }
    }

    /// Commit the pending candidate pubkey to the trust store after a
    /// successful challenge HMAC verification. Returns `false` on
    /// commit failure (e.g. D-I1 concurrent remove, device limit reached).
    ///
    /// On success:
    /// - enrollment → append new device, invalidate the one-time pairing token.
    /// - reconnect → re-check store membership, touch `last_seen`.
    private func commitPendingPubKey() -> Bool {
        guard let pending = pendingPubKey else {
            // Nothing to commit (should not happen post-HMAC).
            return true
        }
        defer {
            pendingPubKey = nil
            pendingIsEnrollment = false
            pendingDeviceType = nil
        }
        let store = TrustStore(configDir: configDir)
        _ = store.load()
        if pendingIsEnrollment {
            if store.devices.count >= TrustStore.deviceLimit {
                log("[security] trust store full at commit — rejecting new device")
                return false
            }
            do {
                _ = try store.add(publicKey: pending, deviceType: pendingDeviceType)
                log("[security] trust store enrollment committed")
            } catch {
                log("[security] trust store add failed: \(error) — rejecting")
                return false
            }
            invalidatePairingToken()
            return true
        } else {
            // D-I1 re-check: confirm the device still exists in the store.
            guard store.contains(publicKey: pending) else {
                log("[security] device removed mid-challenge — rejecting reconnect")
                return false
            }
            try? store.touch(publicKey: pending)
            return true
        }
    }

    /// Invalidate the current one-time pairing token (single-use semantics).
    /// Wipes in-memory + on-disk copies; next connect registers without a hash
    /// so only trust-store-known devices can authenticate.
    private func invalidatePairingToken() {
        activePairingToken = nil
        activePairingTokenExpiresAt = nil
        PairingTokenStore.delete(configDir: configDir)
    }

    /// Serialize all WebSocket sends through an AsyncStream to prevent
    /// concurrent sends from corrupting WebSocket framing.
    /// The previous DispatchSemaphore approach could deadlock with the
    /// Swift cooperative thread pool, causing heartbeat timeouts.
    private func sendRaw(_ text: String) {
        sendContinuation?.yield(text)
    }

    private func startSendLoop() {
        sendTask?.cancel()
        var continuation: AsyncStream<String>.Continuation!
        let stream = AsyncStream<String> { continuation = $0 }
        self.sendContinuation = continuation
        let ws = self.ws
        sendTask = Task {
            for await text in stream {
                do {
                    try await ws.send(text)
                } catch {
                    log("[relay] sendRaw failed: \(error)")
                }
            }
        }
    }

    public func sendEncrypted(_ msg: AppMessage) throws {
        let json = try JSONEncoder().encode(msg)
        let encrypted = try crypto.encrypt(json)
        let payload = encrypted.base64EncodedString()
        let relay = RelayClientMessage(payload: payload)
        guard let text = String(data: try JSONEncoder().encode(relay), encoding: .utf8) else { return }
        sendRaw(text)
    }

    /// Encrypt and queue payload for batched sending. Flushes after 50ms or when buffer hits 20.
    public func sendEncryptedBatched(_ msg: AppMessage) throws {
        let json = try JSONEncoder().encode(msg)
        let encrypted = try crypto.encrypt(json)
        let payload = encrypted.base64EncodedString()

        batchQueue.async { [weak self] in
            guard let self else { return }
            self.batchBuffer.append(payload)

            if self.batchBuffer.count >= Self.batchMaxSize {
                self.batchTimer?.cancel()
                self.batchTimer = nil
                self._flushBatch()
            } else if self.batchTimer == nil {
                let timer = DispatchWorkItem { [weak self] in
                    self?._flushBatch()
                }
                self.batchTimer = timer
                self.batchQueue.asyncAfter(deadline: .now() + Self.batchFlushInterval, execute: timer)
            }
        }
    }

    /// Flush pending batch buffer. Must be called on batchQueue.
    private func _flushBatch() {
        batchTimer?.cancel()
        batchTimer = nil
        let payloads = batchBuffer
        batchBuffer = []
        guard !payloads.isEmpty else { return }

        if payloads.count == 1 {
            // Single payload: send as regular relay (no added overhead)
            let relay = RelayClientMessage(payload: payloads[0])
            if let text = try? JSONEncoder().encode(relay),
               let str = String(data: text, encoding: .utf8) {
                sendRaw(str)
            }
        } else {
            let batch = RelayBatchClientMessage(payloads: payloads)
            if let text = try? JSONEncoder().encode(batch),
               let str = String(data: text, encoding: .utf8) {
                sendRaw(str)
            }
        }
    }

    private static let activeHeartbeatInterval: TimeInterval = 1
    private static let activeWindow: TimeInterval = 15 * 60  // 15 minutes

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        let defaultInterval = heartbeatInterval
        let ackTimeout = heartbeatAckTimeout
        heartbeatTask = Task {
            while !Task.isCancelled {
                // Use 1s heartbeat if peer is connected or user was active within 15 minutes
                let interval: TimeInterval
                if self.peerAuthenticated {
                    interval = Self.activeHeartbeatInterval
                } else if let last = self.lastUserActivityTime,
                          Date().timeIntervalSince(last) < Self.activeWindow {
                    interval = Self.activeHeartbeatInterval
                } else {
                    interval = defaultInterval
                }
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { break }
                guard let encoded = try? JSONEncoder().encode(HeartbeatClientMessage()),
                      let text = String(data: encoded, encoding: .utf8) else { continue }
                sendRaw(text)

                // If no ack received within timeout, force reconnect
                if let lastAck = lastHeartbeatAckTime,
                   Date().timeIntervalSince(lastAck) > ackTimeout {
                    log("[relay] heartbeat ack timeout — forcing reconnect")
                    ws.disconnect()
                    break
                }
            }
        }
    }

    /// After first successful pairing, rotate the room secret so the QR code becomes one-time-use.
    /// Sends rotateSecret to iOS and waits for ack before committing.
    /// If ack is not received within 10s, the rotation is abandoned and both sides keep oldSecret.
    private func initiateSecretRotation() {
        guard !secretRotated else {
            log("[auth] secret already rotated, skipping")
            return
        }
        let newSecret = SessionCrypto.randomAlphanumeric(32)
        log("[auth] rotating room secret (first pairing) — waiting for iOS ack")

        // Don't commit yet — store as pending until iOS acknowledges.
        pendingRotationSecret = newSecret

        // Send new secret to iOS over the encrypted channel
        try? sendEncrypted(.rotateSecret(newSecret: newSecret))

        // Timeout: if iOS doesn't ack within 10s, abandon the rotation.
        // Relay keeps the old secret_hash so both sides can still reconnect with oldSecret.
        rotationTimeoutTask?.cancel()
        rotationTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, let self, self.pendingRotationSecret != nil else { return }
            log("[auth] rotateSecret not acknowledged by iOS within 10s — keeping old secret")
            self.pendingRotationSecret = nil
            self.onPairingFailed?()
        }
    }

    private func printConnectionInfo() {
        let maskedSecret = String(roomSecret.prefix(4)) + "••••"
        let contentLines = [
            "  RemoteDev Agent",
            "  Room:    \(roomID)",
            "  Secret:  \(maskedSecret)",
            "  WorkDir: \(workDir)",
        ]
        let width = contentLines.map(\.count).max() ?? 0
        let border = String(repeating: "═", count: width)
        let body = contentLines.map { line in
            "║\(line.padding(toLength: width, withPad: " ", startingAt: 0))║"
        }.joined(separator: "\n")
        log("╔\(border)╗\n\(body)\n╚\(border)╝")
        // Write connection info for test automation (permissions 0600)
        let infoPath = configDir + "/room_info.txt"
        let info = "\(roomID)\n\(roomSecret)\n"
        FileManager.default.createFile(atPath: infoPath, contents: Data(info.utf8), attributes: [.posixPermissions: 0o600])
    }

    private func jsonEncode<T: Encodable>(_ value: T) throws -> String {
        guard let str = String(data: try JSONEncoder().encode(value), encoding: .utf8) else {
            throw NSError(domain: "RelayConnection", code: -1, userInfo: [NSLocalizedDescriptionKey: "JSON encoding produced non-UTF8 data"])
        }
        return str
    }

}

#if os(macOS)
/// Thread-safe wrapper for tracking the previous NWPath for change detection.
private final class PathState: @unchecked Sendable {
    var current: NWPath?
}
#endif
