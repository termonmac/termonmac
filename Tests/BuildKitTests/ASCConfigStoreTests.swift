import Testing
import Foundation
@testable import BuildKit

@Suite struct ASCConfigStoreTests {

    private func makeTempDir() -> String {
        let dir = NSTemporaryDirectory() + "asc-store-test-\(UUID().uuidString)"
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private func cleanup(_ dir: String) {
        try? FileManager.default.removeItem(atPath: dir)
    }

    // MARK: - loadState()

    @Test("loadState returns .unset when no file exists")
    func testLoadStateNoFile() {
        let dir = makeTempDir()
        defer { cleanup(dir) }

        let store = ASCConfigStore(configDir: dir)
        let state = store.loadState()

        guard case .unset = state else {
            Issue.record("Expected .unset, got \(state)")
            return
        }
    }

    @Test("loadState returns .disabled when file contains disabled marker")
    func testLoadStateDisabled() {
        let dir = makeTempDir()
        defer { cleanup(dir) }

        let json = Data(#"{"disabled":true}"#.utf8)
        FileManager.default.createFile(atPath: dir + "/" + ASCConfigStore.filename, contents: json)

        let store = ASCConfigStore(configDir: dir)
        let state = store.loadState()

        guard case .disabled = state else {
            Issue.record("Expected .disabled, got \(state)")
            return
        }
    }

    @Test("loadState returns .configured with valid config JSON")
    func testLoadStateConfigured() {
        let dir = makeTempDir()
        defer { cleanup(dir) }

        let json = Data(#"{"key_id":"ABC123","issuer_id":"uuid-here","key_path":"/tmp/key.p8"}"#.utf8)
        FileManager.default.createFile(atPath: dir + "/" + ASCConfigStore.filename, contents: json)

        let store = ASCConfigStore(configDir: dir)
        let state = store.loadState()

        guard case .configured(let config) = state else {
            Issue.record("Expected .configured, got \(state)")
            return
        }
        #expect(config.keyId == "ABC123")
        #expect(config.issuerId == "uuid-here")
        #expect(config.keyPath == "/tmp/key.p8")
    }

    @Test("loadState returns .unset for corrupt data")
    func testLoadStateCorrupt() {
        let dir = makeTempDir()
        defer { cleanup(dir) }

        let garbage = Data("not json at all!!!".utf8)
        FileManager.default.createFile(atPath: dir + "/" + ASCConfigStore.filename, contents: garbage)

        let store = ASCConfigStore(configDir: dir)
        let state = store.loadState()

        guard case .unset = state else {
            Issue.record("Expected .unset for corrupt data, got \(state)")
            return
        }
    }

    // MARK: - markDisabled()

    @Test("markDisabled writes disabled marker that loadState reads back as .disabled")
    func testMarkDisabled() {
        let dir = makeTempDir()
        defer { cleanup(dir) }

        let store = ASCConfigStore(configDir: dir)
        store.markDisabled()

        let state = store.loadState()
        guard case .disabled = state else {
            Issue.record("Expected .disabled after markDisabled(), got \(state)")
            return
        }

        // Verify raw file content
        let data = try! Data(contentsOf: URL(fileURLWithPath: dir + "/" + ASCConfigStore.filename))
        let raw = try! JSONDecoder().decode([String: Bool].self, from: data)
        #expect(raw["disabled"] == true)
    }

    // MARK: - save() / markDisabled() ordering

    @Test("save() after markDisabled() overwrites disabled with configured")
    func testSaveOverwritesDisabled() {
        let dir = makeTempDir()
        defer { cleanup(dir) }

        let store = ASCConfigStore(configDir: dir)
        store.markDisabled()
        store.save(ASCConfigStore.Config(keyId: "K1", issuerId: "I1"))

        let state = store.loadState()
        guard case .configured(let config) = state else {
            Issue.record("Expected .configured after save(), got \(state)")
            return
        }
        #expect(config.keyId == "K1")
        #expect(config.issuerId == "I1")
    }

    @Test("markDisabled() after save() overwrites configured with disabled")
    func testMarkDisabledOverwritesSave() {
        let dir = makeTempDir()
        defer { cleanup(dir) }

        let store = ASCConfigStore(configDir: dir)
        store.save(ASCConfigStore.Config(keyId: "K1", issuerId: "I1"))
        store.markDisabled()

        let state = store.loadState()
        guard case .disabled = state else {
            Issue.record("Expected .disabled after markDisabled(), got \(state)")
            return
        }
    }
}
