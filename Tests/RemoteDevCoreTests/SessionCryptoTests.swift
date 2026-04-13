import Testing
import Foundation
import CryptoKit
@testable import RemoteDevCore

@Suite("SessionCrypto")
struct SessionCryptoTests {

    // MARK: - Key pair generation & loading

    @Test("Generate key pair and re-import round-trip")
    func keyPairRoundTrip() throws {
        let crypto = SessionCrypto()
        let exported = crypto.privateKey.rawRepresentation
        let reimported = try SessionCrypto(privateKeyData: exported)
        #expect(crypto.publicKeyBase64 == reimported.publicKeyBase64)
    }

    @Test("Public key data is 32 bytes")
    func publicKeySize() {
        let crypto = SessionCrypto()
        #expect(crypto.publicKeyData.count == 32)
    }

    // MARK: - Session key derivation (legacy, no nonces)

    @Test("Two peers derive the same session key and can decrypt each other")
    func ecdhLegacy() throws {
        let alice = SessionCrypto()
        let bob = SessionCrypto()

        try alice.deriveSessionKey(peerPublicKeyBase64: bob.publicKeyBase64)
        try bob.deriveSessionKey(peerPublicKeyBase64: alice.publicKeyBase64)

        let plaintext = Data("hello from alice".utf8)
        let ciphertext = try alice.encrypt(plaintext)
        let decrypted = try bob.decrypt(ciphertext)
        #expect(decrypted == plaintext)
    }

    // MARK: - Session key derivation (with nonces)

    @Test("ECDH with nonces: A encrypts, B decrypts")
    func ecdhWithNonces() throws {
        let alice = SessionCrypto()
        let bob = SessionCrypto()
        let nonceA = "nonceAAAA"
        let nonceB = "nonceBBBB"

        try alice.deriveSessionKey(peerPublicKeyBase64: bob.publicKeyBase64, localNonce: nonceA, remoteNonce: nonceB)
        try bob.deriveSessionKey(peerPublicKeyBase64: alice.publicKeyBase64, localNonce: nonceB, remoteNonce: nonceA)

        let plaintext = Data("secret message".utf8)
        let ct = try alice.encrypt(plaintext)
        let pt = try bob.decrypt(ct)
        #expect(pt == plaintext)
    }

    @Test("Nonce ordering: swapping local/remote produces same key")
    func nonceOrdering() throws {
        let alice = SessionCrypto()
        let bob = SessionCrypto()

        // Both sides sort nonces the same way
        try alice.deriveSessionKey(peerPublicKeyBase64: bob.publicKeyBase64, localNonce: "ZZZ", remoteNonce: "AAA")
        try bob.deriveSessionKey(peerPublicKeyBase64: alice.publicKeyBase64, localNonce: "AAA", remoteNonce: "ZZZ")

        let data = Data("test".utf8)
        let ct = try alice.encrypt(data)
        let pt = try bob.decrypt(ct)
        #expect(pt == data)
    }

    // MARK: - Encrypt/decrypt round-trip

    @Test("Encrypt/decrypt arbitrary data round-trip")
    func encryptDecryptRoundTrip() throws {
        let alice = SessionCrypto()
        let bob = SessionCrypto()
        try alice.deriveSessionKey(peerPublicKeyBase64: bob.publicKeyBase64)
        try bob.deriveSessionKey(peerPublicKeyBase64: alice.publicKeyBase64)

        // Test various sizes
        for size in [1, 16, 256, 65536] {
            let data = SessionCrypto.randomBytes(size)
            let ct = try alice.encrypt(data)
            let pt = try bob.decrypt(ct)
            #expect(pt == data, "Failed for size \(size)")
        }
    }

    // MARK: - Error cases

    @Test("Decrypt without session key throws noSessionKey")
    func decryptWithoutSessionKey() {
        let crypto = SessionCrypto()
        #expect(throws: SessionCrypto.CryptoError.noSessionKey) {
            try crypto.decrypt(Data(repeating: 0, count: 50))
        }
    }

    @Test("Encrypt without session key throws noSessionKey")
    func encryptWithoutSessionKey() {
        let crypto = SessionCrypto()
        #expect(throws: SessionCrypto.CryptoError.noSessionKey) {
            try crypto.encrypt(Data("hello".utf8))
        }
    }

    @Test("Decrypt short data throws invalidData")
    func decryptShortData() throws {
        let crypto = SessionCrypto()
        let other = SessionCrypto()
        try crypto.deriveSessionKey(peerPublicKeyBase64: other.publicKeyBase64)
        // Data must be > 28 bytes (12 nonce + 16 tag minimum)
        #expect(throws: SessionCrypto.CryptoError.invalidData) {
            try crypto.decrypt(Data(repeating: 0, count: 20))
        }
    }

    @Test("Tampered ciphertext fails decryption")
    func tamperedCiphertext() throws {
        let alice = SessionCrypto()
        let bob = SessionCrypto()
        try alice.deriveSessionKey(peerPublicKeyBase64: bob.publicKeyBase64)
        try bob.deriveSessionKey(peerPublicKeyBase64: alice.publicKeyBase64)

        var ct = try alice.encrypt(Data("secret".utf8))
        // Flip a byte in the ciphertext portion
        ct[15] ^= 0xFF
        #expect(throws: (any Error).self) {
            try bob.decrypt(ct)
        }
    }

    @Test("Invalid base64 public key throws invalidKey")
    func invalidPublicKey() {
        let crypto = SessionCrypto()
        #expect(throws: SessionCrypto.CryptoError.invalidKey) {
            try crypto.deriveSessionKey(peerPublicKeyBase64: "not-valid-base64!!!")
        }
    }

    // MARK: - HMAC / SHA256

    @Test("SHA256 hex produces correct output for known input")
    func sha256Hex() {
        // SHA-256 of empty string
        let hash = SessionCrypto.sha256Hex("")
        #expect(hash == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    @Test("HMAC-SHA256 produces 32-byte output")
    func hmacLength() {
        let hmac = SessionCrypto.hmacSHA256(data: Data("msg".utf8), key: Data("key".utf8))
        #expect(hmac.count == 32)
    }

    @Test("HMAC-SHA256 is deterministic")
    func hmacDeterministic() {
        let d = Data("hello".utf8)
        let k = Data("secret".utf8)
        let h1 = SessionCrypto.hmacSHA256(data: d, key: k)
        let h2 = SessionCrypto.hmacSHA256(data: d, key: k)
        #expect(h1 == h2)
    }

    // MARK: - Random bytes

    @Test("randomBytes produces correct length")
    func randomBytesLength() {
        #expect(SessionCrypto.randomBytes(0).count == 0)
        #expect(SessionCrypto.randomBytes(32).count == 32)
        #expect(SessionCrypto.randomBytes(64).count == 64)
    }

    @Test("randomAlphanumeric produces correct length and charset")
    func randomAlphanumeric() {
        let s = SessionCrypto.randomAlphanumeric(20)
        #expect(s.count == 20)
        let valid = CharacterSet.alphanumerics
        #expect(s.unicodeScalars.allSatisfy { valid.contains($0) })
    }

    // MARK: - Key pair properties

    @Test("Two fresh instances have different key pairs")
    func freshKeysAreDifferent() {
        let a = SessionCrypto()
        let b = SessionCrypto()
        #expect(a.publicKeyBase64 != b.publicKeyBase64)
    }

    @Test("publicKeyBase64 matches base64 encoding of publicKeyData")
    func publicKeyConsistency() {
        let crypto = SessionCrypto()
        #expect(crypto.publicKeyBase64 == crypto.publicKeyData.base64EncodedString())
    }

    @Test("init with invalid private key data throws")
    func invalidPrivateKeyData() {
        #expect(throws: (any Error).self) {
            try SessionCrypto(privateKeyData: Data([0x00, 0x01, 0x02]))
        }
    }

    // MARK: - clearSessionKey

    @Test("clearSessionKey causes subsequent encrypt to throw noSessionKey")
    func clearSessionKeyThenEncrypt() throws {
        let alice = SessionCrypto()
        let bob = SessionCrypto()
        try alice.deriveSessionKey(peerPublicKeyBase64: bob.publicKeyBase64)

        // Encrypt works before clear
        _ = try alice.encrypt(Data("test".utf8))

        alice.clearSessionKey()

        #expect(throws: SessionCrypto.CryptoError.noSessionKey) {
            try alice.encrypt(Data("test".utf8))
        }
    }

    @Test("clearSessionKey causes subsequent decrypt to throw noSessionKey")
    func clearSessionKeyThenDecrypt() throws {
        let alice = SessionCrypto()
        let bob = SessionCrypto()
        try alice.deriveSessionKey(peerPublicKeyBase64: bob.publicKeyBase64)
        try bob.deriveSessionKey(peerPublicKeyBase64: alice.publicKeyBase64)

        let ct = try alice.encrypt(Data("test".utf8))
        bob.clearSessionKey()

        #expect(throws: SessionCrypto.CryptoError.noSessionKey) {
            try bob.decrypt(ct)
        }
    }

    // MARK: - Ciphertext uniqueness

    @Test("Encrypting same plaintext twice produces different ciphertext (unique nonces)")
    func ciphertextUniqueness() throws {
        let alice = SessionCrypto()
        let bob = SessionCrypto()
        try alice.deriveSessionKey(peerPublicKeyBase64: bob.publicKeyBase64)

        let plaintext = Data("same message".utf8)
        let ct1 = try alice.encrypt(plaintext)
        let ct2 = try alice.encrypt(plaintext)
        #expect(ct1 != ct2)
    }

    // MARK: - Cross-derivation isolation

    @Test("Legacy derivation and nonce derivation produce different session keys")
    func legacyVsNonceDerivation() throws {
        let alice = SessionCrypto()
        let bob = SessionCrypto()

        // Legacy derivation on alice
        let aliceLegacyCopy = try SessionCrypto(privateKeyData: alice.privateKey.rawRepresentation)
        try aliceLegacyCopy.deriveSessionKey(peerPublicKeyBase64: bob.publicKeyBase64)

        // Nonce derivation on alice (same key pair)
        let aliceNonce = try SessionCrypto(privateKeyData: alice.privateKey.rawRepresentation)
        try aliceNonce.deriveSessionKey(peerPublicKeyBase64: bob.publicKeyBase64, localNonce: "A", remoteNonce: "B")

        // Both should be able to encrypt, but produce different session keys
        let data = Data("test".utf8)
        _ = try aliceLegacyCopy.encrypt(data)
        let ctNonce = try aliceNonce.encrypt(data)

        // Bob with legacy derivation should NOT decrypt nonce-derived ciphertext
        try bob.deriveSessionKey(peerPublicKeyBase64: alice.publicKeyBase64)
        #expect(throws: (any Error).self) {
            try bob.decrypt(ctNonce)
        }
    }

    @Test("Different nonces produce different session keys")
    func differentNoncesDifferentKeys() throws {
        let alice1 = SessionCrypto()
        let alice2 = try SessionCrypto(privateKeyData: alice1.privateKey.rawRepresentation)
        let bob = SessionCrypto()

        try alice1.deriveSessionKey(peerPublicKeyBase64: bob.publicKeyBase64, localNonce: "nonce1", remoteNonce: "nonce2")
        try alice2.deriveSessionKey(peerPublicKeyBase64: bob.publicKeyBase64, localNonce: "nonce3", remoteNonce: "nonce4")

        let data = Data("test".utf8)
        let ct1 = try alice1.encrypt(data)

        // bob derives with alice1's nonces — should decrypt ct1
        try bob.deriveSessionKey(peerPublicKeyBase64: alice1.publicKeyBase64, localNonce: "nonce2", remoteNonce: "nonce1")
        let pt = try bob.decrypt(ct1)
        #expect(pt == data)

        // bob re-derives with alice2's nonces — should NOT decrypt ct1
        let bob2Copy = try SessionCrypto(privateKeyData: bob.privateKey.rawRepresentation)
        try bob2Copy.deriveSessionKey(peerPublicKeyBase64: alice2.publicKeyBase64, localNonce: "nonce4", remoteNonce: "nonce3")
        let ct2 = try alice2.encrypt(data)
        let pt2 = try bob2Copy.decrypt(ct2)
        #expect(pt2 == data)

        // Cross: bob2Copy should NOT decrypt ct1 (different nonces = different key)
        #expect(throws: (any Error).self) {
            try bob2Copy.decrypt(ct1)
        }
    }

    // MARK: - Decrypt boundary

    @Test("Decrypt exactly 28 bytes throws invalidData")
    func decryptExactly28Bytes() throws {
        let crypto = SessionCrypto()
        let other = SessionCrypto()
        try crypto.deriveSessionKey(peerPublicKeyBase64: other.publicKeyBase64)
        // 28 bytes is NOT > 28, so it should throw invalidData
        #expect(throws: SessionCrypto.CryptoError.invalidData) {
            try crypto.decrypt(Data(repeating: 0, count: 28))
        }
    }

    @Test("Decrypt 29 bytes does not throw invalidData (but may fail authentication)")
    func decrypt29BytesNotInvalidData() throws {
        let crypto = SessionCrypto()
        let other = SessionCrypto()
        try crypto.deriveSessionKey(peerPublicKeyBase64: other.publicKeyBase64)
        // 29 bytes passes the length check, but GCM authentication will fail
        do {
            _ = try crypto.decrypt(Data(repeating: 0, count: 29))
            Issue.record("Expected GCM authentication failure")
        } catch SessionCrypto.CryptoError.invalidData {
            Issue.record("Should not throw invalidData for 29 bytes")
        } catch {
            // Expected: CryptoKit error for invalid GCM tag
        }
    }

    @Test("Encrypt empty data produces 28 bytes (nonce+tag) which fails decrypt length check")
    func encryptEmptyDataCannotRoundTrip() throws {
        let alice = SessionCrypto()
        let bob = SessionCrypto()
        try alice.deriveSessionKey(peerPublicKeyBase64: bob.publicKeyBase64)
        try bob.deriveSessionKey(peerPublicKeyBase64: alice.publicKeyBase64)

        let ct = try alice.encrypt(Data())
        #expect(ct.count == 28) // 12 nonce + 0 ciphertext + 16 tag
        // decrypt guard requires count > 28, so this throws invalidData
        #expect(throws: SessionCrypto.CryptoError.invalidData) {
            try bob.decrypt(ct)
        }
    }

    // MARK: - Ephemeral key derivation (forward secrecy)

    @Test("Ephemeral ECDH: two peers derive same key and can communicate")
    func ephemeralECDH() throws {
        let macIdentity = SessionCrypto()
        let iosIdentity = SessionCrypto()

        let macEph = Curve25519.KeyAgreement.PrivateKey()
        let iosEph = Curve25519.KeyAgreement.PrivateKey()
        let macEphPub = macEph.publicKey.rawRepresentation.base64EncodedString()
        let iosEphPub = iosEph.publicKey.rawRepresentation.base64EncodedString()

        let macNonce = "macNonce"
        let iosNonce = "iosNonce"

        try macIdentity.deriveSessionKeyEphemeral(
            ephemeralPrivateKey: macEph,
            peerEphemeralKeyBase64: iosEphPub,
            localNonce: macNonce,
            remoteNonce: iosNonce
        )
        try iosIdentity.deriveSessionKeyEphemeral(
            ephemeralPrivateKey: iosEph,
            peerEphemeralKeyBase64: macEphPub,
            localNonce: iosNonce,
            remoteNonce: macNonce
        )

        let plaintext = Data("ephemeral secret".utf8)
        let ct = try macIdentity.encrypt(plaintext)
        let pt = try iosIdentity.decrypt(ct)
        #expect(pt == plaintext)

        // Reverse direction
        let ct2 = try iosIdentity.encrypt(plaintext)
        let pt2 = try macIdentity.decrypt(ct2)
        #expect(pt2 == plaintext)
    }

    @Test("Ephemeral keys differ from identity-based derivation")
    func ephemeralVsIdentityDerivation() throws {
        let mac = SessionCrypto()
        let ios = SessionCrypto()
        let nonce1 = "n1"
        let nonce2 = "n2"

        // Identity-based derivation
        let macCopy = try SessionCrypto(privateKeyData: mac.privateKey.rawRepresentation)
        try macCopy.deriveSessionKey(peerPublicKeyBase64: ios.publicKeyBase64, localNonce: nonce1, remoteNonce: nonce2)

        // Ephemeral derivation (different keys → different shared secret)
        let eph = Curve25519.KeyAgreement.PrivateKey()
        let iosEph = Curve25519.KeyAgreement.PrivateKey()
        try mac.deriveSessionKeyEphemeral(
            ephemeralPrivateKey: eph,
            peerEphemeralKeyBase64: iosEph.publicKey.rawRepresentation.base64EncodedString(),
            localNonce: nonce1,
            remoteNonce: nonce2
        )

        let data = Data("test".utf8)
        let ctIdentity = try macCopy.encrypt(data)
        // mac now has ephemeral-derived key — should NOT decrypt identity-derived ciphertext
        #expect(throws: (any Error).self) {
            try mac.decrypt(ctIdentity)
        }
    }

    @Test("Ephemeral derivation uses v2 salt, not v1")
    func ephemeralUsesV2Salt() throws {
        // Same ephemeral keys but using identity derivation (v1) vs ephemeral derivation (v2)
        // should produce different session keys even with same ECDH shared secret
        let eph1 = Curve25519.KeyAgreement.PrivateKey()
        let eph2 = Curve25519.KeyAgreement.PrivateKey()
        let eph2Pub = eph2.publicKey.rawRepresentation.base64EncodedString()

        // Use ephemeral keys AS identity keys for identity derivation
        let identityCrypto = try SessionCrypto(privateKeyData: eph1.rawRepresentation)
        try identityCrypto.deriveSessionKey(peerPublicKeyBase64: eph2Pub, localNonce: "A", remoteNonce: "B")

        // Same ECDH but via ephemeral path (v2 salt)
        let ephCrypto = SessionCrypto()
        try ephCrypto.deriveSessionKeyEphemeral(
            ephemeralPrivateKey: eph1,
            peerEphemeralKeyBase64: eph2Pub,
            localNonce: "A",
            remoteNonce: "B"
        )

        let data = Data("test".utf8)
        let ctIdentity = try identityCrypto.encrypt(data)

        // ephCrypto has different session key due to v2 salt — cannot decrypt
        #expect(throws: (any Error).self) {
            try ephCrypto.decrypt(ctIdentity)
        }
    }

    @Test("Ephemeral derivation with invalid base64 throws invalidKey")
    func ephemeralInvalidKey() {
        let crypto = SessionCrypto()
        let eph = Curve25519.KeyAgreement.PrivateKey()
        #expect(throws: SessionCrypto.CryptoError.invalidKey) {
            try crypto.deriveSessionKeyEphemeral(
                ephemeralPrivateKey: eph,
                peerEphemeralKeyBase64: "not-base64!!!",
                localNonce: "A",
                remoteNonce: "B"
            )
        }
    }

    @Test("Ephemeral nonce ordering: swapped local/remote produce same key")
    func ephemeralNonceOrdering() throws {
        let macEph = Curve25519.KeyAgreement.PrivateKey()
        let iosEph = Curve25519.KeyAgreement.PrivateKey()
        let macEphPub = macEph.publicKey.rawRepresentation.base64EncodedString()
        let iosEphPub = iosEph.publicKey.rawRepresentation.base64EncodedString()

        let mac = SessionCrypto()
        let ios = SessionCrypto()

        try mac.deriveSessionKeyEphemeral(
            ephemeralPrivateKey: macEph,
            peerEphemeralKeyBase64: iosEphPub,
            localNonce: "ZZZ",
            remoteNonce: "AAA"
        )
        try ios.deriveSessionKeyEphemeral(
            ephemeralPrivateKey: iosEph,
            peerEphemeralKeyBase64: macEphPub,
            localNonce: "AAA",
            remoteNonce: "ZZZ"
        )

        let data = Data("nonce order test".utf8)
        let ct = try mac.encrypt(data)
        let pt = try ios.decrypt(ct)
        #expect(pt == data)
    }

    // MARK: - challengeHMAC

    @Test("challengeHMAC without ephemeral keys uses nonce only")
    func challengeHMACNoEphemeralKeys() {
        let nonce = Data("test-nonce".utf8)
        let secret = "room-secret"

        let hmac = SessionCrypto.challengeHMAC(nonce: nonce, roomSecret: secret)
        let expected = SessionCrypto.hmacSHA256(data: nonce, key: Data(secret.utf8))
        #expect(hmac == expected)
    }

    @Test("challengeHMAC with empty ephemeral keys behaves like no keys")
    func challengeHMACEmptyEphemeralKeys() {
        let nonce = Data("test-nonce".utf8)
        let secret = "room-secret"

        let hmac1 = SessionCrypto.challengeHMAC(nonce: nonce, roomSecret: secret)
        let hmac2 = SessionCrypto.challengeHMAC(nonce: nonce, roomSecret: secret, localEphemeralKey: "", peerEphemeralKey: "")
        #expect(hmac1 == hmac2)
    }

    @Test("challengeHMAC with one empty ephemeral key behaves like no keys")
    func challengeHMACOneEmptyKey() {
        let nonce = Data("test-nonce".utf8)
        let secret = "room-secret"

        let hmacNone = SessionCrypto.challengeHMAC(nonce: nonce, roomSecret: secret)
        let hmacOneEmpty = SessionCrypto.challengeHMAC(nonce: nonce, roomSecret: secret, localEphemeralKey: "somekey", peerEphemeralKey: "")
        // With one empty key, the condition !local.isEmpty && !peer.isEmpty is false
        #expect(hmacNone == hmacOneEmpty)
    }

    @Test("challengeHMAC with ephemeral keys differs from without")
    func challengeHMACWithEphemeralKeys() {
        let nonce = Data("test-nonce".utf8)
        let secret = "room-secret"

        let hmacNoKeys = SessionCrypto.challengeHMAC(nonce: nonce, roomSecret: secret)
        let hmacWithKeys = SessionCrypto.challengeHMAC(
            nonce: nonce, roomSecret: secret,
            localEphemeralKey: "keyA", peerEphemeralKey: "keyB"
        )
        #expect(hmacNoKeys != hmacWithKeys)
    }

    @Test("challengeHMAC ephemeral key order does not matter (sorted internally)")
    func challengeHMACKeyOrder() {
        let nonce = Data("test-nonce".utf8)
        let secret = "room-secret"

        let hmac1 = SessionCrypto.challengeHMAC(
            nonce: nonce, roomSecret: secret,
            localEphemeralKey: "keyA", peerEphemeralKey: "keyZ"
        )
        let hmac2 = SessionCrypto.challengeHMAC(
            nonce: nonce, roomSecret: secret,
            localEphemeralKey: "keyZ", peerEphemeralKey: "keyA"
        )
        #expect(hmac1 == hmac2)
    }

    @Test("challengeHMAC with different room secrets produces different HMACs")
    func challengeHMACDifferentSecrets() {
        let nonce = Data("test-nonce".utf8)
        let hmac1 = SessionCrypto.challengeHMAC(nonce: nonce, roomSecret: "secret1", localEphemeralKey: "k1", peerEphemeralKey: "k2")
        let hmac2 = SessionCrypto.challengeHMAC(nonce: nonce, roomSecret: "secret2", localEphemeralKey: "k1", peerEphemeralKey: "k2")
        #expect(hmac1 != hmac2)
    }

    @Test("challengeHMAC with different nonces produces different HMACs")
    func challengeHMACDifferentNonces() {
        let secret = "room-secret"
        let hmac1 = SessionCrypto.challengeHMAC(nonce: Data("nonce1".utf8), roomSecret: secret)
        let hmac2 = SessionCrypto.challengeHMAC(nonce: Data("nonce2".utf8), roomSecret: secret)
        #expect(hmac1 != hmac2)
    }

    @Test("challengeHMAC is deterministic")
    func challengeHMACDeterministic() {
        let nonce = Data("nonce".utf8)
        let h1 = SessionCrypto.challengeHMAC(nonce: nonce, roomSecret: "s", localEphemeralKey: "a", peerEphemeralKey: "b")
        let h2 = SessionCrypto.challengeHMAC(nonce: nonce, roomSecret: "s", localEphemeralKey: "a", peerEphemeralKey: "b")
        #expect(h1 == h2)
    }

    // MARK: - SHA256 additional

    @Test("SHA256 produces 64-character hex string")
    func sha256Length() {
        let hash = SessionCrypto.sha256Hex("anything")
        #expect(hash.count == 64)
        let hexChars = CharacterSet(charactersIn: "0123456789abcdef")
        #expect(hash.unicodeScalars.allSatisfy { hexChars.contains($0) })
    }

    @Test("SHA256 different inputs produce different hashes")
    func sha256DifferentInputs() {
        let h1 = SessionCrypto.sha256Hex("hello")
        let h2 = SessionCrypto.sha256Hex("world")
        #expect(h1 != h2)
    }

    // MARK: - HMAC additional

    @Test("HMAC with different keys produces different output")
    func hmacDifferentKeys() {
        let data = Data("same data".utf8)
        let h1 = SessionCrypto.hmacSHA256(data: data, key: Data("key1".utf8))
        let h2 = SessionCrypto.hmacSHA256(data: data, key: Data("key2".utf8))
        #expect(h1 != h2)
    }

    @Test("HMAC with different data produces different output")
    func hmacDifferentData() {
        let key = Data("same key".utf8)
        let h1 = SessionCrypto.hmacSHA256(data: Data("data1".utf8), key: key)
        let h2 = SessionCrypto.hmacSHA256(data: Data("data2".utf8), key: key)
        #expect(h1 != h2)
    }

    // MARK: - Nonce derivation with invalid key

    @Test("Nonce derivation with invalid base64 throws invalidKey")
    func nonceDerivationInvalidKey() {
        let crypto = SessionCrypto()
        #expect(throws: SessionCrypto.CryptoError.invalidKey) {
            try crypto.deriveSessionKey(peerPublicKeyBase64: "!!!invalid!!!", localNonce: "a", remoteNonce: "b")
        }
    }
}
