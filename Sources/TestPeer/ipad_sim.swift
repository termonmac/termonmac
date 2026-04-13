// ipad_sim.swift — Simulates iPad pairing flow from CLI
// Build: cd mac_agent && swift build -c release --product TestPeer
// Usage: .build/.../TestPeer ipad-sim [--relay URL] [--room-id ID] [--pairing-token TOKEN] [--api-key KEY]
//
// Auto-reads from ~/.config/termonmac/ if flags are omitted.

import Foundation
import RemoteDevCore

// MARK: - Argument parsing

func arg(_ name: String) -> String? {
    guard let idx = CommandLine.arguments.firstIndex(of: "--\(name)"),
          idx + 1 < CommandLine.arguments.count else { return nil }
    return CommandLine.arguments[idx + 1]
}

func readFile(_ path: String) -> String? {
    try? String(contentsOfFile: path, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
}

func runIPadSim() async {
    let configDir = arg("config-dir") ?? "\(NSHomeDirectory())/.config/termonmac"
    let relay = arg("relay") ?? "wss://relay.termonmac.com"
    let roomID = arg("room-id") ?? readFile("\(configDir)/room.json").flatMap({
        (try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])?["room_id"] as? String
    })
    let pairingToken = arg("pairing-token") ?? readFile("\(configDir)/pairing_token")
    let adminToken = arg("admin-token") ?? ProcessInfo.processInfo.environment["ADMIN_TOKEN"]
    let apiKey = adminToken ?? arg("api-key") ?? readFile("\(configDir)/api_key")

    guard let roomID else {
        print("❌ No room_id. Pass --room-id or ensure \(configDir)/room.json exists.")
        exit(1)
    }
    guard let pairingToken, !pairingToken.isEmpty else {
        print("❌ No pairing token. Run 'termonmac pair' first, or pass --pairing-token.")
        exit(1)
    }

    print("╔══════════════════════════════════════════════╗")
    print("║       iPad Pairing Simulator (CLI)           ║")
    print("╠══════════════════════════════════════════════╣")
    print("║ Relay:   \(relay.prefix(36).padding(toLength: 36, withPad: " ", startingAt: 0))║")
    print("║ Room:    \(roomID.padding(toLength: 36, withPad: " ", startingAt: 0))║")
    print("║ Token:   \(pairingToken.prefix(8))...                           ║")
    print("╚══════════════════════════════════════════════╝")

    let crypto = SessionCrypto()
    let ws = WebSocketClient()
    let tokenHash = SessionCrypto.sha256Hex(pairingToken)

    // Step 1: WebSocket connect
    print("\n[1/7] Connecting to relay...")
    var components = URLComponents(string: "\(relay)/ws")!
    var queryItems = [
        URLQueryItem(name: "room_id", value: roomID),
        URLQueryItem(name: "role", value: "ios"),
    ]
    if adminToken != nil {
        // Admin token needs explicit user_id for room registration
        let userId = arg("user-id") ?? ""
        if !userId.isEmpty {
            queryItems.append(URLQueryItem(name: "user_id", value: userId))
        }
    }
    components.queryItems = queryItems
    var request = URLRequest(url: components.url!)
    if let apiKey {
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    }

    do {
        try await ws.connect(request: request)
    } catch {
        print("  ❌ WebSocket connect failed: \(error)")
        if let wsErr = error as? WebSocketClient.WebSocketError,
           case .httpUpgradeFailed(let code) = wsErr {
            print("  HTTP \(code) — likely room limit or auth issue")
        }
        exit(1)
    }
    print("  ✅ WebSocket connected")

    // Step 2: Send join_room with pairing_token_hash
    print("\n[2/7] Joining room with pairing_token_hash...")
    let joinMsg = JoinRoomMessage(
        room_id: roomID,
        public_key: crypto.publicKeyBase64,
        pairing_token_hash: tokenHash
    )
    let joinJSON = String(data: try! JSONEncoder().encode(joinMsg), encoding: .utf8)!
    try! await ws.send(joinJSON)
    print("  ✅ join_room sent (public_key=\(crypto.publicKeyBase64.prefix(16))...)")

    // Step 3: Wait for messages
    print("\n[3/7] Waiting for peer_joined (Mac)...")
    let stream = ws.receive()
    var iterator = stream.makeAsyncIterator()

    var macPubKey: String?
    var macSessionNonce = ""
    var macEphKey = ""
    var gotPairingCreds = false
    var roomSecret: String?

    let timeout = Task {
        try await Task.sleep(for: .seconds(15))
        print("\n  ⏰ Timeout (15s) — Mac did not respond. Possible causes:")
        print("     • Mac agent not running")
        print("     • TOFU blocking (Mac rejects iPad key)")
        print("     • Network issue")
        ws.disconnect()
        exit(1)
    }

    // Read first message — expect peer_joined or error
    guard let firstMsg = try? await iterator.next() else {
        timeout.cancel()
        print("  ❌ Stream ended before receiving any message")
        if let code = ws.lastCloseCode {
            print("  Close code: \(code)")
            if code == 4001 { print("  → Replaced by another device (4001)") }
            if code == 4003 { print("  → Auth failed (4003) — pairing token rejected") }
        }
        exit(1)
    }

    do {
        let serverMsg = try JSONDecoder().decode(ServerMessage.self, from: Data(firstMsg.utf8))
        switch serverMsg {
        case .peerJoined(let pk, let sn, let ek):
            macPubKey = pk
            macSessionNonce = sn
            macEphKey = ek
            print("  ✅ Mac peer_joined (key=\(pk.prefix(16))...)")
        case .error(let code, let message, _, _):
            timeout.cancel()
            print("  ❌ Error from relay: \(code) — \(message)")
            exit(1)
        default:
            timeout.cancel()
            print("  ❌ Unexpected message: \(firstMsg.prefix(200))")
            exit(1)
        }
    } catch {
        timeout.cancel()
        print("  ❌ Decode error: \(error)")
        print("  Raw: \(firstMsg.prefix(200))")
        exit(1)
    }

    // Step 4: Derive session key
    print("\n[4/7] Deriving session key...")
    do {
        try crypto.deriveSessionKey(peerPublicKeyBase64: macPubKey!)
        print("  ✅ Session key derived")
    } catch {
        timeout.cancel()
        print("  ❌ Key derivation failed: \(error)")
        exit(1)
    }

    // Step 5: Wait for challenge + respond
    print("\n[5/7] Waiting for challenge from Mac...")
    guard let challengeRelay = try? await iterator.next() else {
        timeout.cancel()
        print("  ❌ Stream ended waiting for challenge")
        if let code = ws.lastCloseCode {
            print("  Close code: \(code)")
        }
        exit(1)
    }

    var challengeNonce: String?
    do {
        let challengeServerMsg = try JSONDecoder().decode(ServerMessage.self, from: Data(challengeRelay.utf8))
        if case .relay(let payload) = challengeServerMsg {
            let cipherData = Data(base64Encoded: payload)!
            let plainData = try crypto.decrypt(cipherData)
            let appMsg = try JSONDecoder().decode(AppMessage.self, from: plainData)
            if case .challenge(let n) = appMsg {
                challengeNonce = n
                print("  ✅ Challenge received")
            } else {
                timeout.cancel()
                print("  ❌ Expected challenge, got: \(appMsg)")
                exit(1)
            }
        } else if case .peerDisconnected(let reason) = challengeServerMsg {
            timeout.cancel()
            print("  ❌ Mac disconnected: \(reason)")
            print("  → This usually means TOFU rejected iPad's key")
            exit(1)
        } else {
            timeout.cancel()
            print("  ❌ Unexpected: \(challengeRelay.prefix(200))")
            exit(1)
        }
    } catch {
        timeout.cancel()
        print("  ❌ Challenge decode failed: \(error)")
        exit(1)
    }

    // Step 6: Send challenge response (HMAC with pairing token)
    print("\n[6/7] Sending challenge response (HMAC with pairing_token)...")
    let nonceData = Data(base64Encoded: challengeNonce!)!
    let hmac = SessionCrypto.hmacSHA256(data: nonceData, key: Data(pairingToken.utf8))
    let responseMsg = AppMessage.challengeResponse(hmac: hmac.base64EncodedString())
    let responseJSON = try! JSONEncoder().encode(responseMsg)
    let encrypted = try! crypto.encrypt(responseJSON)
    let relayMsg = RelayClientMessage(payload: encrypted.base64EncodedString())
    let relayJSON = String(data: try! JSONEncoder().encode(relayMsg), encoding: .utf8)!
    try! await ws.send(relayJSON)
    print("  ✅ Challenge response sent")

    // Step 7: Wait for pairingCredentials or authOk
    print("\n[7/7] Waiting for pairing credentials...")
    let maxMessages = 10
    for _ in 0..<maxMessages {
        guard let msg = try? await iterator.next() else {
            if let code = ws.lastCloseCode {
                print("  ❌ Stream ended — close code: \(code)")
                if code == 4001 { print("  → Replaced by another device (4001) — iPhone reconnected and kicked us") }
            } else {
                print("  ❌ Stream ended (no close code)")
            }
            break
        }

        do {
            let serverMsg = try JSONDecoder().decode(ServerMessage.self, from: Data(msg.utf8))
            switch serverMsg {
            case .relay(let payload):
                if let cipherData = Data(base64Encoded: payload) {
                    let plainData = try crypto.decrypt(cipherData)
                    let appMsg = try JSONDecoder().decode(AppMessage.self, from: plainData)
                    switch appMsg {
                    case .pairingCredentials(let secret):
                        roomSecret = secret
                        gotPairingCreds = true
                        print("  ✅ Got pairingCredentials! secret=\(secret.prefix(8))...")
                    case .authOk:
                        print("  ✅ authOk received")
                    case .challenge:
                        // Reverse challenge from Mac
                        print("  ℹ️  Reverse challenge received (answering...)")
                        let rcNonce = try JSONDecoder().decode(AppMessage.self, from: plainData)
                        if case .challenge(let rn) = rcNonce,
                           let rnData = Data(base64Encoded: rn) {
                            let rcHmac = SessionCrypto.hmacSHA256(data: rnData, key: Data(pairingToken.utf8))
                            let rcResp = AppMessage.challengeResponse(hmac: rcHmac.base64EncodedString())
                            let rcJSON = try JSONEncoder().encode(rcResp)
                            let rcEnc = try crypto.encrypt(rcJSON)
                            let rcRelay = RelayClientMessage(payload: rcEnc.base64EncodedString())
                            let rcRelayJSON = String(data: try JSONEncoder().encode(rcRelay), encoding: .utf8)!
                            try await ws.send(rcRelayJSON)
                        }
                    case .ptySessions:
                        print("  ℹ️  Got ptySessions (Mac sent session list)")
                    default:
                        print("  ℹ️  App message: \(String(data: plainData, encoding: .utf8)?.prefix(100) ?? "?")")
                    }
                }
            case .peerDisconnected(let reason):
                print("  ⚠️  Mac disconnected: \(reason)")
            case .heartbeatAck:
                continue
            default:
                print("  ℹ️  Server: \(msg.prefix(100))")
            }
        } catch {
            print("  ⚠️  Decode: \(error) — raw: \(msg.prefix(100))")
        }

        if gotPairingCreds { break }
    }

    timeout.cancel()

    // Summary
    print("\n╔══════════════════════════════════════════════╗")
    if gotPairingCreds {
        print("║  ✅ PAIRING SUCCESS                          ║")
        print("║  iPad got room_secret from Mac               ║")
        print("║  TOFU fix works — Mac accepted new key       ║")
    } else {
        print("║  ❌ PAIRING FAILED                            ║")
        print("║  iPad did not get pairingCredentials          ║")
    }
    print("╚══════════════════════════════════════════════╝")

    ws.disconnect()
    exit(gotPairingCreds ? 0 : 1)
}

// Entry point — only runs when "ipad-sim" subcommand is used
