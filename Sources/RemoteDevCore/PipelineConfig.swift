import Foundation

public struct PipelineTask: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var type: TaskType
    public var label: String
    public var builtin: String?
    public var path: String?
    public var args: [String]?
    public var enabled: Bool

    public enum TaskType: String, Codable, Sendable {
        case builtin
        case script
    }

    public init(id: String, type: TaskType, label: String, builtin: String? = nil, path: String? = nil, args: [String]? = nil, enabled: Bool = true) {
        self.id = id
        self.type = type
        self.label = label
        self.builtin = builtin
        self.path = path
        self.args = args
        self.enabled = enabled
    }
}

public struct PipelineStep: Codable, Equatable, Sendable {
    public var tasks: [PipelineTask]

    public init(tasks: [PipelineTask]) {
        self.tasks = tasks
    }
}

public struct PipelineConfig: Codable, Equatable, Sendable {
    public var steps: [String: PipelineStep]

    public static let stepOrder = ["preload", "build", "archive", "upload"]

    public init(steps: [String: PipelineStep] = [:]) {
        self.steps = steps
    }

    public static var `default`: PipelineConfig {
        PipelineConfig(steps: [
            "preload": PipelineStep(tasks: [
                PipelineTask(id: "builtin-list-schemes", type: .builtin, label: "List Schemes", builtin: "xcode-list-schemes")
            ]),
            "build": PipelineStep(tasks: [
                PipelineTask(id: "builtin-build", type: .builtin, label: "Build", builtin: "xcode-build")
            ]),
            "archive": PipelineStep(tasks: [
                PipelineTask(id: "builtin-archive", type: .builtin, label: "Archive", builtin: "xcode-archive")
            ]),
            "upload": PipelineStep(tasks: [
                PipelineTask(id: "builtin-upload", type: .builtin, label: "Export & Upload", builtin: "xcode-upload")
            ]),
        ])
    }
}
