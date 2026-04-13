import Testing
import Foundation
@testable import MacAgentLib
import RemoteDevCore

#if os(macOS)
@Suite("InputLogStore DataRace")
struct InputLogStoreDataRaceTests {

    // MARK: - Unit: concurrent appendEntry + loadLog don't crash

    @Test("concurrent appendEntry and loadLog on same session don't crash")
    func concurrentAppendAndLoad() async throws {
        let store = InputLogStore()
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("InputLogStoreTest-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        let sessionId = "test-session"

        await withTaskGroup(of: Void.self) { group in
            // Writers: concurrent appendEntry (mutates cache dictionary)
            for i in 0..<200 {
                group.addTask {
                    let entry = InputLogEntry(type: "terminalInput", text: "cmd-\(i)")
                    store.appendEntry(entry, sessionId: sessionId, workDir: tmpDir)
                }
            }
            // Readers: concurrent loadLog (reads cache dictionary)
            for _ in 0..<200 {
                group.addTask {
                    _ = store.loadLog(sessionId: sessionId, workDir: tmpDir)
                }
            }
        }

        // Verify all entries landed
        let log = store.loadLog(sessionId: sessionId, workDir: tmpDir)
        #expect(log.entries.count == 200)
    }

    // MARK: - Integration: appendEntry racing with scheduled saveToDisk

    @Test("appendEntry racing with background saveToDisk doesn't crash")
    func appendEntryRacingWithSave() async throws {
        let store = InputLogStore()
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("InputLogStoreSaveTest-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        let sessionId = "save-race"

        // Rapidly append entries — each schedules a save on the internal queue
        for i in 0..<100 {
            let entry = InputLogEntry(type: "terminalInput", text: "line-\(i)")
            store.appendEntry(entry, sessionId: sessionId, workDir: tmpDir)
        }

        // Wait for the debounced save (0.5s) + margin
        try await Task.sleep(for: .milliseconds(800))

        // Flush remaining and verify file on disk
        store.flushToDisk(sessionId: sessionId, workDir: tmpDir)

        let fileURL = URL(fileURLWithPath: tmpDir)
            .appendingPathComponent(".remotedev/input-log/\(sessionId).json")
        #expect(FileManager.default.fileExists(atPath: fileURL.path),
                "saveToDisk should have written the file")

        let data = try Data(contentsOf: fileURL)
        let decoded = try JSONDecoder().decode(InputLogData.self, from: data)
        #expect(decoded.entries.count == 100)
    }
}

@Suite("PTYManager DataRace")
struct PTYManagerDataRaceTests {

    // MARK: - Unit: concurrent switchToBufferOnly / switchToLive

    @Test("concurrent switchToBufferOnly/switchToLive during output doesn't crash")
    func concurrentModeSwitch() async throws {
        let manager = PTYManager()
        defer { manager.destroyAll() }

        manager.onOutput = { _, _ in }
        manager.createSession(sessionId: "test", name: "zsh", cols: 80, rows: 24)

        // Generate output to create contention with onOutput closure
        manager.write(Data("for i in $(seq 1 50); do echo line$i; done\n".utf8), to: "test")

        // Rapidly switch modes from multiple threads
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<100 {
                group.addTask { manager.switchToBufferOnly() }
                group.addTask { manager.switchToLive() }
            }
        }

        // Session still alive after mode switches
        try await Task.sleep(for: .milliseconds(300))
        #expect(manager.hasSession("test"))
    }

    // MARK: - Integration: live mode restores output after buffer-only

    @Test("switchToLive restores output delivery after switchToBufferOnly")
    func modeSwitchOutputDelivery() async throws {
        let manager = PTYManager()
        defer { manager.destroyAll() }

        let collected = OutputCollector()
        manager.onOutput = { _, data in collected.append(data) }

        manager.createSession(sessionId: "test", name: "zsh", cols: 80, rows: 24)
        try await Task.sleep(for: .milliseconds(300))

        // Switch to buffer-only, then back to live
        manager.switchToBufferOnly()
        // setOnOutput is async (dispatched to outputQueue), wait for it to take effect
        try await Task.sleep(for: .milliseconds(100))
        manager.switchToLive()
        try await Task.sleep(for: .milliseconds(100))

        // Reset and send a marker command
        collected.reset()
        let marker = "LIVEOK_\(UUID().uuidString.prefix(8))"
        manager.write(Data("echo \(marker)\n".utf8), to: "test")

        // Wait for output to appear
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            if collected.string().contains(marker) { break }
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(collected.string().contains(marker),
                "Live mode should deliver output after buffer-only round-trip")
    }
}

/// Thread-safe output collector for async PTY output.
private final class OutputCollector: @unchecked Sendable {
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

    func reset() {
        lock.lock()
        data = Data()
        lock.unlock()
    }
}
#endif
