import Testing
import Foundation
@testable import MacAgentLib

#if os(macOS)
@Suite("PTYManager")
struct PTYManagerTests {

    @Test("sessionsUnderLimitAllowed — 4 sessions all succeed with maxSessions=4")
    func sessionsUnderLimitAllowed() {
        let manager = PTYManager(maxSessions: 4)
        defer { manager.destroyAll() }

        for i in 0..<4 {
            let result = manager.createSession(sessionId: "s\(i)", name: "zsh-\(i)", cols: 80, rows: 24)
            #expect(result.success == true, "Session \(i) should succeed")
        }
        #expect(manager.sessionCount == 4)
    }

    @Test("sessionAtLimitBlocked — 5th session returns false with maxSessions=4")
    func sessionAtLimitBlocked() {
        let manager = PTYManager(maxSessions: 4)
        defer { manager.destroyAll() }

        for i in 0..<4 {
            let result = manager.createSession(sessionId: "s\(i)", name: "zsh-\(i)", cols: 80, rows: 24)
            #expect(result.success == true)
        }
        #expect(manager.sessionCount == 4)

        let rejected = manager.createSession(sessionId: "s4", name: "zsh-4", cols: 80, rows: 24)
        #expect(rejected.success == false)
        #expect(rejected.error?.contains("session limit") == true)
        #expect(manager.sessionCount == 4)
    }

    @Test("updateMaxSessions raises limit")
    func updateMaxSessionsRaisesLimit() {
        let manager = PTYManager(maxSessions: 4)
        defer { manager.destroyAll() }

        #expect(manager.maxSessions == 4)
        manager.updateMaxSessions(32)
        #expect(manager.maxSessions == 32)
    }

    @Test("updateMaxSessions does not shrink below current session count")
    func updateMaxSessionsNoShrink() {
        let manager = PTYManager(maxSessions: 16)
        defer { manager.destroyAll() }

        for i in 0..<8 {
            manager.createSession(sessionId: "s\(i)", name: "zsh-\(i)", cols: 80, rows: 24)
        }
        #expect(manager.sessionCount == 8)

        manager.updateMaxSessions(4)
        #expect(manager.maxSessions == 8)  // clamped to current count
    }

    @Test("negative maxSessions means unlimited")
    func negativeMaxSessionsUnlimited() {
        let manager = PTYManager(maxSessions: -1)
        defer { manager.destroyAll() }

        for i in 0..<20 {
            let result = manager.createSession(sessionId: "s\(i)", name: "zsh-\(i)", cols: 80, rows: 24)
            #expect(result.success == true, "Session \(i) should succeed with unlimited")
        }
        #expect(manager.sessionCount == 20)
    }

    @Test("updateMaxSessions to negative enables unlimited")
    func updateToNegativeUnlimited() {
        let manager = PTYManager(maxSessions: 2)
        defer { manager.destroyAll() }

        manager.createSession(sessionId: "s0", name: "zsh-0", cols: 80, rows: 24)
        manager.createSession(sessionId: "s1", name: "zsh-1", cols: 80, rows: 24)
        let rejected = manager.createSession(sessionId: "s2", name: "zsh-2", cols: 80, rows: 24)
        #expect(rejected.success == false)

        manager.updateMaxSessions(-1)
        #expect(manager.maxSessions == -1)
        let ok = manager.createSession(sessionId: "s2", name: "zsh-2", cols: 80, rows: 24)
        #expect(ok.success == true)
    }

    @Test("getSize returns cols/rows from createSession")
    func getSizeReturnsCreatedSize() {
        let manager = PTYManager()
        defer { manager.destroyAll() }

        manager.createSession(sessionId: "s1", name: "zsh", cols: 120, rows: 40)
        let size = manager.getSize(sessionId: "s1")
        #expect(size.cols == 120)
        #expect(size.rows == 40)
    }

    @Test("getSize updates after resize")
    func getSizeUpdatesAfterResize() {
        let manager = PTYManager()
        defer { manager.destroyAll() }

        manager.createSession(sessionId: "s1", name: "zsh", cols: 80, rows: 24)
        manager.resize(sessionId: "s1", cols: 132, rows: 50)
        let size = manager.getSize(sessionId: "s1")
        #expect(size.cols == 132)
        #expect(size.rows == 50)
    }

    @Test("getSize defaults to 80x24 for unknown session")
    func getSizeDefaultsForUnknown() {
        let manager = PTYManager()
        let size = manager.getSize(sessionId: "nonexistent")
        #expect(size.cols == 80)
        #expect(size.rows == 24)
    }

    @Test("SHELL_SESSIONS_DISABLE is set in PTY child")
    func shellSessionsDisableIsSet() async throws {
        let manager = PTYManager()
        defer { manager.destroyAll() }

        let collected = Collected()
        manager.onOutput = { _, data in
            collected.append(data)
        }

        manager.createSession(sessionId: "env-test", name: "zsh", cols: 80, rows: 24)

        // Wait for shell to initialize
        try await Task.sleep(for: .milliseconds(500))

        // Use printenv and wrap with unique markers on separate lines
        let cmd = "echo SSDBEGIN; printenv SHELL_SESSIONS_DISABLE; echo SSDEND\n"
        manager.write(Data(cmd.utf8), to: "env-test")

        // Wait for SSDEND to appear (up to 5s)
        let deadline = ContinuousClock.now + .seconds(5)
        var found = false
        while ContinuousClock.now < deadline {
            let text = collected.string()
            if text.contains("SSDEND") {
                // Use .backwards to skip the echoed command and find actual output
                if let begin = text.range(of: "SSDBEGIN", options: .backwards),
                   let end = text.range(of: "SSDEND", options: .backwards) {
                    let between = text[begin.upperBound..<end.lowerBound]
                    let trimmed = between.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed == "1" {
                        found = true
                    }
                }
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(found, "Expected SHELL_SESSIONS_DISABLE=1 in PTY output")
    }
}

/// Thread-safe collector for async PTY output.
private final class Collected: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    func string() -> String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: data, encoding: .utf8) ?? ""
    }

}
#endif
