import Testing
import Foundation
@testable import RemoteDevCore

/// Tests that verify WebSocketClient is free from data races.
///
/// ## How to interpret
///
/// **Stress tests** (test 1-4): Exercise the concurrent access patterns that
/// caused 7 production crashes in 6 days. They pass if no crash occurs.
/// With TSan (`swift test --sanitize thread`), these detect races deterministically.
/// Without TSan, they still catch crashes from severe races.
///
/// **Behavioral test** (test 5): Verifies the lock's **observable invariant** —
/// that concurrent disconnect correctly resolves the connect continuation
/// exactly once. This test CAN fail without the lock (connect hangs → timeout).
@Suite("WebSocketClient concurrency safety")
struct WebSocketConcurrencyTests {

    // MARK: - Stress tests (crash detection)

    /// Production crash scenario: disconnect() called from wake notification
    /// (main queue) or network-change handler (net-monitor queue) while
    /// URLSession delegate callbacks access the same properties.
    @Test("Concurrent disconnect calls do not race",
          .timeLimit(.minutes(1)))
    func testConcurrentDisconnect() async throws {
        for _ in 0..<100 {
            let ws = WebSocketClient()

            let connectTask = Task {
                try? await ws.connect(url: URL(string: "wss://192.0.2.1:1")!)
            }

            try await Task.sleep(for: .milliseconds(5))

            let group = DispatchGroup()
            for _ in 0..<8 {
                group.enter()
                DispatchQueue.global().async {
                    ws.disconnect()
                    group.leave()
                }
            }
            group.wait()

            connectTask.cancel()
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    /// disconnect() from external thread + onDisconnect read from delegate
    /// queue. Before fix, onDisconnect was a plain stored property with
    /// no synchronization.
    @Test("onDisconnect read/write does not race",
          .timeLimit(.minutes(1)))
    func testOnDisconnectReadWriteNoRace() async throws {
        for _ in 0..<200 {
            let ws = WebSocketClient()
            let callCount = Counter()

            ws.onDisconnect = { callCount.increment() }

            let group = DispatchGroup()
            for _ in 0..<8 {
                group.enter()
                DispatchQueue.global().async {
                    ws.onDisconnect?()
                    ws.onDisconnect = { callCount.increment() }
                    group.leave()
                }
            }
            group.wait()
        }
    }

    /// Rapid connect→disconnect cycles on the same instance.
    /// Without locks, delegate callbacks from cycle N can race with
    /// state setup of cycle N+1.
    @Test("Rapid connect-disconnect cycles do not crash",
          .timeLimit(.minutes(1)))
    func testRapidConnectDisconnectCycles() async throws {
        let ws = WebSocketClient()

        for _ in 0..<30 {
            let connectTask = Task {
                try? await ws.connect(url: URL(string: "wss://192.0.2.1:1")!)
            }

            try await Task.sleep(for: .milliseconds(3))

            let done = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                ws.disconnect()
                done.signal()
            }
            done.wait()

            connectTask.cancel()
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    /// disconnect() racing with send() on different threads.
    /// send() reads self.task; disconnect() nils it.
    @Test("Disconnect racing with send does not crash",
          .timeLimit(.minutes(1)))
    func testDisconnectRacingWithSend() async throws {
        for _ in 0..<50 {
            let ws = WebSocketClient()

            let connectTask = Task {
                try? await ws.connect(url: URL(string: "wss://192.0.2.1:1")!)
            }

            try await Task.sleep(for: .milliseconds(5))

            let group = DispatchGroup()

            group.enter()
            DispatchQueue.global().async {
                ws.disconnect()
                group.leave()
            }

            group.enter()
            Task {
                try? await ws.send("test")
                group.leave()
            }

            group.wait()

            connectTask.cancel()
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    // MARK: - Behavioral test (observable invariant)

    /// Verifies that concurrent disconnect properly resolves the connect
    /// continuation — connect() must either succeed or throw, never hang.
    ///
    /// **Before fix**: disconnect() could race with didCompleteWithError on
    /// the delegate queue. In the worst case, both threads read
    /// connectContinuation as non-nil but neither properly resumes it
    /// (torn read of the Optional struct), causing connect() to hang forever.
    ///
    /// **After fix**: The lock ensures exactly one thread takes the
    /// continuation; the other sees nil. Connect always resolves.
    @Test("Concurrent disconnect always resolves pending connect",
          .timeLimit(.minutes(1)))
    func testDisconnectResolvesConnect() async throws {
        for i in 0..<100 {
            let ws = WebSocketClient()
            let resolved = Flag()

            // Start connect (will hang on non-routable IP)
            let connectTask = Task {
                defer { resolved.value = true }
                try await ws.connect(url: URL(string: "wss://192.0.2.1:1")!)
            }

            // Let connect set up connectContinuation
            try await Task.sleep(for: .milliseconds(5))

            // Race: disconnect from 4 threads + didCompleteWithError from
            // URLSession delegate queue (triggered by task.cancel inside disconnect)
            let group = DispatchGroup()
            for _ in 0..<4 {
                group.enter()
                DispatchQueue.global().async {
                    ws.disconnect()
                    group.leave()
                }
            }
            group.wait()

            // connect() MUST resolve within 2 seconds — if the continuation
            // was lost due to a race, this would hang until the test timeout.
            let deadline = Date().addingTimeInterval(2)
            while !resolved.value && Date() < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }

            #expect(resolved.value,
                    "Iteration \(i): connect() did not resolve after concurrent disconnect — continuation likely lost due to race")

            connectTask.cancel()
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

// MARK: - Thread-safe helpers (local to avoid cross-target dependency)

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    var value: Int { lock.withLock { _value } }
    func increment() { lock.withLock { _value += 1 } }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    var value: Bool {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}
