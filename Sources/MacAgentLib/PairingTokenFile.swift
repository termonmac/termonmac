import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// On-disk JSON format for `<configDir>/pairing_token.json`.
///
/// Single-file atomic write, carries both the token and its wall-clock expiry.
/// Daemon and `pair` command communicate exclusively through this file plus
/// SIGHUP; daemon never generates tokens.
public struct PairingTokenFile: Codable, Equatable, Sendable {
    public static let currentVersion = 2
    public static let ttlSeconds = 300

    public let v: Int
    public let token: String
    public let expires_at: Int

    public init(v: Int = PairingTokenFile.currentVersion, token: String, expires_at: Int) {
        self.v = v
        self.token = token
        self.expires_at = expires_at
    }
}

public enum PairingTokenLoadResult: Equatable, Sendable {
    case missing
    case expired
    case unsupportedVersion(Int)
    case corrupted(String)
    case ok(PairingTokenFile)
}

public enum PairingTokenStore {
    public static let fileName = "pairing_token.json"

    public static func path(in configDir: String) -> String {
        configDir + "/" + fileName
    }

    /// Load current pairing token from disk. Returns `.missing` if file absent.
    /// If parse fails, version mismatches, or file is expired, the on-disk
    /// file is deleted so the next call sees a clean `.missing` state.
    public static func load(
        configDir: String,
        now: () -> Int = { Int(Date().timeIntervalSince1970) }
    ) -> PairingTokenLoadResult {
        let p = path(in: configDir)
        let fm = FileManager.default
        guard fm.fileExists(atPath: p) else { return .missing }
        guard let data = fm.contents(atPath: p) else { return .missing }

        let decoded: PairingTokenFile
        do {
            decoded = try JSONDecoder().decode(PairingTokenFile.self, from: data)
        } catch {
            try? fm.removeItem(atPath: p)
            return .corrupted(String(describing: error))
        }

        if decoded.v != PairingTokenFile.currentVersion {
            try? fm.removeItem(atPath: p)
            return .unsupportedVersion(decoded.v)
        }
        if now() >= decoded.expires_at {
            try? fm.removeItem(atPath: p)
            return .expired
        }
        return .ok(decoded)
    }

    /// Atomically write the pairing token file with 0o600 permissions.
    /// Uses tempfile + rename; on any failure the previous file is untouched.
    public static func write(
        configDir: String,
        token: String,
        expiresAt: Int
    ) throws {
        let file = PairingTokenFile(token: token, expires_at: expiresAt)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(file)

        let finalPath = path(in: configDir)
        let tmpPath = finalPath + ".tmp.\(getpid())"
        let fm = FileManager.default
        try? fm.removeItem(atPath: tmpPath)

        if !fm.createFile(
            atPath: tmpPath,
            contents: data,
            attributes: [.posixPermissions: 0o600]
        ) {
            throw PairingTokenWriteError.tempfileCreateFailed(tmpPath)
        }

        if Darwin.rename(tmpPath, finalPath) != 0 {
            let code = errno
            try? fm.removeItem(atPath: tmpPath)
            throw PairingTokenWriteError.renameFailed(code)
        }
    }

    /// Delete the on-disk pairing token file, ignoring "not found" errors.
    public static func delete(configDir: String) {
        try? FileManager.default.removeItem(atPath: path(in: configDir))
    }
}

public enum PairingTokenWriteError: Error, Equatable {
    case tempfileCreateFailed(String)
    case renameFailed(Int32)
}
