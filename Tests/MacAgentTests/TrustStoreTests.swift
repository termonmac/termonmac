import Testing
import Foundation
@testable import MacAgentLib

@Suite struct TrustStoreTests {

    // MARK: - Helpers

    private func makeDir() -> String {
        let dir = NSTemporaryDirectory() + "ts-test-\(UUID().uuidString)"
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

    private func writeValidStore(dir: String, devices: [TrustedDevice]) {
        let file = TrustStoreFile(devices: devices)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try! encoder.encode(file)
        FileManager.default.createFile(
            atPath: dir + "/" + TrustStore.fileName,
            contents: data,
            attributes: [.posixPermissions: 0o600]
        )
    }

    private func sampleDevice(_ key: String, label: String, type: String = "iPhone") -> TrustedDevice {
        TrustedDevice(public_key: key, label: label, added_at: 1000, last_seen: 2000, device_type: type)
    }

    // MARK: - A1: missing file → empty list

    @Test("A1 load missing file yields empty list")
    func testLoadMissingFileYieldsEmptyList() {
        let dir = makeDir(); defer { cleanup(dir) }
        let store = TrustStore(configDir: dir)
        let outcome = store.load()
        #expect(outcome == .missing)
        #expect(store.devices.isEmpty)
    }

    // MARK: - A2: valid JSON → devices populated

    @Test("A2 load valid json populates devices")
    func testLoadValidJsonPopulatesDevices() {
        let dir = makeDir(); defer { cleanup(dir) }
        writeValidStore(dir: dir, devices: [
            sampleDevice("K1", label: "iPhone-1"),
            sampleDevice("K2", label: "iPad-1", type: "iPad"),
        ])
        let store = TrustStore(configDir: dir)
        let outcome = store.load()
        #expect(outcome == .loaded(deviceCount: 2))
        #expect(store.devices.count == 2)
        #expect(store.devices[0].label == "iPhone-1")
        #expect(store.devices[1].device_type == "iPad")
    }

    // MARK: - A3: parse failure → backup rename

    @Test("A3 parse failure renames backup")
    func testParseFailureRenamesBackup() {
        let dir = makeDir(); defer { cleanup(dir) }
        writeRaw("this is not json", to: dir + "/" + TrustStore.fileName)

        let store = TrustStore(configDir: dir, now: { 12345 })
        let outcome = store.load()

        if case .reset(_, let backupPath, _) = outcome {
            #expect(backupPath.hasSuffix(".corrupted.12345"))
            #expect(FileManager.default.fileExists(atPath: backupPath))
        } else {
            Issue.record("expected .reset, got \(outcome)")
        }
        #expect(store.devices.isEmpty)
    }

    // MARK: - A4: sentinel file created

    @Test("A4 parse failure creates sentinel")
    func testParseFailureCreatesSentinel() {
        let dir = makeDir(); defer { cleanup(dir) }
        let bad = "{ incomplete"
        writeRaw(bad, to: dir + "/" + TrustStore.fileName)

        let store = TrustStore(configDir: dir, now: { 12345 })
        _ = store.load()

        let sentinels = TrustStore.listSentinels(in: dir)
        #expect(sentinels.count == 1)
        #expect(sentinels[0].hasSuffix("\(TrustStore.sentinelPrefix)12345"))

        let sentinelData = try! Data(contentsOf: URL(fileURLWithPath: sentinels[0]))
        let json = try! JSONSerialization.jsonObject(with: sentinelData) as! [String: Any]
        #expect(json["timestamp"] as? Int == 12345)
        #expect((json["original_size"] as? Int) == bad.count)
        #expect((json["reason"] as? String)?.isEmpty == false)
    }

    // MARK: - A5: logged via outcome

    @Test("A5 reset outcome carries reason and paths")
    func testResetOutcomeCarriesReason() {
        let dir = makeDir(); defer { cleanup(dir) }
        writeRaw("not-json", to: dir + "/" + TrustStore.fileName)
        let store = TrustStore(configDir: dir, now: { 12345 })
        let outcome = store.load()
        guard case .reset(let reason, let backup, let sentinel) = outcome else {
            Issue.record("wrong outcome"); return
        }
        #expect(!reason.isEmpty)
        #expect(backup.contains("corrupted"))
        #expect(sentinel.contains(TrustStore.sentinelPrefix))
    }

    // MARK: - A6: future version rejected

    @Test("A6 rejects future schema version")
    func testRejectsFutureSchemaVersion() {
        let dir = makeDir(); defer { cleanup(dir) }
        writeRaw(#"{"v":99,"devices":[]}"#, to: dir + "/" + TrustStore.fileName)
        let store = TrustStore(configDir: dir)
        let outcome = store.load()
        #expect(outcome == .unsupportedVersion(99))
        #expect(store.devices.isEmpty)
    }

    // MARK: - A7: multiple sentinels

    @Test("A7 multiple sentinels accumulate")
    func testMultipleSentinelsAccumulate() {
        let dir = makeDir(); defer { cleanup(dir) }
        // First corruption
        writeRaw("bad1", to: dir + "/" + TrustStore.fileName)
        _ = TrustStore(configDir: dir, now: { 100 }).load()
        // Second — write another bad file (first one was moved to backup)
        writeRaw("bad2", to: dir + "/" + TrustStore.fileName)
        _ = TrustStore(configDir: dir, now: { 200 }).load()
        // Third
        writeRaw("bad3", to: dir + "/" + TrustStore.fileName)
        _ = TrustStore(configDir: dir, now: { 300 }).load()

        let sentinels = TrustStore.listSentinels(in: dir)
        #expect(sentinels.count == 3)
    }

    // MARK: - A8: atomic write via tempfile rename

    @Test("A8 atomic write via tempfile + rename sets 0o600")
    func testAtomicWriteViaTempfileRename() throws {
        let dir = makeDir(); defer { cleanup(dir) }
        let store = TrustStore(configDir: dir, now: { 1000 })
        _ = try store.add(publicKey: "K1", deviceType: "iPhone")

        let finalPath = dir + "/" + TrustStore.fileName
        #expect(FileManager.default.fileExists(atPath: finalPath))
        let attrs = try FileManager.default.attributesOfItem(atPath: finalPath)
        let perms = attrs[.posixPermissions] as? NSNumber
        #expect(perms?.int16Value == 0o600)

        // No leftover tempfile
        let entries = try FileManager.default.contentsOfDirectory(atPath: dir)
        #expect(entries.filter { $0.contains(".tmp.") }.isEmpty)
    }

    // MARK: - A9, A10: write failure rollback (read-only dir)

    @Test("A9 write failure rolls back memory state")
    func testWriteFailureRollsBackMemory() throws {
        let dir = makeDir(); defer { cleanup(dir) }
        let store = TrustStore(configDir: dir)
        _ = try store.add(publicKey: "K1", deviceType: "iPhone")
        #expect(store.devices.count == 1)

        // Make directory read-only so write fails
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: dir
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: dir
            )
        }

        do {
            _ = try store.add(publicKey: "K2", deviceType: "iPad")
            Issue.record("expected write failure")
        } catch {
            // Memory should be rolled back to count == 1
            #expect(store.devices.count == 1)
            #expect(store.devices[0].public_key == "K1")
        }
    }

    @Test("A10 rename failure keeps old file intact")
    func testRenameFailureKeepsOldFile() throws {
        let dir = makeDir(); defer { cleanup(dir) }
        let store = TrustStore(configDir: dir)
        _ = try store.add(publicKey: "K1", deviceType: "iPhone")
        let originalData = try Data(contentsOf: URL(fileURLWithPath: dir + "/" + TrustStore.fileName))

        // Make directory read-only — tempfile creation will fail (not rename
        // specifically, but from the caller's perspective the invariant is
        // the same: old file untouched, memory rolled back).
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: dir
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: dir
            )
        }

        do {
            _ = try store.add(publicKey: "K2", deviceType: "iPad")
        } catch {}

        // Restore permissions so we can read
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: dir
        )
        let nowData = try Data(contentsOf: URL(fileURLWithPath: dir + "/" + TrustStore.fileName))
        #expect(nowData == originalData)
    }

    // MARK: - A11: JSON schema snapshot

    @Test("A11 JSON schema snapshot — sortedKeys stable encoding")
    func testJsonSchemaSnapshot() throws {
        let device = TrustedDevice(
            public_key: "K1", label: "iPhone-1",
            added_at: 100, last_seen: 200, device_type: "iPhone")
        let file = TrustStoreFile(devices: [device])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(file)
        let s = try #require(String(data: data, encoding: .utf8))
        #expect(s == #"{"devices":[{"added_at":100,"device_type":"iPhone","label":"iPhone-1","last_seen":200,"public_key":"K1"}],"v":1}"#)
    }

    // MARK: - A12-A14: auto label generation

    @Test("A12 auto label iPhone collision increments")
    func testAutoLabelIPhoneCollision() throws {
        let dir = makeDir(); defer { cleanup(dir) }
        let store = TrustStore(configDir: dir)
        _ = try store.add(publicKey: "K1", deviceType: "iPhone")
        let d2 = try store.add(publicKey: "K2", deviceType: "iPhone")
        #expect(d2.label == "iPhone-2")
    }

    @Test("A13 auto label iPad collision increments")
    func testAutoLabelIPadCollision() throws {
        let dir = makeDir(); defer { cleanup(dir) }
        let store = TrustStore(configDir: dir)
        _ = try store.add(publicKey: "K1", deviceType: "iPad")
        let d2 = try store.add(publicKey: "K2", deviceType: "iPad")
        #expect(d2.label == "iPad-2")
    }

    @Test("A14 auto label unknown type uses device- prefix")
    func testAutoLabelUnknownType() throws {
        let dir = makeDir(); defer { cleanup(dir) }
        let store = TrustStore(configDir: dir)
        let d = try store.add(publicKey: "K1", deviceType: nil)
        #expect(d.label == "device-1")
        #expect(d.device_type == "unknown")
    }

    // MARK: - A15: 32-device limit

    @Test("A15 add rejected at 32 device limit")
    func testAddRejectedAt32Devices() throws {
        let dir = makeDir(); defer { cleanup(dir) }
        let store = TrustStore(configDir: dir)
        for i in 0..<32 {
            _ = try store.add(publicKey: "K\(i)", deviceType: "iPhone")
        }
        #expect(store.devices.count == 32)
        #expect(throws: TrustStoreError.self) {
            try store.add(publicKey: "K32", deviceType: "iPhone")
        }
        #expect(store.devices.count == 32)
    }

    // MARK: - A16: remove nonexistent

    @Test("A16 remove nonexistent label throws")
    func testRemoveNonexistentLabel() throws {
        let dir = makeDir(); defer { cleanup(dir) }
        let store = TrustStore(configDir: dir)
        #expect(throws: TrustStoreError.self) {
            try store.remove(label: "ghost")
        }
    }

    // MARK: - A17: rename collision

    @Test("A17 rename collision rejected")
    func testRenameCollisionRejected() throws {
        let dir = makeDir(); defer { cleanup(dir) }
        let store = TrustStore(configDir: dir)
        _ = try store.add(publicKey: "K1", deviceType: "iPhone")  // iPhone-1
        _ = try store.add(publicKey: "K2", deviceType: "iPad")    // iPad-1
        #expect(throws: TrustStoreError.self) {
            try store.rename(from: "iPhone-1", to: "iPad-1")
        }
    }

    // MARK: - A18: control chars rejected

    @Test("A18 rename with control chars rejected")
    func testRenameControlCharsRejected() throws {
        let dir = makeDir(); defer { cleanup(dir) }
        let store = TrustStore(configDir: dir)
        _ = try store.add(publicKey: "K1", deviceType: "iPhone")
        #expect(throws: TrustStoreError.self) {
            try store.rename(from: "iPhone-1", to: "hello\u{0}world")
        }
        #expect(throws: TrustStoreError.self) {
            try store.rename(from: "iPhone-1", to: "line1\nline2")
        }
    }

    // MARK: - A19: length bounds

    @Test("A19 rename length bounds enforced")
    func testRenameLengthBounds() throws {
        let dir = makeDir(); defer { cleanup(dir) }
        let store = TrustStore(configDir: dir)
        _ = try store.add(publicKey: "K1", deviceType: "iPhone")
        #expect(throws: TrustStoreError.self) {
            try store.rename(from: "iPhone-1", to: "")
        }
        let over = String(repeating: "a", count: 65)
        #expect(throws: TrustStoreError.self) {
            try store.rename(from: "iPhone-1", to: over)
        }
    }

    // MARK: - A20: added_at / last_seen

    @Test("A20 add writes added_at and last_seen")
    func testAddWritesAddedAtAndLastSeen() throws {
        let dir = makeDir(); defer { cleanup(dir) }
        let store = TrustStore(configDir: dir, now: { 5000 })
        let d = try store.add(publicKey: "K1", deviceType: "iPhone")
        #expect(d.added_at == 5000)
        #expect(d.last_seen == 5000)
    }

    // MARK: - A21: reconnect updates only last_seen

    @Test("A21 reconnect updates only last_seen")
    func testReconnectUpdatesOnlyLastSeen() throws {
        let dir = makeDir(); defer { cleanup(dir) }

        let clock = Clock()
        clock.value = 1000
        let store = TrustStore(configDir: dir, now: { clock.value })
        let added = try store.add(publicKey: "K1", deviceType: "iPhone")

        clock.value = 9999
        try store.touch(publicKey: "K1")

        let found = store.find(publicKey: "K1")
        #expect(found?.added_at == added.added_at)
        #expect(found?.label == added.label)
        #expect(found?.public_key == added.public_key)
        #expect(found?.last_seen == 9999)
    }

    // MARK: - A22: unknown device_type normalized

    @Test("A22 unknown device type normalized to unknown, not rejected")
    func testUnknownDeviceTypeStoredAsUnknown() throws {
        let dir = makeDir(); defer { cleanup(dir) }
        let store = TrustStore(configDir: dir)
        let d = try store.add(publicKey: "K1", deviceType: "watchOS")
        #expect(d.device_type == "unknown")
        #expect(d.label == "device-1")
    }

    // MARK: - Sentinel helpers

    @Test("clearSentinels removes all and returns count")
    func testClearSentinels() throws {
        let dir = makeDir(); defer { cleanup(dir) }
        writeRaw("{}", to: dir + "/\(TrustStore.sentinelPrefix)1")
        writeRaw("{}", to: dir + "/\(TrustStore.sentinelPrefix)2")
        writeRaw("other file", to: dir + "/other")

        #expect(TrustStore.listSentinels(in: dir).count == 2)
        #expect(TrustStore.clearSentinels(in: dir) == 2)
        #expect(TrustStore.listSentinels(in: dir).count == 0)
        // Non-sentinel file preserved
        #expect(FileManager.default.fileExists(atPath: dir + "/other"))
    }
}

/// Test-scope mutable clock without needing `@unchecked Sendable`.
private final class Clock {
    var value: Int = 0
}
