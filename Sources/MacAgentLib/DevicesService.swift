import Foundation

/// Pure-logic backend for the `termonmac devices ...` subcommands.
/// Kept in `MacAgentLib` rather than the executable target so unit tests
/// can drive list / remove / rename / acknowledge-reset without any CLI
/// rendering or signal-sending side effects.
public struct DeviceRow: Equatable, Sendable {
    public let label: String
    public let deviceType: String
    public let addedAtEpoch: Int
    public let lastSeenEpoch: Int
    public let publicKey: String
}

public struct ListResult: Equatable, Sendable {
    public let rows: [DeviceRow]
    /// Pending reset events (derived from `TRUST_STORE_RESET_*` sentinels).
    public let pendingResetCount: Int
}

public enum DeviceMutation: Equatable, Sendable {
    case removed(label: String)
    case renamed(old: String, new: String)
}

public final class DevicesService {
    public let trustStore: TrustStore
    public let configDir: String

    public init(configDir: String, trustStore: TrustStore? = nil) {
        self.configDir = configDir
        self.trustStore = trustStore ?? TrustStore(configDir: configDir)
        _ = self.trustStore.load()
    }

    // MARK: - list

    public func list() -> ListResult {
        let rows = trustStore.devices.map {
            DeviceRow(
                label: $0.label,
                deviceType: $0.device_type,
                addedAtEpoch: $0.added_at,
                lastSeenEpoch: $0.last_seen,
                publicKey: $0.public_key
            )
        }
        return ListResult(
            rows: rows,
            pendingResetCount: TrustStore.listSentinels(in: configDir).count
        )
    }

    // MARK: - remove

    /// Remove a device by label. Does NOT send SIGHUP — the caller (CLI
    /// wrapper) is responsible for invoking `DaemonPidFile.signalDaemon`
    /// after a successful removal, so tests can assert on the mutation
    /// without bringing a running daemon into the picture.
    public func remove(label: String) throws -> DeviceMutation {
        try trustStore.remove(label: label)
        return .removed(label: label)
    }

    // MARK: - rename

    public func rename(from oldLabel: String, to newLabel: String) throws -> DeviceMutation {
        try trustStore.rename(from: oldLabel, to: newLabel)
        return .renamed(old: oldLabel, new: newLabel)
    }

    // MARK: - acknowledge-reset

    /// Remove all `TRUST_STORE_RESET_*` sentinel files; `.corrupted.<ts>`
    /// backup files are left in place intentionally for forensics.
    public func acknowledgeReset() -> Int {
        TrustStore.clearSentinels(in: configDir)
    }

    // MARK: - pair gate

    /// Returns true if a pair command should be blocked because one or more
    /// reset sentinels are pending acknowledgement (D-I7).
    public func pairIsBlockedBySentinel() -> Bool {
        !TrustStore.listSentinels(in: configDir).isEmpty
    }
}

// MARK: - Output rendering (pure, testable separately)

public enum DevicesRenderer {
    /// Render the `devices list` human-readable table. Uses ISO dates in the
    /// system time zone; no ANSI colors.
    public static func renderList(_ result: ListResult, now: Date = Date()) -> String {
        var lines: [String] = []
        if result.pendingResetCount > 0 {
            lines.append(bannerForReset(count: result.pendingResetCount))
            lines.append("")
        }
        if result.rows.isEmpty {
            lines.append("No trusted devices. Run `termonmac pair` to add one.")
            return lines.joined(separator: "\n")
        }
        lines.append("LABEL        TYPE      ADDED        LAST SEEN    PUBLIC KEY")
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        for row in result.rows {
            let added = df.string(from: Date(timeIntervalSince1970: TimeInterval(row.addedAtEpoch)))
            let lastSeen = df.string(from: Date(timeIntervalSince1970: TimeInterval(row.lastSeenEpoch)))
            let keyShort = shortKey(row.publicKey)
            let label = row.label.padding(toLength: 12, withPad: " ", startingAt: 0)
            let type = row.deviceType.padding(toLength: 9, withPad: " ", startingAt: 0)
            let a = added.padding(toLength: 12, withPad: " ", startingAt: 0)
            let l = lastSeen.padding(toLength: 12, withPad: " ", startingAt: 0)
            lines.append("\(label) \(type) \(a) \(l) \(keyShort)")
        }
        return lines.joined(separator: "\n")
    }

    /// JSON representation of the list for scripts.
    public static func renderListJson(_ result: ListResult) throws -> String {
        struct Row: Codable {
            let label: String
            let device_type: String
            let added_at: Int
            let last_seen: Int
            let public_key: String
        }
        struct Payload: Codable {
            let devices: [Row]
            let pending_reset_count: Int
        }
        let payload = Payload(
            devices: result.rows.map {
                Row(label: $0.label, device_type: $0.deviceType,
                    added_at: $0.addedAtEpoch, last_seen: $0.lastSeenEpoch,
                    public_key: $0.publicKey)
            },
            pending_reset_count: result.pendingResetCount
        )
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try enc.encode(payload)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    public static func shortKey(_ key: String) -> String {
        guard key.count > 14 else { return key }
        let prefix = key.prefix(8)
        let suffix = key.suffix(4)
        return "\(prefix)…\(suffix)"
    }

    public static func bannerForReset(count: Int) -> String {
        let noun = count == 1 ? "reset event" : "reset events"
        return """
        ⚠️  TermOnMac: trust store was reset (\(count) \(noun) detected).
            All previous device authorizations are gone.
            Run `termonmac devices acknowledge-reset` to dismiss this warning.
        """
    }

    public static func pairBlockedBanner() -> String {
        """
        ⚠️  Trust store was reset due to parse failure.
            Before re-pairing, review the corruption and acknowledge it:
              termonmac devices list                  # confirm current state
              termonmac devices acknowledge-reset     # clear the warning

            If you did not cause this reset and cannot explain it, investigate
            before proceeding — your trust store may have been tampered with.
        """
    }
}
