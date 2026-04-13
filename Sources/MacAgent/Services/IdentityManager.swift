import Foundation
import Security
import RemoteDevCore

#if os(macOS)
struct IdentityManager {
    let configDir: String
    private let identityKeyPath: String
    private let identityPubPath: String
    private let fm = FileManager.default

    // Kept for reverse migration (Keychain → file)
    private static let keychainService = "com.remotedev.agent"
    private static let keychainAccount = "identity_private_key"

    init(configDir: String) {
        self.configDir = configDir
        self.identityKeyPath = configDir + "/identity.key"
        self.identityPubPath = configDir + "/identity.pub"
    }

    /// Check if an identity key exists without loading or printing.
    func identityExists() -> Bool {
        fm.fileExists(atPath: identityKeyPath) || loadFromKeychain() != nil
    }

    func loadIdentity(silent: Bool = false) -> SessionCrypto? {
        // 1. Try file
        if let crypto = loadFromFile() {
            if !silent { printIdentityInfo(crypto, generated: false) }
            return crypto
        }
        // 2. Try Keychain → migrate back to file
        if let keyData = loadFromKeychain(),
           let crypto = try? SessionCrypto(privateKeyData: keyData) {
            migrateToFile(crypto)
            if !silent { printIdentityInfo(crypto, generated: false) }
            return crypto
        }
        return nil
    }

    func loadOrGenerateIdentity(silent: Bool = false) -> SessionCrypto {
        // 1. Try file
        if let crypto = loadFromFile() {
            if !silent { printIdentityInfo(crypto, generated: false) }
            return crypto
        }
        // 2. Try Keychain → migrate back to file
        if let keyData = loadFromKeychain(),
           let crypto = try? SessionCrypto(privateKeyData: keyData) {
            migrateToFile(crypto)
            if !silent { printIdentityInfo(crypto, generated: false) }
            return crypto
        }
        // 3. Generate new key → store as file
        let crypto = SessionCrypto()
        saveKeyFile(crypto)
        savePubKeyFile(crypto)
        if !silent { printIdentityInfo(crypto, generated: true) }
        return crypto
    }

    /// Remove identity key file (for config reset).
    func deleteIdentity() {
        try? fm.removeItem(atPath: identityKeyPath)
        // Also clean up any leftover Keychain entry
        deleteFromKeychain()
    }

    // MARK: - File storage

    private func loadFromFile() -> SessionCrypto? {
        guard let hexKey = try? String(contentsOfFile: identityKeyPath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
              let keyData = Data(hexString: hexKey),
              let crypto = try? SessionCrypto(privateKeyData: keyData) else {
            return nil
        }
        return crypto
    }

    private func saveKeyFile(_ crypto: SessionCrypto) {
        if !fm.fileExists(atPath: configDir) {
            try? fm.createDirectory(atPath: configDir, withIntermediateDirectories: true)
        }
        let privHex = crypto.privateKey.rawRepresentation.map { String(format: "%02x", $0) }.joined()
        fm.createFile(atPath: identityKeyPath,
                      contents: Data(privHex.utf8),
                      attributes: [.posixPermissions: 0o600])
    }

    // MARK: - Keychain (reverse migration only)

    private func loadFromKeychain() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount,
            kSecReturnData as String: true,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return data
    }

    private func deleteFromKeychain() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount,
        ]
        SecItemDelete(query as CFDictionary)
    }

    private func migrateToFile(_ crypto: SessionCrypto) {
        saveKeyFile(crypto)
        savePubKeyFile(crypto)
        // Remove Keychain entry after successful file save
        if fm.fileExists(atPath: identityKeyPath) {
            deleteFromKeychain()
            log("[identity] migrated identity key from Keychain back to file")
        }
    }

    // MARK: - Public key file (non-sensitive, kept on disk)

    private func savePubKeyFile(_ crypto: SessionCrypto) {
        if !fm.fileExists(atPath: configDir) {
            try? fm.createDirectory(atPath: configDir, withIntermediateDirectories: true)
        }
        fm.createFile(atPath: identityPubPath,
                      contents: Data(crypto.publicKeyBase64.utf8),
                      attributes: [.posixPermissions: 0o644])
    }

    private func printIdentityInfo(_ crypto: SessionCrypto, generated: Bool) {
        let action = generated ? "Generated new" : "Loaded"
        let pubHex = crypto.publicKeyData.map { String(format: "%02x", $0) }.joined()
        let fingerprint = SessionCrypto.sha256Hex(crypto.publicKeyBase64)
        log("[identity] \(action) persistent identity key")
        log("[identity]   Type:        Curve25519")
        log("[identity]   Public key:  \(crypto.publicKeyBase64)")
        log("[identity]   Hex:         \(pubHex)")
        log("[identity]   Fingerprint: \(String(fingerprint.prefix(16)))")
        log("[identity]   Storage:     \(identityKeyPath) (0600)")
    }
}
#endif
