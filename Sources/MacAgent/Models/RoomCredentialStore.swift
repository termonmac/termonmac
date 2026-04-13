import Foundation
import RemoteDevCore

#if os(macOS)
/// Persists room credentials (room_id, room_secret, room_name) to `room.json`
/// so they survive Mac agent restarts. iOS can reconnect without re-scanning QR.
///
/// File permissions: 0600 (owner read/write only) — room_secret is sensitive.
struct RoomCredentialStore {
    struct Credentials: Codable {
        var roomId: String
        var roomSecret: String
        var roomName: String?
        var createdAt: String  // ISO 8601
        var secretRotated: Bool?

        enum CodingKeys: String, CodingKey {
            case roomId = "room_id"
            case roomSecret = "room_secret"
            case roomName = "room_name"
            case createdAt = "created_at"
            case secretRotated = "secret_rotated"
        }
    }

    let configDir: String
    private let filePath: String
    private let fm = FileManager.default

    init(configDir: String) {
        self.configDir = configDir
        self.filePath = configDir + "/room.json"
    }

    /// Load existing credentials or generate new ones.
    func loadOrGenerate() -> Credentials {
        if let creds = load() {
            log("[room] Loaded persistent room credentials")
            log("[room]   Room ID:  \(creds.roomId)")
            log("[room]   Name:     \(creds.roomName ?? "(unnamed)")")
            log("[room]   Created:  \(creds.createdAt)")
            return creds
        }
        let creds = generate()
        save(creds)
        log("[room] Generated new room credentials")
        log("[room]   Room ID:  \(creds.roomId)")
        return creds
    }

    /// Regenerate room credentials (used by reset-room and collision recovery).
    func regenerate(keepName: Bool = true) -> Credentials {
        let oldName = load()?.roomName
        let creds = generate(roomName: keepName ? oldName : nil)
        save(creds)
        log("[room] Regenerated room credentials")
        log("[room]   New Room ID: \(creds.roomId)")
        return creds
    }

    /// Update just the room secret (used by auto-rotate after first pairing).
    func updateSecret(_ newSecret: String) -> Credentials? {
        guard var creds = load() else { return nil }
        creds.roomSecret = newSecret
        creds.secretRotated = true
        save(creds)
        log("[room] Secret rotated (auto-rotate after first pairing)")
        return creds
    }

    /// Update the room name without changing credentials.
    func rename(_ newName: String) -> Credentials? {
        guard var creds = load() else { return nil }
        creds.roomName = newName
        save(creds)
        log("[room] Renamed room to: \(newName)")
        return creds
    }

    /// Read current credentials (returns nil if file missing or corrupt).
    func load() -> Credentials? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)) else {
            return nil
        }
        do {
            return try JSONDecoder().decode(Credentials.self, from: data)
        } catch {
            log("[room] WARNING: room.json is corrupt (\(error.localizedDescription)). Will regenerate.")
            log("[room]   iOS devices will need to re-scan the QR code.")
            return nil
        }
    }

    // MARK: - Private

    private func generate(roomName: String? = nil) -> Credentials {
        Credentials(
            roomId: SessionCrypto.randomAlphanumeric(10).uppercased(),
            roomSecret: SessionCrypto.randomAlphanumeric(32),
            roomName: roomName,
            createdAt: ISO8601DateFormatter().string(from: Date())
        )
    }

    private func save(_ creds: Credentials) {
        if !fm.fileExists(atPath: configDir) {
            try? fm.createDirectory(atPath: configDir, withIntermediateDirectories: true)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(creds) else { return }
        if !fm.createFile(atPath: filePath, contents: data,
                          attributes: [.posixPermissions: 0o600]) {
            log("[room] WARNING: failed to save room.json to \(filePath)")
        }
    }
}
#endif
