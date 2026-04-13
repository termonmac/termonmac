import Testing
import Foundation
@testable import MacAgentLib

@Suite struct PairingTokenFileTests {

    // MARK: - Helpers

    private func makeTempConfig() -> String {
        let dir = NSTemporaryDirectory() + "pt-test-\(UUID().uuidString)"
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private func cleanup(_ dir: String) {
        try? FileManager.default.removeItem(atPath: dir)
    }

    private func writeRaw(_ contents: String, to path: String) {
        FileManager.default.createFile(
            atPath: path,
            contents: Data(contents.utf8),
            attributes: [.posixPermissions: 0o600]
        )
    }

    // MARK: - B1: atomic write

    @Test("B1 atomic write produces correct JSON with 0o600")
    func testAtomicWriteOfTokenJson() throws {
        let dir = makeTempConfig()
        defer { cleanup(dir) }

        try PairingTokenStore.write(configDir: dir, token: "abc123", expiresAt: 1712846400)

        let finalPath = PairingTokenStore.path(in: dir)
        let data = try #require(FileManager.default.contents(atPath: finalPath))
        let decoded = try JSONDecoder().decode(PairingTokenFile.self, from: data)
        #expect(decoded.v == 2)
        #expect(decoded.token == "abc123")
        #expect(decoded.expires_at == 1712846400)

        let attrs = try FileManager.default.attributesOfItem(atPath: finalPath)
        let perms = attrs[.posixPermissions] as? NSNumber
        #expect(perms?.int16Value == 0o600)

        // No leftover tempfiles
        let entries = try FileManager.default.contentsOfDirectory(atPath: dir)
        #expect(entries.filter { $0.hasPrefix(PairingTokenStore.fileName + ".tmp") }.isEmpty)
    }

    // MARK: - B2: missing field → corrupted (which deletes file)

    @Test("B2 missing field treated as corrupted and deleted")
    func testLoadMissingFieldTreatedAsNoToken() throws {
        let dir = makeTempConfig()
        defer { cleanup(dir) }
        writeRaw(#"{"v":2,"token":"abc"}"#, to: PairingTokenStore.path(in: dir))

        let result = PairingTokenStore.load(configDir: dir)
        guard case .corrupted = result else {
            Issue.record("expected corrupted, got \(result)")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: PairingTokenStore.path(in: dir)))
    }

    // MARK: - B3: parse failure

    @Test("B3 parse failure treated as corrupted and deleted")
    func testLoadParseFailureTreatedAsNoToken() throws {
        let dir = makeTempConfig()
        defer { cleanup(dir) }
        writeRaw("not json at all", to: PairingTokenStore.path(in: dir))

        let result = PairingTokenStore.load(configDir: dir)
        guard case .corrupted = result else {
            Issue.record("expected corrupted, got \(result)")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: PairingTokenStore.path(in: dir)))
    }

    // MARK: - B4: schema snapshot

    @Test("B4 JSON schema snapshot — stable sorted-keys encoding")
    func testJsonSchemaSnapshot() throws {
        let file = PairingTokenFile(token: "Z9", expires_at: 1712846400)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(file)
        let s = try #require(String(data: data, encoding: .utf8))
        #expect(s == #"{"expires_at":1712846400,"token":"Z9","v":2}"#)
    }

    // MARK: - B5: expired token → rejected + cleared

    @Test("B5 expired token rejected and cleared")
    func testLoadExpiredTokenRejectedAndCleared() throws {
        let dir = makeTempConfig()
        defer { cleanup(dir) }
        try PairingTokenStore.write(configDir: dir, token: "tok", expiresAt: 100)

        let result = PairingTokenStore.load(configDir: dir, now: { 200 })
        #expect(result == .expired)
        #expect(!FileManager.default.fileExists(atPath: PairingTokenStore.path(in: dir)))
    }

    // MARK: - B6: future schema version rejected

    @Test("B6 unsupported version rejected and cleared")
    func testRejectsFutureSchemaVersion() throws {
        let dir = makeTempConfig()
        defer { cleanup(dir) }
        writeRaw(#"{"v":99,"token":"abc","expires_at":99999999999}"#,
                 to: PairingTokenStore.path(in: dir))

        let result = PairingTokenStore.load(configDir: dir)
        #expect(result == .unsupportedVersion(99))
        #expect(!FileManager.default.fileExists(atPath: PairingTokenStore.path(in: dir)))
    }

    // MARK: - B7: consecutive writes overwrite

    @Test("B7 consecutive writes overwrite old token")
    func testPairRewriteSupersedesOldToken() throws {
        let dir = makeTempConfig()
        defer { cleanup(dir) }
        try PairingTokenStore.write(configDir: dir, token: "first", expiresAt: 1000)
        try PairingTokenStore.write(configDir: dir, token: "second", expiresAt: 2000)

        let result = PairingTokenStore.load(configDir: dir, now: { 500 })
        guard case .ok(let file) = result else {
            Issue.record("expected ok, got \(result)")
            return
        }
        #expect(file.token == "second")
        #expect(file.expires_at == 2000)
    }

    // MARK: - B8: load returns remaining expiry, caller can rebuild monotonic deadline

    @Test("B8 load returns full expires_at so caller can rebuild monotonic deadline")
    func testLoadProvidesExpiryForMonotonicRebuild() throws {
        let dir = makeTempConfig()
        defer { cleanup(dir) }
        try PairingTokenStore.write(configDir: dir, token: "tok", expiresAt: 500)

        let result = PairingTokenStore.load(configDir: dir, now: { 350 })
        guard case .ok(let file) = result else {
            Issue.record("expected ok, got \(result)")
            return
        }
        // Caller sees absolute expires_at, can compute remaining = expires_at - now
        // and rebuild a monotonic deadline from that.
        #expect(file.expires_at - 350 == 150)
    }

    // MARK: - Delete helper

    @Test("delete() removes file and is idempotent")
    func testDelete() throws {
        let dir = makeTempConfig()
        defer { cleanup(dir) }
        try PairingTokenStore.write(configDir: dir, token: "tok", expiresAt: 99999999999)
        #expect(FileManager.default.fileExists(atPath: PairingTokenStore.path(in: dir)))
        PairingTokenStore.delete(configDir: dir)
        #expect(!FileManager.default.fileExists(atPath: PairingTokenStore.path(in: dir)))
        // Second delete does not throw
        PairingTokenStore.delete(configDir: dir)
    }

    @Test("load from nonexistent dir returns missing")
    func testLoadMissing() {
        let dir = makeTempConfig()
        defer { cleanup(dir) }
        #expect(PairingTokenStore.load(configDir: dir) == .missing)
    }
}
