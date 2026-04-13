import Testing
import Foundation
@testable import MacAgentLib
import RemoteDevCore

// MARK: - Hex helpers (mirrors Data+Hex from MacAgent target)

private extension Data {
    init?(hexString: String) {
        let hex = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hex.count % 2 == 0 else { return nil }
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<nextIndex], radix: 16) else { return nil }
            data.append(byte)
            index = nextIndex
        }
        self = data
    }

    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Minimal IdentityManager replica for testing
// IdentityManager lives in the TermOnMac executable target, which cannot be
// @testable-imported. We duplicate the small struct here so that tests exercise
// the same file-system logic without changing production code layout.

private struct IdentityManager {
    let configDir: String
    private let identityKeyPath: String
    private let identityPubPath: String
    private let fm = FileManager.default

    init(configDir: String) {
        self.configDir = configDir
        self.identityKeyPath = configDir + "/identity.key"
        self.identityPubPath = configDir + "/identity.pub"
    }

    func loadIdentity() -> SessionCrypto? {
        if let hexKey = try? String(contentsOfFile: identityKeyPath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
           let keyData = Data(hexString: hexKey),
           let crypto = try? SessionCrypto(privateKeyData: keyData) {
            return crypto
        }
        return nil
    }

    func loadOrGenerateIdentity() -> SessionCrypto {
        if let hexKey = try? String(contentsOfFile: identityKeyPath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
           let keyData = Data(hexString: hexKey),
           let crypto = try? SessionCrypto(privateKeyData: keyData) {
            return crypto
        }

        let crypto = SessionCrypto()
        if !fm.fileExists(atPath: configDir) {
            try? fm.createDirectory(atPath: configDir, withIntermediateDirectories: true)
        }
        let privHex = crypto.privateKey.rawRepresentation.hexString
        fm.createFile(atPath: identityKeyPath,
                      contents: Data(privHex.utf8),
                      attributes: [.posixPermissions: 0o600])
        fm.createFile(atPath: identityPubPath,
                      contents: Data(crypto.publicKeyBase64.utf8),
                      attributes: [.posixPermissions: 0o644])
        return crypto
    }
}

// MARK: - Tests

@Suite("IdentityManager")
struct IdentityManagerTests {

    private func cleanup(_ dir: String) {
        try? FileManager.default.removeItem(atPath: dir)
    }

    // MARK: - loadIdentity

    @Test("loadIdentity returns nil when no key file exists")
    func loadIdentityMissingFile() {
        let dir = makeTempDir()
        defer { cleanup(dir) }

        let mgr = IdentityManager(configDir: dir)
        #expect(mgr.loadIdentity() == nil)
    }

    @Test("loadIdentity returns nil for invalid hex data")
    func loadIdentityInvalidHex() throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }

        try "not-hex-data".write(toFile: dir + "/identity.key",
                                 atomically: true, encoding: .utf8)

        let mgr = IdentityManager(configDir: dir)
        #expect(mgr.loadIdentity() == nil)
    }

    @Test("loadIdentity returns SessionCrypto when valid key file exists")
    func loadIdentityValidKey() throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }

        let original = SessionCrypto()
        let hex = original.privateKey.rawRepresentation.hexString
        try hex.write(toFile: dir + "/identity.key",
                      atomically: true, encoding: .utf8)

        let mgr = IdentityManager(configDir: dir)
        let loaded = mgr.loadIdentity()
        #expect(loaded != nil)
    }

    @Test("loaded key matches original key data")
    func loadIdentityMatchesOriginal() throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }

        let original = SessionCrypto()
        let hex = original.privateKey.rawRepresentation.hexString
        try hex.write(toFile: dir + "/identity.key",
                      atomically: true, encoding: .utf8)

        let mgr = IdentityManager(configDir: dir)
        let loaded = mgr.loadIdentity()!
        #expect(loaded.publicKeyBase64 == original.publicKeyBase64)
        #expect(loaded.privateKey.rawRepresentation == original.privateKey.rawRepresentation)
    }

    // MARK: - loadOrGenerateIdentity

    @Test("loadOrGenerateIdentity generates new key when no file exists")
    func generateNewKey() {
        let dir = makeTempDir()
        defer { cleanup(dir) }

        let mgr = IdentityManager(configDir: dir)
        let crypto = mgr.loadOrGenerateIdentity()

        #expect(!crypto.publicKeyBase64.isEmpty)
        #expect(crypto.privateKey.rawRepresentation.count == 32)
    }

    @Test("loadOrGenerateIdentity creates configDir if it doesn't exist")
    func createsConfigDir() {
        let dir = NSTemporaryDirectory() + "identity-test-\(UUID().uuidString)"
        defer { cleanup(dir) }

        #expect(!FileManager.default.fileExists(atPath: dir))

        let mgr = IdentityManager(configDir: dir)
        _ = mgr.loadOrGenerateIdentity()

        #expect(FileManager.default.fileExists(atPath: dir))
    }

    @Test("identity.key file has 0600 permissions")
    func keyFilePermissions() throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }

        let mgr = IdentityManager(configDir: dir)
        _ = mgr.loadOrGenerateIdentity()

        let attrs = try FileManager.default.attributesOfItem(atPath: dir + "/identity.key")
        let perms = attrs[.posixPermissions] as? Int
        #expect(perms == 0o600)
    }

    @Test("identity.pub file has 0644 permissions")
    func pubFilePermissions() throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }

        let mgr = IdentityManager(configDir: dir)
        _ = mgr.loadOrGenerateIdentity()

        let attrs = try FileManager.default.attributesOfItem(atPath: dir + "/identity.pub")
        let perms = attrs[.posixPermissions] as? Int
        #expect(perms == 0o644)
    }

    @Test("loadOrGenerateIdentity loads existing key instead of generating new")
    func loadsExistingKey() throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }

        let original = SessionCrypto()
        let hex = original.privateKey.rawRepresentation.hexString
        try hex.write(toFile: dir + "/identity.key",
                      atomically: true, encoding: .utf8)

        let mgr = IdentityManager(configDir: dir)
        let loaded = mgr.loadOrGenerateIdentity()

        #expect(loaded.publicKeyBase64 == original.publicKeyBase64)
    }

    @Test("generated key can be loaded again (round-trip)")
    func roundTrip() {
        let dir = makeTempDir()
        defer { cleanup(dir) }

        let mgr = IdentityManager(configDir: dir)
        let generated = mgr.loadOrGenerateIdentity()
        let loaded = mgr.loadIdentity()

        #expect(loaded != nil)
        #expect(loaded!.publicKeyBase64 == generated.publicKeyBase64)
        #expect(loaded!.privateKey.rawRepresentation == generated.privateKey.rawRepresentation)
    }

    @Test("public key in .pub file matches crypto's publicKeyBase64")
    func pubFileMatchesCrypto() throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }

        let mgr = IdentityManager(configDir: dir)
        let crypto = mgr.loadOrGenerateIdentity()

        let pubContent = try String(contentsOfFile: dir + "/identity.pub", encoding: .utf8)
        #expect(pubContent == crypto.publicKeyBase64)
    }
}
