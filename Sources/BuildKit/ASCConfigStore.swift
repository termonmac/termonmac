import Foundation
import RemoteDevCore

#if os(macOS)
/// Persists ASC (App Store Connect) API Key configuration to `asc.json`
/// so builds can upload to TestFlight without environment variables.
///
/// File permissions: 0600 (owner read/write only).
public struct ASCConfigStore: @unchecked Sendable {
    public static let filename = "asc.json"

    public struct Config: Codable {
        public var keyId: String       // ASC API Key ID
        public var issuerId: String    // Issuer ID (UUID)
        public var keyPath: String?    // Custom .p8 path (nil = default)

        public init(keyId: String, issuerId: String, keyPath: String? = nil) {
            self.keyId = keyId
            self.issuerId = issuerId
            self.keyPath = keyPath
        }

        enum CodingKeys: String, CodingKey {
            case keyId = "key_id"
            case issuerId = "issuer_id"
            case keyPath = "key_path"
        }
    }

    public let configDir: String
    private let filePath: String
    private let fm = FileManager.default

    public init(configDir: String) {
        self.configDir = configDir
        self.filePath = configDir + "/" + Self.filename
    }

    /// Read current config (returns nil if file missing or corrupt).
    public func load() -> Config? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)) else {
            return nil
        }
        do {
            return try JSONDecoder().decode(Config.self, from: data)
        } catch {
            log("[asc] WARNING: asc.json is corrupt (\(error.localizedDescription)).")
            return nil
        }
    }

    /// Save config to disk with restricted permissions.
    public func save(_ config: Config) {
        if !fm.fileExists(atPath: configDir) {
            try? fm.createDirectory(atPath: configDir, withIntermediateDirectories: true)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(config) else { return }
        fm.createFile(atPath: filePath, contents: data,
                      attributes: [.posixPermissions: 0o600])
    }

    /// Delete ASC config file from disk.
    public func delete() {
        try? fm.removeItem(atPath: filePath)
    }

    // MARK: - Three-state support

    private struct DisabledMarker: Codable {
        let disabled: Bool
    }

    /// Load ASC config as a three-state value: unset, disabled, or configured.
    public func loadState() -> ASCConfigState {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)) else {
            return .unset
        }
        if let marker = try? JSONDecoder().decode(DisabledMarker.self, from: data), marker.disabled {
            return .disabled
        }
        if let config = try? JSONDecoder().decode(Config.self, from: data) {
            return .configured(ASCConfig(keyId: config.keyId, issuerId: config.issuerId,
                                          keyPath: resolvedKeyPath(for: config)))
        }
        return .unset  // corrupt file
    }

    /// Write a disabled marker to asc.json, preventing env var fallback.
    public func markDisabled() {
        if !fm.fileExists(atPath: configDir) {
            try? fm.createDirectory(atPath: configDir, withIntermediateDirectories: true)
        }
        let data = try? JSONEncoder().encode(DisabledMarker(disabled: true))
        fm.createFile(atPath: filePath, contents: data,
                      attributes: [.posixPermissions: 0o600])
    }

    /// Resolve the .p8 key file path: custom path or default location.
    public func resolvedKeyPath(for config: Config) -> String {
        if let custom = config.keyPath, !custom.isEmpty {
            return NSString(string: custom).expandingTildeInPath
        }
        return Self.defaultKeyPath(keyId: config.keyId)
    }

    /// Default key file path: ~/.private_keys/AuthKey_{keyId}.p8
    public static func defaultKeyPath(keyId: String) -> String {
        NSString(string: "~/.private_keys/AuthKey_\(keyId).p8").expandingTildeInPath
    }
}
#endif
