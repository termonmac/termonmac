import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Multi-key trust store for iOS devices known to this Mac agent.
/// Replaces the legacy single-key TOFU pin file.
///
/// Single source of truth is the in-memory `devices` array; the JSON file is
/// only touched at load time and when the caller explicitly commits a change.
/// On parse failure the file is renamed to `.corrupted.<ts>` and a sentinel
/// `TRUST_STORE_RESET_<ts>` is dropped; the daemon keeps running with an
/// empty list so the surviving pairing-token gate is what prevents bypass.
public struct TrustedDevice: Codable, Equatable, Sendable {
    public var public_key: String
    public var label: String
    public var added_at: Int
    public var last_seen: Int
    public var device_type: String   // "iPhone" | "iPad" | "unknown"

    public init(public_key: String, label: String, added_at: Int,
                last_seen: Int, device_type: String) {
        self.public_key = public_key
        self.label = label
        self.added_at = added_at
        self.last_seen = last_seen
        self.device_type = device_type
    }
}

public struct TrustStoreFile: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public let v: Int
    public let devices: [TrustedDevice]

    public init(v: Int = TrustStoreFile.currentVersion, devices: [TrustedDevice]) {
        self.v = v
        self.devices = devices
    }
}

public enum TrustStoreError: Error, Equatable {
    case unsupportedVersion(Int)
    case deviceLimitReached(Int)
    case labelNotFound(String)
    case labelCollision(String)
    case invalidLabel(String)
    case writeFailed(String)
}

public enum TrustStoreLoadOutcome: Equatable, Sendable {
    case missing
    case loaded(deviceCount: Int)
    case reset(reason: String, backupPath: String, sentinelPath: String)
    case unsupportedVersion(Int)
}

public final class TrustStore {
    public static let fileName = "known_ios_devices.json"
    public static let deviceLimit = 32
    public static let labelMaxLength = 64
    public static let sentinelPrefix = "TRUST_STORE_RESET_"

    public let configDir: String
    public private(set) var devices: [TrustedDevice]

    private let nowProvider: () -> Int
    private let filePath: String

    public init(configDir: String, now: @escaping () -> Int = { Int(Date().timeIntervalSince1970) }) {
        self.configDir = configDir
        self.nowProvider = now
        self.devices = []
        self.filePath = configDir + "/" + TrustStore.fileName
    }

    // MARK: - Load

    /// Load the on-disk trust store into memory. On corruption the file is
    /// rotated to `.corrupted.<ts>` and a sentinel is written so the next
    /// CLI invocation can surface a banner. Returns the outcome so the
    /// caller (daemon init / CLI) can decide whether to log warnings.
    @discardableResult
    public func load() -> TrustStoreLoadOutcome {
        let fm = FileManager.default
        guard fm.fileExists(atPath: filePath) else {
            devices = []
            return .missing
        }
        guard let data = fm.contents(atPath: filePath) else {
            devices = []
            return .missing
        }

        let decoded: TrustStoreFile
        do {
            decoded = try JSONDecoder().decode(TrustStoreFile.self, from: data)
        } catch {
            return handleCorruption(
                reason: String(describing: error),
                originalSize: data.count
            )
        }

        if decoded.v != TrustStoreFile.currentVersion {
            // Forward-compat: refuse to touch a newer file rather than
            // silently downgrade. Caller should bail.
            devices = []
            return .unsupportedVersion(decoded.v)
        }

        devices = decoded.devices
        return .loaded(deviceCount: decoded.devices.count)
    }

    private func handleCorruption(reason: String, originalSize: Int) -> TrustStoreLoadOutcome {
        let ts = nowProvider()
        let backupPath = filePath + ".corrupted.\(ts)"
        let sentinelPath = configDir + "/\(TrustStore.sentinelPrefix)\(ts)"
        let fm = FileManager.default

        try? fm.moveItem(atPath: filePath, toPath: backupPath)

        let sentinel: [String: Any] = [
            "reason": reason,
            "original_size": originalSize,
            "timestamp": ts,
        ]
        let sentinelData = (try? JSONSerialization.data(
            withJSONObject: sentinel,
            options: [.sortedKeys]
        )) ?? Data("{}".utf8)
        _ = fm.createFile(atPath: sentinelPath, contents: sentinelData,
                          attributes: [.posixPermissions: 0o600])

        // Seed an empty store so the next read is clean.
        do {
            try persist(devices: [])
        } catch {
            // Non-fatal: daemon still runs with empty list even if the file
            // can't be created (next write will try again).
        }
        devices = []
        return .reset(reason: reason, backupPath: backupPath, sentinelPath: sentinelPath)
    }

    // MARK: - Sentinel introspection (used by CLI banner + pair-command gate)

    public static func listSentinels(in configDir: String) -> [String] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: configDir) else {
            return []
        }
        return entries
            .filter { $0.hasPrefix(sentinelPrefix) }
            .sorted()
            .map { configDir + "/" + $0 }
    }

    public static func clearSentinels(in configDir: String) -> Int {
        let fm = FileManager.default
        let sentinels = listSentinels(in: configDir)
        for p in sentinels {
            try? fm.removeItem(atPath: p)
        }
        return sentinels.count
    }

    // MARK: - Queries

    public func find(publicKey: String) -> TrustedDevice? {
        devices.first { $0.public_key == publicKey }
    }

    public func contains(publicKey: String) -> Bool {
        find(publicKey: publicKey) != nil
    }

    // MARK: - Mutations (commit to memory + disk atomically)

    /// Append a new device to the store. Throws on label collision, invalid
    /// label, or when the 32-device limit has been reached.
    @discardableResult
    public func add(publicKey: String, deviceType rawType: String?,
                    proposedLabel: String? = nil) throws -> TrustedDevice {
        if devices.count >= TrustStore.deviceLimit {
            throw TrustStoreError.deviceLimitReached(TrustStore.deviceLimit)
        }
        let deviceType = Self.normalizedDeviceType(rawType)
        let label: String
        if let proposed = proposedLabel {
            try Self.validateLabel(proposed)
            if devices.contains(where: { $0.label == proposed }) {
                throw TrustStoreError.labelCollision(proposed)
            }
            label = proposed
        } else {
            label = autoLabel(for: deviceType)
        }

        let now = nowProvider()
        let device = TrustedDevice(
            public_key: publicKey,
            label: label,
            added_at: now,
            last_seen: now,
            device_type: deviceType
        )
        let previous = devices
        devices.append(device)
        do {
            try persist(devices: devices)
        } catch {
            devices = previous
            throw error
        }
        return device
    }

    /// Update `last_seen` for a known device. No-ops if not found.
    public func touch(publicKey: String) throws {
        guard let idx = devices.firstIndex(where: { $0.public_key == publicKey }) else {
            return
        }
        let previous = devices
        devices[idx].last_seen = nowProvider()
        do {
            try persist(devices: devices)
        } catch {
            devices = previous
            throw error
        }
    }

    public func remove(label: String) throws {
        guard let idx = devices.firstIndex(where: { $0.label == label }) else {
            throw TrustStoreError.labelNotFound(label)
        }
        let previous = devices
        devices.remove(at: idx)
        do {
            try persist(devices: devices)
        } catch {
            devices = previous
            throw error
        }
    }

    public func rename(from oldLabel: String, to newLabel: String) throws {
        try Self.validateLabel(newLabel)
        guard let idx = devices.firstIndex(where: { $0.label == oldLabel }) else {
            throw TrustStoreError.labelNotFound(oldLabel)
        }
        if devices.contains(where: { $0.label == newLabel }) {
            throw TrustStoreError.labelCollision(newLabel)
        }
        let previous = devices
        devices[idx].label = newLabel
        do {
            try persist(devices: devices)
        } catch {
            devices = previous
            throw error
        }
    }

    // MARK: - Persistence

    /// Atomic tempfile + rename. 0o600 permissions. Throws on failure
    /// without touching the existing file.
    private func persist(devices: [TrustedDevice]) throws {
        let file = TrustStoreFile(devices: devices)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(file)
        } catch {
            throw TrustStoreError.writeFailed("encode: \(error)")
        }

        let tmpPath = filePath + ".tmp.\(getpid())"
        let fm = FileManager.default
        try? fm.removeItem(atPath: tmpPath)

        if !fm.createFile(
            atPath: tmpPath,
            contents: data,
            attributes: [.posixPermissions: 0o600]
        ) {
            throw TrustStoreError.writeFailed("tempfile create failed")
        }

        if Darwin.rename(tmpPath, filePath) != 0 {
            let code = errno
            try? fm.removeItem(atPath: tmpPath)
            throw TrustStoreError.writeFailed("rename failed: errno=\(code)")
        }
    }

    // MARK: - Label generation + validation

    static func normalizedDeviceType(_ raw: String?) -> String {
        switch raw {
        case "iPhone", "iPad": return raw!
        default: return "unknown"
        }
    }

    private func autoLabel(for deviceType: String) -> String {
        let prefix: String
        switch deviceType {
        case "iPhone": prefix = "iPhone"
        case "iPad": prefix = "iPad"
        default: prefix = "device"
        }
        var n = 1
        while devices.contains(where: { $0.label == "\(prefix)-\(n)" }) {
            n += 1
        }
        return "\(prefix)-\(n)"
    }

    static func validateLabel(_ label: String) throws {
        if label.isEmpty || label.count > TrustStore.labelMaxLength {
            throw TrustStoreError.invalidLabel(label)
        }
        for scalar in label.unicodeScalars {
            if scalar.value == 0 || (scalar.value < 0x20) || scalar.value == 0x7F {
                throw TrustStoreError.invalidLabel(label)
            }
        }
    }
}
