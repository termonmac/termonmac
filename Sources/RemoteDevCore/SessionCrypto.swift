import Foundation
import CryptoKit

public final class SessionCrypto {
    public let privateKey: Curve25519.KeyAgreement.PrivateKey
    public let publicKeyBase64: String
    private var sessionKey: SymmetricKey?

    public init() {
        self.privateKey = Curve25519.KeyAgreement.PrivateKey()
        self.publicKeyBase64 = privateKey.publicKey.rawRepresentation.base64EncodedString()
    }

    /// Load from existing private key data (for persistent identity keys).
    public init(privateKeyData: Data) throws {
        self.privateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKeyData)
        self.publicKeyBase64 = privateKey.publicKey.rawRepresentation.base64EncodedString()
    }

    /// Raw public key bytes (32 bytes).
    public var publicKeyData: Data {
        privateKey.publicKey.rawRepresentation
    }

    /// Legacy: derive session key without nonces (backward compat).
    public func deriveSessionKey(peerPublicKeyBase64: String) throws {
        guard let peerKeyData = Data(base64Encoded: peerPublicKeyBase64) else {
            throw CryptoError.invalidKey
        }
        let peerKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerKeyData)
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: peerKey)
        self.sessionKey = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data("remotedev-v1".utf8),
            sharedInfo: Data(),
            outputByteCount: 32
        )
    }

    /// Derive session key with nonces for unique per-connection keys.
    /// Nonces are sorted lexicographically so both sides compute the same salt.
    public func deriveSessionKey(peerPublicKeyBase64: String, localNonce: String, remoteNonce: String) throws {
        guard let peerKeyData = Data(base64Encoded: peerPublicKeyBase64) else {
            throw CryptoError.invalidKey
        }
        let peerKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerKeyData)
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: peerKey)
        let sortedNonces = [localNonce, remoteNonce].sorted()
        let salt = Data("remotedev-v1".utf8) + Data(sortedNonces.joined().utf8)
        self.sessionKey = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: Data(),
            outputByteCount: 32
        )
    }

    public func encrypt(_ data: Data) throws -> Data {
        guard let key = sessionKey else { throw CryptoError.noSessionKey }
        let nonce = AES.GCM.Nonce()
        let sealed = try AES.GCM.seal(data, using: key, nonce: nonce)
        return nonce.withUnsafeBytes { Data($0) } + sealed.ciphertext + sealed.tag
    }

    public func decrypt(_ data: Data) throws -> Data {
        guard let key = sessionKey else { throw CryptoError.noSessionKey }
        guard data.count > 28 else { throw CryptoError.invalidData }
        let nonce = try AES.GCM.Nonce(data: data[0..<12])
        let ciphertext = data[12..<(data.count - 16)]
        let tag = data[(data.count - 16)...]
        let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
        return try AES.GCM.open(box, using: key)
    }

    public static func sha256Hex(_ string: String) -> String {
        let digest = SHA256.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public static func hmacSHA256(data: Data, key: Data) -> Data {
        let hmac = HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key))
        return Data(hmac)
    }

    /// Compute challenge-response HMAC with channel binding.
    /// When both ephemeral keys are present, they are sorted and appended to the nonce
    /// to bind the HMAC to the specific ECDH ephemeral keys, preventing a relay MITM
    /// from substituting ephemeral keys while passing TOFU checks on identity keys.
    public static func challengeHMAC(nonce: Data, roomSecret: String,
                                     localEphemeralKey: String = "",
                                     peerEphemeralKey: String = "") -> Data {
        var payload = nonce
        if !localEphemeralKey.isEmpty && !peerEphemeralKey.isEmpty {
            let sorted = [localEphemeralKey, peerEphemeralKey].sorted()
            payload.append(Data(sorted.joined().utf8))
        }
        return hmacSHA256(data: payload, key: Data(roomSecret.utf8))
    }

    public static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }

    public static func randomAlphanumeric(_ count: Int) -> String {
        let chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
        return String((0..<count).map { _ in chars.randomElement()! })
    }

    /// Derive session key using an ephemeral key pair for forward secrecy.
    /// The persistent identity key is NOT used for ECDH — only the ephemeral keys.
    public func deriveSessionKeyEphemeral(
        ephemeralPrivateKey: Curve25519.KeyAgreement.PrivateKey,
        peerEphemeralKeyBase64: String,
        localNonce: String,
        remoteNonce: String
    ) throws {
        guard let peerKeyData = Data(base64Encoded: peerEphemeralKeyBase64) else {
            throw CryptoError.invalidKey
        }
        let peerKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerKeyData)
        let shared = try ephemeralPrivateKey.sharedSecretFromKeyAgreement(with: peerKey)
        let sortedNonces = [localNonce, remoteNonce].sorted()
        let salt = Data("remotedev-v2".utf8) + Data(sortedNonces.joined().utf8)
        self.sessionKey = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: Data(),
            outputByteCount: 32
        )
    }

    /// Clear the derived session key from memory.
    public func clearSessionKey() {
        sessionKey = nil
    }

    public enum CryptoError: Error {
        case invalidKey, noSessionKey, invalidData
    }
}
