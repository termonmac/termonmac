import Testing
import Foundation
@testable import MacAgentLib

@Suite struct DevicesServiceTests {

    private func makeDir() -> String {
        let dir = NSTemporaryDirectory() + "dev-svc-\(UUID().uuidString)"
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private func cleanup(_ dir: String) {
        try? FileManager.default.removeItem(atPath: dir)
    }

    private func seed(_ dir: String, count: Int) throws -> TrustStore {
        let store = TrustStore(configDir: dir, now: { 1_700_000_000 })
        for i in 0..<count {
            _ = try store.add(publicKey: "K\(i)", deviceType: i % 2 == 0 ? "iPhone" : "iPad")
        }
        return store
    }

    // MARK: - D1: list format

    @Test("D1 list renders header + one row per device")
    func testListFormat() throws {
        let dir = makeDir(); defer { cleanup(dir) }
        _ = try seed(dir, count: 2)
        let service = DevicesService(configDir: dir)
        let result = service.list()
        let text = DevicesRenderer.renderList(result)
        #expect(text.contains("LABEL"))
        #expect(text.contains("TYPE"))
        #expect(text.contains("ADDED"))
        #expect(text.contains("LAST SEEN"))
        #expect(text.contains("PUBLIC KEY"))
        #expect(text.contains("iPhone-1"))
        #expect(text.contains("iPad-1"))
    }

    // MARK: - D2: empty hint

    @Test("D2 list with empty store shows hint")
    func testListEmptyShowsHint() {
        let dir = makeDir(); defer { cleanup(dir) }
        let service = DevicesService(configDir: dir)
        let text = DevicesRenderer.renderList(service.list())
        #expect(text.contains("No trusted devices"))
        #expect(text.contains("termonmac pair"))
    }

    // MARK: - D3: --json

    @Test("D3 list --json outputs valid structured JSON")
    func testListJsonFlag() throws {
        let dir = makeDir(); defer { cleanup(dir) }
        _ = try seed(dir, count: 2)
        let service = DevicesService(configDir: dir)
        let json = try DevicesRenderer.renderListJson(service.list())
        let obj = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        let devices = obj["devices"] as! [[String: Any]]
        #expect(devices.count == 2)
        #expect(devices[0]["label"] as? String == "iPhone-1")
        #expect(devices[0]["public_key"] as? String == "K0")
        #expect(obj["pending_reset_count"] as? Int == 0)
    }

    // MARK: - D4: remove persists + returns mutation

    @Test("D4 remove deletes from store and returns mutation")
    func testRemovePersistsAndReturnsMutation() throws {
        let dir = makeDir(); defer { cleanup(dir) }
        _ = try seed(dir, count: 2)
        let service = DevicesService(configDir: dir)
        let m = try service.remove(label: "iPad-1")
        #expect(m == .removed(label: "iPad-1"))

        // Re-open and confirm persisted
        let reopened = DevicesService(configDir: dir)
        let rows = reopened.list().rows
        #expect(rows.count == 1)
        #expect(rows[0].label == "iPhone-1")
    }

    // MARK: - D5: remove nonexistent

    @Test("D5 remove nonexistent label throws labelNotFound")
    func testRemoveNonexistentLabel() throws {
        let dir = makeDir(); defer { cleanup(dir) }
        _ = try seed(dir, count: 1)
        let service = DevicesService(configDir: dir)
        #expect(throws: TrustStoreError.self) {
            try service.remove(label: "ghost")
        }
    }

    // MARK: - D6: rename returns mutation but does not touch daemon

    @Test("D6 rename is persisted and does not require SIGHUP")
    func testRenameDoesNotRequireSighup() throws {
        let dir = makeDir(); defer { cleanup(dir) }
        _ = try seed(dir, count: 2)
        let service = DevicesService(configDir: dir)
        _ = try service.rename(from: "iPad-1", to: "Sophie's iPad")
        let rows = DevicesService(configDir: dir).list().rows
        #expect(rows.contains { $0.label == "Sophie's iPad" })
        #expect(!rows.contains { $0.label == "iPad-1" })
    }

    // MARK: - D7: acknowledge-reset clears sentinels, keeps corrupted

    @Test("D7 acknowledge-reset clears sentinels but keeps corrupted backup")
    func testAcknowledgeResetClearsSentinelsKeepsCorrupted() throws {
        let dir = makeDir(); defer { cleanup(dir) }
        // Corrupt the store file so load() creates a sentinel + backup
        FileManager.default.createFile(
            atPath: dir + "/" + TrustStore.fileName,
            contents: Data("bad".utf8),
            attributes: [.posixPermissions: 0o600])
        _ = TrustStore(configDir: dir, now: { 999 }).load()

        let service = DevicesService(configDir: dir)
        #expect(service.list().pendingResetCount == 1)

        let cleared = service.acknowledgeReset()
        #expect(cleared == 1)

        let second = DevicesService(configDir: dir)
        #expect(second.list().pendingResetCount == 0)

        // Corrupted backup preserved
        let entries = try FileManager.default.contentsOfDirectory(atPath: dir)
        #expect(entries.contains { $0.contains(".corrupted.") })
    }

    // MARK: - D8: acknowledge-reset is idempotent

    @Test("D8 acknowledge-reset with no sentinels returns 0")
    func testAcknowledgeResetNoSentinelsIdempotent() throws {
        let dir = makeDir(); defer { cleanup(dir) }
        _ = try seed(dir, count: 1)
        let service = DevicesService(configDir: dir)
        #expect(service.acknowledgeReset() == 0)
    }

    // MARK: - pair gate helper

    @Test("pair is blocked only when sentinel exists (D-I7)")
    func testPairBlockedBySentinel() throws {
        let dir = makeDir(); defer { cleanup(dir) }
        // No sentinel → not blocked
        #expect(DevicesService(configDir: dir).pairIsBlockedBySentinel() == false)

        // Corrupt → sentinel → blocked
        FileManager.default.createFile(
            atPath: dir + "/" + TrustStore.fileName,
            contents: Data("bad".utf8))
        _ = TrustStore(configDir: dir, now: { 123 }).load()
        #expect(DevicesService(configDir: dir).pairIsBlockedBySentinel() == true)

        // Acknowledge → unblocked
        _ = DevicesService(configDir: dir).acknowledgeReset()
        #expect(DevicesService(configDir: dir).pairIsBlockedBySentinel() == false)
    }

    // MARK: - banner with multiple events

    @Test("banner for N reset events pluralizes correctly")
    func testBannerPluralization() {
        #expect(DevicesRenderer.bannerForReset(count: 1).contains("1 reset event"))
        let three = DevicesRenderer.bannerForReset(count: 3)
        #expect(three.contains("3 reset events"))
    }
}

// MARK: - DaemonPidFile tests (D9, D10)

@Suite struct DaemonPidFileTests {

    private func makeDir() -> String {
        let dir = NSTemporaryDirectory() + "dpid-\(UUID().uuidString)"
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private func cleanup(_ dir: String) { try? FileManager.default.removeItem(atPath: dir) }

    @Test("D9 SIGHUP rejected when pid start timestamp mismatches")
    func testSighupRejectsPidStartTsMismatch() {
        let dir = makeDir(); defer { cleanup(dir) }
        FileManager.default.createFile(
            atPath: DaemonPidFile.path(in: dir),
            contents: Data("4242\n100\n".utf8),
            attributes: [.posixPermissions: 0o600])

        var killInvocations = 0
        let result = DaemonPidFile.signalDaemon(
            configDir: dir,
            startTimestampProvider: { _ in 9999 },
            isAlive: { _ in true },
            kill: { _, _ in killInvocations += 1; return 0 }
        )
        #expect(killInvocations == 0)
        if case .staleStartTimestamp(let expected, let observed, _) = result {
            #expect(expected == 100)
            #expect(observed == 9999)
        } else {
            Issue.record("expected staleStartTimestamp, got \(result)")
        }
    }

    @Test("D10 SIGHUP skipped when pid is not alive")
    func testSighupSkippedWhenPidNotAlive() {
        let dir = makeDir(); defer { cleanup(dir) }
        FileManager.default.createFile(
            atPath: DaemonPidFile.path(in: dir),
            contents: Data("4242\n100\n".utf8),
            attributes: [.posixPermissions: 0o600])

        var killInvocations = 0
        let result = DaemonPidFile.signalDaemon(
            configDir: dir,
            startTimestampProvider: { _ in 100 },
            isAlive: { _ in false },
            kill: { _, _ in killInvocations += 1; return 0 }
        )
        #expect(killInvocations == 0)
        if case .pidNotAlive = result {} else {
            Issue.record("expected pidNotAlive, got \(result)")
        }
    }

    @Test("SIGHUP sent when pid alive + start timestamp within slack")
    func testSighupSentOnMatch() {
        let dir = makeDir(); defer { cleanup(dir) }
        FileManager.default.createFile(
            atPath: DaemonPidFile.path(in: dir),
            contents: Data("4242\n100\n".utf8),
            attributes: [.posixPermissions: 0o600])

        var killInvocations = 0
        var killedPid: pid_t = 0
        var killedSig: Int32 = 0
        let result = DaemonPidFile.signalDaemon(
            configDir: dir,
            startTimestampProvider: { _ in 101 },
            isAlive: { _ in true },
            kill: { pid, sig in
                killInvocations += 1
                killedPid = pid
                killedSig = sig
                return 0
            }
        )
        #expect(killInvocations == 1)
        #expect(killedPid == 4242)
        #expect(killedSig == SIGHUP)
        if case .ok(let info) = result {
            #expect(info.pid == 4242)
            #expect(info.startTimestamp == 100)
        } else {
            Issue.record("expected ok, got \(result)")
        }
    }

    @Test("missing pid file returns noPidFile")
    func testMissingPidFile() {
        let dir = makeDir(); defer { cleanup(dir) }
        let result = DaemonPidFile.lookup(configDir: dir)
        #expect(result == .noPidFile)
    }

    @Test("malformed pid file returns malformed")
    func testMalformedPidFile() {
        let dir = makeDir(); defer { cleanup(dir) }
        FileManager.default.createFile(
            atPath: DaemonPidFile.path(in: dir),
            contents: Data("notanumber\nalso not a number\n".utf8))
        let result = DaemonPidFile.lookup(configDir: dir)
        if case .malformed = result {} else {
            Issue.record("expected malformed, got \(result)")
        }
    }

    @Test("writeSelf + lookup round-trip on real pid")
    func testWriteSelfRoundTrip() throws {
        let dir = makeDir(); defer { cleanup(dir) }
        try DaemonPidFile.writeSelf(configDir: dir)
        let result = DaemonPidFile.lookup(configDir: dir)
        guard case .ok(let info) = result else {
            Issue.record("expected ok, got \(result)"); return
        }
        #expect(info.pid == getpid())
    }
}
