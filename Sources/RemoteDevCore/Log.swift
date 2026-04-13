import Foundation
import OSLog

public let logSubsystem = "com.termonmac.agent"

private var currentLogger = Logger(subsystem: logSubsystem, category: "general")

/// Set the OSLog category to the room ID so logs from different instances can be filtered.
public func configureLogCategory(_ category: String) {
    currentLogger = Logger(subsystem: logSubsystem, category: category)
}

public func log(_ message: String) {
    currentLogger.notice("\(message, privacy: .public)")
}
