import Testing
import Foundation
@testable import RemoteDevCore

@Suite("Crypto Handshake Integration")
struct CryptoHandshakeTests {

    @Test("Full handshake: key exchange -> challenge -> HMAC verify -> bidirectional encryption")
    func fullHandshake() throws {
        let roomSecret = "my-room-secret-42"

        // 1. Both sides generate ephemeral keys + nonces
        let mac = SessionCrypto()
        let ios = SessionCrypto()
        let macNonce = SessionCrypto.randomAlphanumeric(16)
        let iosNonce = SessionCrypto.randomAlphanumeric(16)

        // 2. Exchange public keys + nonces, derive session keys
        try mac.deriveSessionKey(peerPublicKeyBase64: ios.publicKeyBase64, localNonce: macNonce, remoteNonce: iosNonce)
        try ios.deriveSessionKey(peerPublicKeyBase64: mac.publicKeyBase64, localNonce: iosNonce, remoteNonce: macNonce)

        // 3. Mac sends challenge: random nonce encrypted
        let challengeNonce = SessionCrypto.randomAlphanumeric(32)
        let challengeMsg = AppMessage.challenge(nonce: challengeNonce)
        let challengeJSON = try JSONEncoder().encode(challengeMsg)
        let challengeEncrypted = try mac.encrypt(challengeJSON)

        // 4. iOS decrypts challenge
        let challengeDecrypted = try ios.decrypt(challengeEncrypted)
        let receivedChallenge = try JSONDecoder().decode(AppMessage.self, from: challengeDecrypted)
        guard case .challenge(let receivedNonce) = receivedChallenge else {
            Issue.record("Expected challenge message"); return
        }
        #expect(receivedNonce == challengeNonce)

        // 5. iOS computes HMAC of nonce using room secret
        let hmac = SessionCrypto.hmacSHA256(
            data: Data(receivedNonce.utf8),
            key: Data(roomSecret.utf8)
        )
        let hmacHex = hmac.map { String(format: "%02x", $0) }.joined()
        let responseMsg = AppMessage.challengeResponse(hmac: hmacHex)
        let responseJSON = try JSONEncoder().encode(responseMsg)
        let responseEncrypted = try ios.encrypt(responseJSON)

        // 6. Mac decrypts and verifies HMAC
        let responseDecrypted = try mac.decrypt(responseEncrypted)
        let receivedResponse = try JSONDecoder().decode(AppMessage.self, from: responseDecrypted)
        guard case .challengeResponse(let receivedHmac) = receivedResponse else {
            Issue.record("Expected challengeResponse message"); return
        }

        let expectedHmac = SessionCrypto.hmacSHA256(
            data: Data(challengeNonce.utf8),
            key: Data(roomSecret.utf8)
        )
        let expectedHmacHex = expectedHmac.map { String(format: "%02x", $0) }.joined()
        #expect(receivedHmac == expectedHmacHex)

        // 7. Mac sends auth_ok
        let authOkJSON = try JSONEncoder().encode(AppMessage.authOk)
        let authOkEncrypted = try mac.encrypt(authOkJSON)
        let authOkDecrypted = try ios.decrypt(authOkEncrypted)
        let authOk = try JSONDecoder().decode(AppMessage.self, from: authOkDecrypted)
        guard case .authOk = authOk else {
            Issue.record("Expected authOk"); return
        }

        // 8. Bidirectional: iOS sends ptyInput, Mac sends ptyData
        let inputMsg = AppMessage.ptyInput(data: "bHM=", sessionId: "s1")
        let inputJSON = try JSONEncoder().encode(inputMsg)
        let inputEncrypted = try ios.encrypt(inputJSON)
        let inputDecrypted = try mac.decrypt(inputEncrypted)
        let decodedInput = try JSONDecoder().decode(AppMessage.self, from: inputDecrypted)
        guard case .ptyInput(let d, let sid) = decodedInput else {
            Issue.record("Expected ptyInput"); return
        }
        #expect(d == "bHM=")
        #expect(sid == "s1")

        let outputMsg = AppMessage.ptyData(data: "b3V0cHV0", sessionId: "s1", offset: 100)
        let outputJSON = try JSONEncoder().encode(outputMsg)
        let outputEncrypted = try mac.encrypt(outputJSON)
        let outputDecrypted = try ios.decrypt(outputEncrypted)
        let decodedOutput = try JSONDecoder().decode(AppMessage.self, from: outputDecrypted)
        guard case .ptyData(let od, let osid, let offset) = decodedOutput else {
            Issue.record("Expected ptyData"); return
        }
        #expect(od == "b3V0cHV0")
        #expect(osid == "s1")
        #expect(offset == 100)
    }

    @Test("Wrong room secret fails HMAC verification")
    func wrongRoomSecret() throws {
        let mac = SessionCrypto()
        let ios = SessionCrypto()
        try mac.deriveSessionKey(peerPublicKeyBase64: ios.publicKeyBase64)
        try ios.deriveSessionKey(peerPublicKeyBase64: mac.publicKeyBase64)

        let challengeNonce = "test-nonce-123"

        // Mac computes expected HMAC with correct secret
        let expectedHmac = SessionCrypto.hmacSHA256(
            data: Data(challengeNonce.utf8),
            key: Data("correct-secret".utf8)
        )

        // iOS computes HMAC with wrong secret
        let wrongHmac = SessionCrypto.hmacSHA256(
            data: Data(challengeNonce.utf8),
            key: Data("wrong-secret".utf8)
        )

        #expect(expectedHmac != wrongHmac)
    }
}
