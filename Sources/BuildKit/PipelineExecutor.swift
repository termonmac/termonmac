import Foundation
import RemoteDevCore

#if os(macOS)
public final class PipelineExecutor: @unchecked Sendable {
    public var onOutput: ((Data) -> Void)?
    public var onStatusChange: ((String, String, String?, String?, String?, [String]?, Int?) -> Void)?
    public var onStateChange: ((PipelineState) -> Void)?

    // Thread-safe pipeline state
    private let lock = NSLock()
    private var _isPipelineRunning = false
    private var _pipelineSteps: [String] = []
    private var _pipelineCurrentIndex: Int = 0
    private var _currentStepStatuses: [String: String] = [:]
    private var _cancelled = false
    private var _currentProcess: Process?

    public var isPipelineRunning: Bool { lock.lock(); defer { lock.unlock() }; return _isPipelineRunning }
    public var pipelineSteps: [String] { lock.lock(); defer { lock.unlock() }; return _pipelineSteps }
    public var pipelineCurrentIndex: Int { lock.lock(); defer { lock.unlock() }; return _pipelineCurrentIndex }
    public var currentStepStatuses: [String: String] { lock.lock(); defer { lock.unlock() }; return _currentStepStatuses }

    /// Must be called with lock held.
    private var _activePipelineSteps: [String]? { _isPipelineRunning ? _pipelineSteps : nil }
    private var _activePipelineIndex: Int? { _isPipelineRunning ? _pipelineCurrentIndex : nil }

    private func _makeState(steps: [String], currentIndex: Int, overallStatus: String) -> PipelineState {
        PipelineState(steps: steps, currentIndex: currentIndex, overallStatus: overallStatus, stepStatuses: _currentStepStatuses)
    }

    private let buildManager: BuildManager

    public init(buildManager: BuildManager) {
        self.buildManager = buildManager
    }

    /// Run all enabled tasks in a pipeline step sequentially.
    public func runStep(
        step: String,
        tasks: [PipelineTask],
        workDir: String,
        params: [String: String]?
    ) {
        lock.lock()
        _cancelled = false
        lock.unlock()

        let enabledTasks = tasks.filter(\.enabled)
        let stepActionMap = ["build": "build", "archive": "archive", "upload": "exportUpload"]
        let action = stepActionMap[step] ?? (params?["action"] ?? step)
        guard !enabledTasks.isEmpty else {
            lock.lock()
            let steps = _activePipelineSteps
            let index = _activePipelineIndex
            lock.unlock()
            onStatusChange?("succeeded", "No tasks to run for step '\(step)'", nil, nil, action, steps, index)
            return
        }

        let scheme = params?["scheme"] ?? ""
        let configuration = params?["configuration"]
        let sdk = params?["sdk"]?.nilIfEmpty
        let teamId = params?["teamId"]

        do {
            lock.lock()
            let steps = _activePipelineSteps
            let index = _activePipelineIndex
            lock.unlock()
            onStatusChange?("running", "Pipeline step: \(step)", nil, nil, action, steps, index)
        }

        for task in enabledTasks {
            lock.lock()
            let isCancelled = _cancelled
            lock.unlock()
            guard !isCancelled else {
                lock.lock()
                let steps = _activePipelineSteps
                let index = _activePipelineIndex
                lock.unlock()
                onStatusChange?("cancelled", "Pipeline cancelled", nil, nil, action, steps, index)
                return
            }

            switch task.type {
            case .builtin:
                runBuiltin(task: task, workDir: workDir, scheme: scheme, action: action, configuration: configuration, sdk: sdk, teamId: teamId)
            case .script:
                runScript(task: task, workDir: workDir)
            }

            // Check if built-in task failed
            lock.lock()
            let cancelled = _cancelled
            lock.unlock()
            if cancelled { return }
        }
    }

    /// Run a full pipeline: iterate steps, mapping each to a build action.
    public func runPipeline(steps: [String], config: PipelineConfig, workDir: String, params: [String: String]?) {
        lock.lock()
        _cancelled = false
        _isPipelineRunning = true
        _pipelineSteps = steps
        _pipelineCurrentIndex = 0
        _currentStepStatuses = Dictionary(uniqueKeysWithValues: steps.map { ($0, "pending") })
        let initialState = _makeState(steps: steps, currentIndex: 0, overallStatus: "running")
        lock.unlock()
        onStateChange?(initialState)

        let stepActionMap = ["build": "build", "archive": "archive", "upload": "exportUpload"]

        for (index, step) in steps.enumerated() {
            lock.lock()
            if _cancelled {
                _currentStepStatuses[step] = "cancelled"
                let state = _makeState(steps: steps, currentIndex: index, overallStatus: "cancelled")
                lock.unlock()
                onStateChange?(state)
                onStatusChange?("cancelled", "Pipeline cancelled", nil, nil, nil, nil, nil)
                break
            }
            _pipelineCurrentIndex = index
            _currentStepStatuses[step] = "running"
            let state = _makeState(steps: steps, currentIndex: index, overallStatus: "running")
            lock.unlock()
            onStateChange?(state)

            let action = stepActionMap[step] ?? step

            // Check if this step has a pipeline config with custom tasks
            if let stepConfig = config.steps[step], !stepConfig.tasks.isEmpty {
                let enabledTasks = stepConfig.tasks.filter(\.enabled)
                if !enabledTasks.isEmpty {
                    var stepParams = params ?? [:]
                    stepParams["action"] = action
                    runStep(step: step, tasks: enabledTasks, workDir: workDir, params: stepParams)
                    lock.lock()
                    if _cancelled {
                        _currentStepStatuses[step] = "failed"
                        let failState = _makeState(steps: steps, currentIndex: index, overallStatus: "failed")
                        lock.unlock()
                        onStateChange?(failState)
                        break
                    }
                    _currentStepStatuses[step] = "succeeded"
                    let okState = _makeState(steps: steps, currentIndex: index, overallStatus: "running")
                    lock.unlock()
                    onStateChange?(okState)
                    continue
                }
            }

            // Default: use builtin build action
            let scheme = params?["scheme"] ?? ""
            let configuration = params?["configuration"]
            let sdk = params?["sdk"]?.nilIfEmpty
            let teamId = params?["teamId"]
            let projectPath = params?["projectPath"]

            onStatusChange?("running", "Pipeline step: \(step)", nil, nil, action, steps, index)

            let sem = DispatchSemaphore(value: 0)
            var buildSucceeded = false

            let prevStatusChange = buildManager.onStatusChange
            let prevOutput = buildManager.onOutput

            buildManager.onOutput = { [weak self] data in
                self?.onOutput?(data)
            }
            buildManager.onStatusChange = { [weak self] status, message, branch, commit in
                guard let self else { return }
                self.onStatusChange?(status, message, branch, commit, action, steps, index)
                if status != "running" {
                    buildSucceeded = (status == "succeeded")
                    sem.signal()
                }
            }

            do {
                if let projectPath, !projectPath.isEmpty {
                    try buildManager.startBuildInProject(scheme: scheme, action: action, configuration: configuration, sdk: sdk, teamId: teamId, projectPath: projectPath)
                } else {
                    try buildManager.startBuild(scheme: scheme, action: action, configuration: configuration, sdk: sdk, teamId: teamId, workDir: workDir)
                }
            } catch {
                lock.lock()
                _currentStepStatuses[step] = "failed"
                let failState = _makeState(steps: steps, currentIndex: index, overallStatus: "failed")
                _cancelled = true
                lock.unlock()
                onStateChange?(failState)
                onStatusChange?("failed", "Pipeline step '\(step)' failed: \(error.localizedDescription)", nil, nil, action, steps, index)
                buildManager.onStatusChange = prevStatusChange
                buildManager.onOutput = prevOutput
                break
            }

            sem.wait()
            buildManager.onStatusChange = prevStatusChange
            buildManager.onOutput = prevOutput

            if !buildSucceeded {
                lock.lock()
                _currentStepStatuses[step] = "failed"
                let failState = _makeState(steps: steps, currentIndex: index, overallStatus: "failed")
                _cancelled = true
                lock.unlock()
                onStateChange?(failState)
                break
            }
            lock.lock()
            _currentStepStatuses[step] = "succeeded"
            let okState = _makeState(steps: steps, currentIndex: index, overallStatus: "running")
            lock.unlock()
            onStateChange?(okState)
        }

        lock.lock()
        if !_cancelled {
            let finalState = _makeState(steps: steps, currentIndex: steps.count - 1, overallStatus: "succeeded")
            _isPipelineRunning = false
            lock.unlock()
            onStateChange?(finalState)
        } else {
            _isPipelineRunning = false
            lock.unlock()
        }
    }

    public func cancel() {
        lock.lock()
        _cancelled = true
        var state: PipelineState?
        if _isPipelineRunning {
            if _pipelineCurrentIndex < _pipelineSteps.count {
                _currentStepStatuses[_pipelineSteps[_pipelineCurrentIndex]] = "cancelled"
            }
            state = _makeState(steps: _pipelineSteps, currentIndex: _pipelineCurrentIndex, overallStatus: "cancelled")
        }
        _isPipelineRunning = false
        let proc = _currentProcess
        _currentProcess = nil
        lock.unlock()
        if let state { onStateChange?(state) }
        proc?.terminate()
        buildManager.cancel()
    }

    // MARK: - Private

    private func runBuiltin(task: PipelineTask, workDir: String, scheme: String, action: String, configuration: String?, sdk: String?, teamId: String?, projectPath: String? = nil) {
        guard let builtin = task.builtin else { return }

        // Use a semaphore to wait for async BuildManager callbacks
        let sem = DispatchSemaphore(value: 0)
        var buildSucceeded = false

        let prevStatusChange = buildManager.onStatusChange
        let prevOutput = buildManager.onOutput

        buildManager.onOutput = { [weak self] data in
            self?.onOutput?(data)
        }
        buildManager.onStatusChange = { [weak self] status, message, branch, commit in
            guard let self else { return }
            self.lock.lock()
            let steps = self._activePipelineSteps
            let index = self._activePipelineIndex
            self.lock.unlock()
            self.onStatusChange?(status, message, branch, commit, action, steps, index)
            if status != "running" {
                buildSucceeded = (status == "succeeded")
                sem.signal()
            }
        }

        let useProject = projectPath != nil && !projectPath!.isEmpty

        do {
            switch builtin {
            case "xcode-list-schemes":
                let result = try buildManager.listSchemes(workDir: workDir)
                lock.lock()
                let steps = _activePipelineSteps
                let index = _activePipelineIndex
                lock.unlock()
                onStatusChange?("succeeded", "Found \(result.schemes.count) schemes", nil, nil, nil, steps, index)
                // Restore callbacks
                buildManager.onStatusChange = prevStatusChange
                buildManager.onOutput = prevOutput
                return

            case "xcode-build":
                if useProject {
                    try buildManager.startBuildInProject(scheme: scheme, action: "build", configuration: configuration, sdk: sdk, teamId: teamId, projectPath: projectPath!)
                } else {
                    try buildManager.startBuild(scheme: scheme, action: "build", configuration: configuration, sdk: sdk, teamId: teamId, workDir: workDir)
                }

            case "xcode-archive":
                if useProject {
                    try buildManager.startBuildInProject(scheme: scheme, action: "archive", configuration: configuration, sdk: sdk, teamId: teamId, projectPath: projectPath!)
                } else {
                    try buildManager.startBuild(scheme: scheme, action: "archive", configuration: configuration, sdk: sdk, teamId: teamId, workDir: workDir)
                }

            case "xcode-upload":
                if useProject {
                    try buildManager.startBuildInProject(scheme: scheme, action: "exportUpload", configuration: configuration, sdk: sdk, teamId: teamId, projectPath: projectPath!)
                } else {
                    try buildManager.startBuild(scheme: scheme, action: "exportUpload", configuration: configuration, sdk: sdk, teamId: teamId, workDir: workDir)
                }

            default:
                lock.lock()
                let steps = _activePipelineSteps
                let index = _activePipelineIndex
                lock.unlock()
                onStatusChange?("failed", "Unknown builtin task: \(builtin)", nil, nil, nil, steps, index)
                buildManager.onStatusChange = prevStatusChange
                buildManager.onOutput = prevOutput
                return
            }
        } catch {
            lock.lock()
            let steps = _activePipelineSteps
            let index = _activePipelineIndex
            _cancelled = true
            lock.unlock()
            onStatusChange?("failed", "Task '\(task.label)' failed: \(error.localizedDescription)", nil, nil, nil, steps, index)
            buildManager.onStatusChange = prevStatusChange
            buildManager.onOutput = prevOutput
            return
        }

        // Wait for build to finish
        sem.wait()

        // Restore callbacks
        buildManager.onStatusChange = prevStatusChange
        buildManager.onOutput = prevOutput

        if !buildSucceeded {
            lock.lock()
            _cancelled = true
            lock.unlock()
        }
    }

    private func runScript(task: PipelineTask, workDir: String) {
        guard let scriptPath = task.path else {
            lock.lock()
            let steps = _activePipelineSteps
            let index = _activePipelineIndex
            _cancelled = true
            lock.unlock()
            onStatusChange?("failed", "Script task '\(task.label)' has no path", nil, nil, nil, steps, index)
            return
        }

        onOutput?(Data("=== Running script: \(task.label) ===\n".utf8))

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = ["-c", scriptPath] + (task.args ?? [])
        proc.currentDirectoryURL = URL(fileURLWithPath: workDir)

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        proc.standardInput = FileHandle.nullDevice

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if !data.isEmpty { self?.onOutput?(data) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if !data.isEmpty { self?.onOutput?(data) }
        }

        lock.lock()
        _currentProcess = proc
        lock.unlock()

        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            lock.lock()
            let steps = _activePipelineSteps
            let index = _activePipelineIndex
            _cancelled = true
            _currentProcess = nil
            lock.unlock()
            onStatusChange?("failed", "Script '\(task.label)' failed to start: \(error.localizedDescription)", nil, nil, nil, steps, index)
            return
        }

        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil

        lock.lock()
        _currentProcess = nil
        lock.unlock()

        if proc.terminationStatus != 0 {
            lock.lock()
            let steps = _activePipelineSteps
            let index = _activePipelineIndex
            _cancelled = true
            lock.unlock()
            onStatusChange?("failed", "Script '\(task.label)' failed (exit \(proc.terminationStatus))", nil, nil, nil, steps, index)
        }
    }
}
#endif
