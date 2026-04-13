import Testing
import Foundation
@testable import BuildKit
import RemoteDevCore

#if os(macOS)

/// Thread-safe accumulator for collecting values from callbacks on arbitrary queues.
private final class Accumulator<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [T] = []

    func append(_ value: T) {
        lock.lock()
        _values.append(value)
        lock.unlock()
    }

    var values: [T] {
        lock.lock()
        defer { lock.unlock() }
        return _values
    }
}

@Suite("PipelineExecutor")
struct PipelineExecutorTests {

    // MARK: - Helpers

    private func makeExecutor() -> PipelineExecutor {
        PipelineExecutor(buildManager: BuildManager())
    }

    private func scriptTask(_ label: String, path: String, enabled: Bool = true) -> PipelineTask {
        PipelineTask(id: UUID().uuidString, type: .script, label: label, path: path, enabled: enabled)
    }

    private func disabledBuiltinTask(_ label: String) -> PipelineTask {
        PipelineTask(id: UUID().uuidString, type: .builtin, label: label, builtin: "xcode-build", enabled: false)
    }

    // MARK: - runStep

    @Test("runStep with no enabled tasks reports succeeded")
    func runStepNoEnabledTasks() {
        let executor = makeExecutor()
        var reportedStatus = ""

        executor.onStatusChange = { status, message, _, _, _, _, _ in
            reportedStatus = status
        }

        let disabledTask = disabledBuiltinTask("Disabled")
        executor.runStep(step: "build", tasks: [disabledTask], workDir: "/tmp", params: nil)

        #expect(reportedStatus == "succeeded")
    }

    @Test("runStep with script task executes and captures output")
    func runStepScriptTask() {
        let executor = makeExecutor()
        let outputAcc = Accumulator<Data>()
        let statusAcc = Accumulator<String>()

        executor.onOutput = { data in
            outputAcc.append(data)
        }
        executor.onStatusChange = { status, _, _, _, _, _, _ in
            statusAcc.append(status)
        }

        let task = scriptTask("Echo Test", path: "echo 'pipeline-test-output'")
        executor.runStep(step: "test", tasks: [task], workDir: "/tmp", params: nil)

        let combined = outputAcc.values.reduce(Data(), +)
        let output = String(data: combined, encoding: .utf8) ?? ""
        #expect(output.contains("pipeline-test-output"))
        #expect(statusAcc.values.contains("running"))
    }

    @Test("runStep with failing script task reports failure")
    func runStepFailingScript() {
        let executor = makeExecutor()
        let statusAcc = Accumulator<String>()

        executor.onStatusChange = { status, _, _, _, _, _, _ in
            statusAcc.append(status)
        }

        let task = scriptTask("Fail", path: "exit 1")
        executor.runStep(step: "test", tasks: [task], workDir: "/tmp", params: nil)

        #expect(statusAcc.values.contains("failed"))
    }

    @Test("runStep with script task that has no path reports failure")
    func runStepScriptNoPath() {
        let executor = makeExecutor()
        let statusAcc = Accumulator<String>()

        executor.onStatusChange = { status, _, _, _, _, _, _ in
            statusAcc.append(status)
        }

        // Script task with nil path
        let task = PipelineTask(id: "no-path", type: .script, label: "No Path", path: nil, enabled: true)
        executor.runStep(step: "test", tasks: [task], workDir: "/tmp", params: nil)

        #expect(statusAcc.values.contains("failed"))
    }

    // MARK: - cancel

    @Test("cancel sets isPipelineRunning to false")
    func cancelSetsFalse() {
        let executor = makeExecutor()
        // Start a pipeline in the background to set isPipelineRunning = true
        #expect(executor.isPipelineRunning == false)
        executor.cancel()
        #expect(executor.isPipelineRunning == false)
    }

    // MARK: - runPipeline with script tasks

    @Test("runPipeline with single script step tracks state transitions")
    func runPipelineSingleStep() {
        let executor = makeExecutor()
        let stateAcc = Accumulator<PipelineState>()
        let statusAcc = Accumulator<String>()

        executor.onStateChange = { state in
            stateAcc.append(state)
        }
        executor.onStatusChange = { status, _, _, _, _, _, _ in
            statusAcc.append(status)
        }

        let config = PipelineConfig(steps: [
            "test": PipelineStep(tasks: [
                scriptTask("Echo", path: "echo 'hello'")
            ])
        ])

        executor.runPipeline(steps: ["test"], config: config, workDir: "/tmp", params: nil)

        // Should have state transitions: running → succeeded
        let states = stateAcc.values
        #expect(!states.isEmpty)
        #expect(states.last?.overallStatus == "succeeded")
        #expect(states.last?.stepStatuses["test"] == "succeeded")
        #expect(executor.isPipelineRunning == false)
    }

    @Test("runPipeline with multiple script steps tracks all step statuses")
    func runPipelineMultipleSteps() {
        let executor = makeExecutor()
        let stateAcc = Accumulator<PipelineState>()

        executor.onStateChange = { state in
            stateAcc.append(state)
        }
        executor.onStatusChange = { _, _, _, _, _, _, _ in }

        let config = PipelineConfig(steps: [
            "step1": PipelineStep(tasks: [scriptTask("S1", path: "echo 'step1'")]),
            "step2": PipelineStep(tasks: [scriptTask("S2", path: "echo 'step2'")]),
        ])

        executor.runPipeline(steps: ["step1", "step2"], config: config, workDir: "/tmp", params: nil)

        let states = stateAcc.values
        let finalState = states.last!
        #expect(finalState.overallStatus == "succeeded")
        #expect(finalState.stepStatuses["step1"] == "succeeded")
        #expect(finalState.stepStatuses["step2"] == "succeeded")
    }

    @Test("runPipeline stops at first failed step")
    func runPipelineStopsAtFailure() {
        let executor = makeExecutor()
        let stateAcc = Accumulator<PipelineState>()

        executor.onStateChange = { state in
            stateAcc.append(state)
        }
        executor.onStatusChange = { _, _, _, _, _, _, _ in }

        let config = PipelineConfig(steps: [
            "good": PipelineStep(tasks: [scriptTask("Pass", path: "echo 'ok'")]),
            "bad": PipelineStep(tasks: [scriptTask("Fail", path: "exit 1")]),
            "after": PipelineStep(tasks: [scriptTask("Never", path: "echo 'should not run'")]),
        ])

        executor.runPipeline(steps: ["good", "bad", "after"], config: config, workDir: "/tmp", params: nil)

        let states = stateAcc.values
        let finalState = states.last!
        #expect(finalState.overallStatus == "failed")
        #expect(finalState.stepStatuses["good"] == "succeeded")
        #expect(finalState.stepStatuses["bad"] == "failed")
        // "after" should remain pending since pipeline stopped
        #expect(finalState.stepStatuses["after"] == "pending")
    }

    @Test("runPipeline initial state has all steps as pending")
    func runPipelineInitialState() {
        let executor = makeExecutor()
        let stateAcc = Accumulator<PipelineState>()

        executor.onStateChange = { state in
            stateAcc.append(state)
        }
        executor.onStatusChange = { _, _, _, _, _, _, _ in }

        let config = PipelineConfig(steps: [
            "a": PipelineStep(tasks: [scriptTask("A", path: "echo a")]),
            "b": PipelineStep(tasks: [scriptTask("B", path: "echo b")]),
        ])

        executor.runPipeline(steps: ["a", "b"], config: config, workDir: "/tmp", params: nil)

        let firstState = stateAcc.values.first
        #expect(firstState != nil)
        #expect(firstState?.overallStatus == "running")
        #expect(firstState?.stepStatuses["a"] == "pending")
        #expect(firstState?.stepStatuses["b"] == "pending")
    }

    @Test("isPipelineRunning is false after pipeline completes")
    func isPipelineRunningFalseAfterComplete() {
        let executor = makeExecutor()
        executor.onStatusChange = { _, _, _, _, _, _, _ in }

        let config = PipelineConfig(steps: [
            "only": PipelineStep(tasks: [scriptTask("T", path: "echo done")])
        ])

        executor.runPipeline(steps: ["only"], config: config, workDir: "/tmp", params: nil)
        #expect(executor.isPipelineRunning == false)
    }

    // MARK: - Thread-safe property access

    @Test("Thread-safe properties are accessible without crash")
    func threadSafeProperties() async {
        let executor = makeExecutor()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<50 {
                group.addTask {
                    _ = executor.isPipelineRunning
                    _ = executor.pipelineSteps
                    _ = executor.pipelineCurrentIndex
                    _ = executor.currentStepStatuses
                }
            }
        }

        // Verify properties are still accessible after concurrent reads
        #expect(executor.isPipelineRunning == false)
    }
}
#endif
