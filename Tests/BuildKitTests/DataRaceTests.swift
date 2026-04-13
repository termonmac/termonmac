import Testing
import Foundation
@testable import BuildKit
import RemoteDevCore

#if os(macOS)
@Suite("BuildManager DataRace")
struct BuildManagerDataRaceTests {

    // MARK: - Unit: concurrent closure swap + state reads

    @Test("concurrent read/write of closures and state doesn't crash")
    func concurrentClosureSwapAndStateRead() async {
        let bm = BuildManager()

        await withTaskGroup(of: Void.self) { group in
            // Writers: swap closures (simulates PipelineExecutor callback restore)
            for _ in 0..<500 {
                group.addTask {
                    bm.onOutput = { _ in }
                    bm.onStatusChange = { _, _, _, _ in }
                }
            }
            // Readers: read state (simulates AgentService buildReplay)
            for _ in 0..<500 {
                group.addTask {
                    _ = bm.buildReplayInfo()
                    _ = bm.isRunning
                    _ = bm.lastStatus
                    _ = bm.lastMessage
                    _ = bm.lastAction
                    _ = bm.lastBranch
                    _ = bm.lastCommit
                    _ = bm.onOutput
                    _ = bm.onStatusChange
                }
            }
        }
        // Reaching here without crash = lock protection works
    }

    // MARK: - Integration: concurrent cancel + state reads + callback swaps

    @Test("concurrent cancel, state reads, and callback swaps don't crash")
    func concurrentCancelAndReads() async {
        let bm = BuildManager()
        bm.onStatusChange = { _, _, _, _ in }
        bm.onOutput = { _ in }

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<200 {
                group.addTask { bm.cancel() }
            }
            for _ in 0..<200 {
                group.addTask { _ = bm.buildReplayInfo() }
            }
            for _ in 0..<200 {
                group.addTask {
                    bm.onStatusChange = { _, _, _, _ in }
                    bm.onOutput = { _ in }
                    bm.ascConfigState = .disabled
                }
            }
            for _ in 0..<200 {
                group.addTask {
                    _ = bm.ascConfigState
                    _ = bm.resolvedASCCredentials()
                }
            }
        }
    }
}

@Suite("PipelineExecutor DataRace")
struct PipelineExecutorDataRaceTests {

    // MARK: - Unit: concurrent state reads during cancel

    @Test("concurrent state reads during cancel don't crash")
    func concurrentStateReadsDuringCancel() async {
        let bm = BuildManager()
        let pe = PipelineExecutor(buildManager: bm)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<500 {
                group.addTask { pe.cancel() }
            }
            for _ in 0..<500 {
                group.addTask {
                    _ = pe.isPipelineRunning
                    _ = pe.pipelineSteps
                    _ = pe.pipelineCurrentIndex
                    _ = pe.currentStepStatuses
                }
            }
        }
    }

    // MARK: - Integration: cancel a running script pipeline

    @Test("cancel during running script pipeline doesn't crash")
    func cancelDuringRunningPipeline() async throws {
        let bm = BuildManager()
        let pe = PipelineExecutor(buildManager: bm)

        let config = PipelineConfig(steps: [
            "build": PipelineStep(tasks: [
                PipelineTask(id: "t1", type: .script, label: "slow",
                             path: "sleep 10", enabled: true)
            ])
        ])

        let pipelineFinished: Bool = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                pe.runPipeline(steps: ["build"], config: config, workDir: "/tmp", params: nil)
                continuation.resume(returning: true)
            }

            // Let the script process start, then cancel
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
                pe.cancel()
            }
        }

        #expect(pipelineFinished, "Pipeline should finish after cancel")
        #expect(pe.isPipelineRunning == false)
    }
}
#endif
