import Foundation

public struct PipelineState: Codable, Equatable {
    public var steps: [String]
    public var currentIndex: Int
    public var overallStatus: String   // "running" | "succeeded" | "failed" | "cancelled"
    public var stepStatuses: [String: String]   // e.g. {"build":"succeeded","archive":"running","upload":"pending"}
    public var timestamp: Date

    public init(steps: [String], currentIndex: Int, overallStatus: String,
                stepStatuses: [String: String]? = nil, timestamp: Date = Date()) {
        self.steps = steps
        self.currentIndex = currentIndex
        self.overallStatus = overallStatus
        self.stepStatuses = stepStatuses ?? Dictionary(uniqueKeysWithValues: steps.map { ($0, "pending") })
        self.timestamp = timestamp
    }
}
