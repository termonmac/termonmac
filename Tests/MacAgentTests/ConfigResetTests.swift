import Testing
import Foundation
@testable import MacAgentLib
import BuildKit

@Suite struct ConfigResetTests {

    private func makeTempConfig(files: [String] = ["identity.key", "room.json", "api_key"]) -> String {
        let dir = NSTemporaryDirectory() + "config-reset-test-\(UUID().uuidString)"
        let fm = FileManager.default
        try! fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for name in files {
            fm.createFile(atPath: dir + "/" + name, contents: Data(name.utf8))
        }
        return dir
    }

    private func cleanup(_ dir: String) {
        try? FileManager.default.removeItem(atPath: dir)
    }

    @Test("deleteAll removes all files")
    func testDeleteAll() throws {
        let dir = makeTempConfig()
        defer { cleanup(dir) }

        let reset = ConfigReset(configDir: dir, preserve: [])
        let count = try reset.deleteAll()

        #expect(count == 3)
        let fm = FileManager.default
        #expect(!fm.fileExists(atPath: dir + "/identity.key"))
        #expect(!fm.fileExists(atPath: dir + "/room.json"))
        #expect(!fm.fileExists(atPath: dir + "/api_key"))
        // config dir itself should still exist
        #expect(fm.fileExists(atPath: dir))
    }

    @Test("deleteAll with empty config dir returns 0")
    func testDeleteAllEmptyDir() throws {
        let dir = makeTempConfig(files: [])
        defer { cleanup(dir) }

        let reset = ConfigReset(configDir: dir, preserve: [])
        let count = try reset.deleteAll()

        #expect(count == 0)
    }

    @Test("deleteAll skips subdirectories")
    func testDeleteAllSkipsSubdirectories() throws {
        let dir = makeTempConfig(files: ["api_key"])
        defer { cleanup(dir) }

        try FileManager.default.createDirectory(
            atPath: dir + "/some_subdir", withIntermediateDirectories: false)

        let reset = ConfigReset(configDir: dir, preserve: [])
        let count = try reset.deleteAll()

        #expect(count == 1)
        #expect(FileManager.default.fileExists(atPath: dir + "/some_subdir"))
    }

    @Test("deleteAll throws when config dir missing")
    func testDeleteAllMissingDir() throws {
        let reset = ConfigReset(configDir: "/tmp/nonexistent-\(UUID().uuidString)", preserve: [])
        #expect(throws: ConfigResetError.self) {
            try reset.deleteAll()
        }
    }

    @Test("deleteAll can be called multiple times")
    func testDeleteAllIdempotent() throws {
        let dir = makeTempConfig()
        defer { cleanup(dir) }

        let reset = ConfigReset(configDir: dir, preserve: [])
        let count1 = try reset.deleteAll()
        let count2 = try reset.deleteAll()

        #expect(count1 == 3)
        #expect(count2 == 0)
    }

    @Test("deleteAll preserves specified files")
    func testDeleteAllPreserve() throws {
        let dir = makeTempConfig(files: ["identity.key", "room.json", "api_key", ASCConfigStore.filename])
        defer { cleanup(dir) }

        let reset = ConfigReset(configDir: dir, preserve: [ASCConfigStore.filename])
        let count = try reset.deleteAll()

        #expect(count == 3)
        let fm = FileManager.default
        #expect(!fm.fileExists(atPath: dir + "/identity.key"))
        #expect(!fm.fileExists(atPath: dir + "/room.json"))
        #expect(!fm.fileExists(atPath: dir + "/api_key"))
        #expect(fm.fileExists(atPath: dir + "/" + ASCConfigStore.filename))
    }
}
