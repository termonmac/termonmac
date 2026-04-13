import Foundation
import RemoteDevCore

// Subcommand dispatch
if CommandLine.arguments.count >= 2 && CommandLine.arguments[1] == "ipad-sim" {
    await runIPadSim()
    exit(0)  // runIPadSim calls exit() internally, but just in case
}

// Usage: swift run TestPeer <roomID> <roomSecret> <serverURL>
// Example: swift run TestPeer K7X2M9 dK82xLm9... ws://localhost:8787

guard CommandLine.arguments.count >= 4 else {
    print("Usage: TestPeer <roomID> <roomSecret> <serverURL> [apiKey]")
    print("       TestPeer ipad-sim [--relay URL] [--room-id ID] [--pairing-token TOKEN] [--api-key KEY]")
    exit(1)
}

let roomID = CommandLine.arguments[1]
let roomSecret = CommandLine.arguments[2]
let serverURL = CommandLine.arguments[3]
let apiKey = CommandLine.arguments.count >= 5 ? CommandLine.arguments[4] : nil
let sandboxKey = ProcessInfo.processInfo.environment["SANDBOX_KEY"]

var passed = 0
var failed = 0

func check(_ name: String, _ condition: Bool) {
    if condition {
        passed += 1
        print("  PASS: \(name)")
    } else {
        failed += 1
        print("  FAIL: \(name)")
    }
}

do {
    let crypto = SessionCrypto()
    let ws = WebSocketClient()

    // Step 1: Connect to relay
    print("[1] Connecting to relay...")
    var components = URLComponents(string: "\(serverURL)/ws")!
    components.queryItems = [URLQueryItem(name: "room_id", value: roomID)]
    var request = URLRequest(url: components.url!)
    if let apiKey {
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    }
    if let sandboxKey, !sandboxKey.isEmpty {
        request.setValue(sandboxKey, forHTTPHeaderField: "X-Sandbox-Key")
    }
    try await ws.connect(request: request)

    // Step 2: Send join_room
    print("[2] Joining room...")
    let joinMsg = JoinRoomMessage(room_id: roomID, public_key: crypto.publicKeyBase64, secret_hash: SessionCrypto.sha256Hex(roomSecret))
    let joinJSON = String(data: try JSONEncoder().encode(joinMsg), encoding: .utf8)!
    try await ws.send(joinJSON)

    // Step 3: Wait for peer_joined (Mac's public key)
    print("[3] Waiting for peer_joined...")
    var macPublicKey: String?
    let stream = ws.receive()
    var iterator = stream.makeAsyncIterator()

    let peerMsg = try await iterator.next()!
    let serverMsg = try JSONDecoder().decode(ServerMessage.self, from: Data(peerMsg.utf8))
    if case .peerJoined(let pubKey, _, _) = serverMsg {
        macPublicKey = pubKey
        check("Received peer_joined", true)
    } else {
        check("Received peer_joined", false)
        print("    Got: \(peerMsg)")
    }

    // Step 4: Derive shared session key
    print("[4] Deriving session key...")
    guard let macPubKey = macPublicKey else {
        print("  FAIL: No Mac public key")
        exit(1)
    }
    try crypto.deriveSessionKey(peerPublicKeyBase64: macPubKey)
    check("Session key derived", true)

    // Step 5: Receive encrypted challenge from Mac
    print("[5] Waiting for challenge...")
    let challengeRelay = try await iterator.next()!
    let challengeServerMsg = try JSONDecoder().decode(ServerMessage.self, from: Data(challengeRelay.utf8))
    var challengeNonce: String?
    if case .relay(let payload) = challengeServerMsg {
        let cipherData = Data(base64Encoded: payload)!
        let plainData = try crypto.decrypt(cipherData)
        let appMsg = try JSONDecoder().decode(AppMessage.self, from: plainData)
        if case .challenge(let nonce) = appMsg {
            challengeNonce = nonce
            check("Received challenge", true)
        } else {
            check("Received challenge", false)
        }
    } else {
        check("Received challenge (relay)", false)
    }

    // Step 6: Send challenge_response
    print("[6] Sending challenge response...")
    guard let nonce = challengeNonce, let nonceData = Data(base64Encoded: nonce) else {
        print("  FAIL: No challenge nonce")
        exit(1)
    }
    let hmac = SessionCrypto.hmacSHA256(data: nonceData, key: Data(roomSecret.utf8))
    let responseMsg = AppMessage.challengeResponse(hmac: hmac.base64EncodedString())
    let responseJSON = try JSONEncoder().encode(responseMsg)
    let encrypted = try crypto.encrypt(responseJSON)
    let relayMsg = RelayClientMessage(payload: encrypted.base64EncodedString())
    let relayJSON = String(data: try JSONEncoder().encode(relayMsg), encoding: .utf8)!
    try await ws.send(relayJSON)
    check("Challenge response sent", true)

    // Step 7: Send pty_input "echo hello\n"
    print("[7] Sending pty_input...")
    // Wait a moment for Mac to start PTY after auth
    try await Task.sleep(for: .seconds(1))
    let inputData = "echo hello\n".data(using: .utf8)!
    let inputMsg = AppMessage.ptyInput(data: inputData.base64EncodedString(), sessionId: "")
    let inputJSON = try JSONEncoder().encode(inputMsg)
    let inputEncrypted = try crypto.encrypt(inputJSON)
    let inputRelay = RelayClientMessage(payload: inputEncrypted.base64EncodedString())
    let inputRelayJSON = String(data: try JSONEncoder().encode(inputRelay), encoding: .utf8)!
    try await ws.send(inputRelayJSON)
    check("pty_input sent", true)

    // Step 8: Wait for pty_data containing "hello"
    print("[8] Waiting for pty_data...")
    var foundHello = false
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
        guard let dataRelay = try await iterator.next() else { break }
        let dataServerMsg = try JSONDecoder().decode(ServerMessage.self, from: Data(dataRelay.utf8))
        if case .relay(let payload) = dataServerMsg {
            if let cipherData = Data(base64Encoded: payload) {
                let plain = try crypto.decrypt(cipherData)
                let appMsg = try JSONDecoder().decode(AppMessage.self, from: plain)
                if case .ptyData(let ptyBase64, _, _) = appMsg {
                    if let rawData = Data(base64Encoded: ptyBase64),
                       let text = String(data: rawData, encoding: .utf8) {
                        if text.contains("hello") {
                            foundHello = true
                            break
                        }
                    }
                }
            }
        }
    }
    check("pty_data contains 'hello'", foundHello)

    // Step 9: Send pty_resize
    print("[9] Sending pty_resize...")
    let resizeMsg = AppMessage.ptyResize(cols: 120, rows: 40, sessionId: "")
    let resizeJSON = try JSONEncoder().encode(resizeMsg)
    let resizeEncrypted = try crypto.encrypt(resizeJSON)
    let resizeRelay = RelayClientMessage(payload: resizeEncrypted.base64EncodedString())
    let resizeRelayJSON = String(data: try JSONEncoder().encode(resizeRelay), encoding: .utf8)!
    try await ws.send(resizeRelayJSON)
    check("pty_resize sent", true)

    // Step 10: Disconnect
    print("[10] Disconnecting...")
    ws.disconnect()
    check("Disconnected cleanly", true)

    // Summary
    print("\n=============================")
    print("Results: \(passed) passed, \(failed) failed")
    print("=============================")
    exit(failed > 0 ? 1 : 0)
} catch {
    print("ERROR: \(error)")
    exit(1)
}
