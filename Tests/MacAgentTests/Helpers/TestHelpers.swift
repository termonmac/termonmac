import Foundation
import MacAgentLib

/// Thread-safe boolean flag for cross-task callback tracking.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    var value: Bool {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

/// Thread-safe integer counter.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    var value: Int { lock.withLock { _value } }
    func increment() { lock.withLock { _value += 1 } }
}

/// Thread-safe date array for tracking timestamps.
final class TimestampList: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [Date] = []
    var values: [Date] { lock.withLock { _values } }
    func append(_ date: Date) { lock.withLock { _values.append(date) } }
}

/// Create a temporary directory for test isolation.
func makeTempDir() -> String {
    let dir = NSTemporaryDirectory() + "relay-test-\(UUID().uuidString)"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}

/// Known pairing token used by tests that exercise the auth handshake.
let testPairingToken = "test-pairing-token-32chars-abcde"

/// Create a temp config dir with a pre-seeded pairing token so the
/// RelayConnection picks it up via `PairingTokenStore.load`.
func makeTempDirWithPairingToken(expiresAt: Int? = nil) -> String {
    let dir = makeTempDir()
    let exp = expiresAt ?? (Int(Date().timeIntervalSince1970) + PairingTokenFile.ttlSeconds)
    try? PairingTokenStore.write(configDir: dir, token: testPairingToken, expiresAt: exp)
    return dir
}

/// Pre-seed a trusted iOS device in `configDir` so RelayConnection treats
/// the supplied public key as a TOFU-verified reconnecting peer.
@discardableResult
func seedTrustedDevice(configDir: String, publicKey: String,
                       deviceType: String? = nil, label: String? = nil) -> Bool {
    let store = TrustStore(configDir: configDir)
    _ = store.load()
    do {
        _ = try store.add(publicKey: publicKey, deviceType: deviceType, proposedLabel: label)
        return true
    } catch {
        return false
    }
}

enum TestError: Error {
    case timeout(String)
}

/// Poll a condition until it becomes true, or throw on timeout.
func awaitCondition(
    timeout: TimeInterval = 5,
    interval: TimeInterval = 0.05,
    file: String = #file,
    line: Int = #line,
    _ condition: @escaping @Sendable () -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline {
            throw TestError.timeout("Condition not met within \(timeout)s at \(file):\(line)")
        }
        try await Task.sleep(for: .seconds(interval))
    }
}
