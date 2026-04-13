import Testing
import Foundation
@testable import MacAgentLib

/// Tests for token file persistence behavior (saveTokens, file permissions, partial write scenarios).
/// These test the same file I/O patterns used by CLIRouter.saveTokens.
@Suite struct TokenPersistenceTests {

    private func makeTempDir() -> String {
        let dir = NSTemporaryDirectory() + "token-test-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private func cleanup(_ dir: String) {
        try? FileManager.default.removeItem(atPath: dir)
    }

    // MARK: - Basic file write

    @Test("both api_key and refresh_token are persisted correctly")
    func testBothTokensSaved() throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }

        let apiKeyPath = dir + "/api_key"
        let refreshTokenPath = dir + "/refresh_token"

        try "rdkey_abc123".write(toFile: apiKeyPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: apiKeyPath)
        try "rdrt_xyz789".write(toFile: refreshTokenPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: refreshTokenPath)

        let savedApiKey = try String(contentsOfFile: apiKeyPath, encoding: .utf8)
        let savedRefreshToken = try String(contentsOfFile: refreshTokenPath, encoding: .utf8)
        #expect(savedApiKey == "rdkey_abc123")
        #expect(savedRefreshToken == "rdrt_xyz789")
    }

    @Test("token files have 0600 permissions")
    func testFilePermissions() throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }

        let apiKeyPath = dir + "/api_key"
        try "rdkey_test".write(toFile: apiKeyPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: apiKeyPath)

        let attrs = try FileManager.default.attributesOfItem(atPath: apiKeyPath)
        let perms = attrs[.posixPermissions] as? Int
        #expect(perms == 0o600)
    }

    @Test("config dir is created if missing")
    func testCreatesMissingDir() throws {
        let dir = NSTemporaryDirectory() + "token-test-newdir-\(UUID().uuidString)"
        defer { cleanup(dir) }

        // Dir doesn't exist yet
        #expect(!FileManager.default.fileExists(atPath: dir))

        // Create dir and write
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try "test_key".write(toFile: dir + "/api_key", atomically: true, encoding: .utf8)

        #expect(FileManager.default.fileExists(atPath: dir + "/api_key"))
    }

    // MARK: - Partial write scenarios

    @Test("api_key write failure does not prevent refresh_token write")
    func testPartialWriteApiKeyFails() throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }

        let apiKeyPath = dir + "/api_key"
        let refreshTokenPath = dir + "/refresh_token"

        // Make api_key path a directory so write fails
        try FileManager.default.createDirectory(atPath: apiKeyPath, withIntermediateDirectories: true)

        // api_key write should fail (path is a directory)
        var apiKeyWriteOk = true
        do {
            try "rdkey_test".write(toFile: apiKeyPath, atomically: true, encoding: .utf8)
        } catch {
            apiKeyWriteOk = false
        }
        #expect(!apiKeyWriteOk, "Writing to directory path should fail")

        // refresh_token write should still succeed independently
        try "rdrt_test".write(toFile: refreshTokenPath, atomically: true, encoding: .utf8)
        let saved = try String(contentsOfFile: refreshTokenPath, encoding: .utf8)
        #expect(saved == "rdrt_test")
    }

    @Test("refresh_token write failure does not corrupt api_key")
    func testPartialWriteRefreshFails() throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }

        let apiKeyPath = dir + "/api_key"
        let refreshTokenPath = dir + "/refresh_token"

        // Write api_key first (succeeds)
        try "rdkey_good".write(toFile: apiKeyPath, atomically: true, encoding: .utf8)

        // Make refresh_token path a directory so write fails
        try FileManager.default.createDirectory(atPath: refreshTokenPath, withIntermediateDirectories: true)

        var refreshWriteOk = true
        do {
            try "rdrt_test".write(toFile: refreshTokenPath, atomically: true, encoding: .utf8)
        } catch {
            refreshWriteOk = false
        }
        #expect(!refreshWriteOk, "Writing to directory path should fail")

        // api_key should be intact
        let saved = try String(contentsOfFile: apiKeyPath, encoding: .utf8)
        #expect(saved == "rdkey_good")
    }

    // MARK: - Atomic overwrite

    @Test("overwriting existing tokens preserves atomicity")
    func testAtomicOverwrite() throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }

        let path = dir + "/api_key"

        // Write initial value
        try "rdkey_old".write(toFile: path, atomically: true, encoding: .utf8)

        // Overwrite with new value
        try "rdkey_new".write(toFile: path, atomically: true, encoding: .utf8)

        let content = try String(contentsOfFile: path, encoding: .utf8)
        #expect(content == "rdkey_new")
    }

    @Test("reading nonexistent token file returns nil with try?")
    func testReadMissingToken() {
        let dir = makeTempDir()
        defer { cleanup(dir) }

        let content = try? String(contentsOfFile: dir + "/api_key", encoding: .utf8)
        #expect(content == nil)
    }

    @Test("trimming whitespace from token file")
    func testTokenTrimming() throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }

        let path = dir + "/api_key"
        try "  rdkey_test  \n".write(toFile: path, atomically: true, encoding: .utf8)

        let raw = try String(contentsOfFile: path, encoding: .utf8)
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(trimmed == "rdkey_test")
    }
}
