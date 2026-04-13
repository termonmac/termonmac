import Foundation
import RemoteDevCore

#if os(macOS)

/// Who currently controls a PTY session's I/O.
public enum SessionController: String, Codable, Sendable {
    case ios
    case mac
    case none
}

/// Session info returned by the local socket, including controller.
public struct LocalSessionInfo: Codable, Sendable {
    public let sessionId: String
    public let name: String
    public let cols: Int
    public let rows: Int
    public let sessionType: SessionType?
    public let cwd: String?
    public let controller: SessionController
    public let slavePath: String?

    public init(sessionId: String, name: String, cols: Int, rows: Int,
                sessionType: SessionType? = nil, cwd: String? = nil,
                controller: SessionController = .none, slavePath: String? = nil) {
        self.sessionId = sessionId
        self.name = name
        self.cols = cols
        self.rows = rows
        self.sessionType = sessionType
        self.cwd = cwd
        self.controller = controller
        self.slavePath = slavePath
    }
}

// MARK: - Local IPC request/response envelopes

public struct LocalIPC {
    public struct Request: Codable {
        public let id: UInt64
        public let message: RequestMessage

        public init(id: UInt64, message: RequestMessage) {
            self.id = id
            self.message = message
        }
    }

    public struct Response: Codable {
        public let id: UInt64?
        public let message: ResponseMessage

        public init(id: UInt64?, message: ResponseMessage) {
            self.id = id
            self.message = message
        }
    }

    // MARK: - CLI → AgentService requests

    public enum RequestMessage: Codable {
        case listSessions
        case createSession(name: String, cols: Int, rows: Int, workDir: String)
        case attach(sessionId: String)
        case input(sessionId: String, data: Data)
        case resize(sessionId: String, cols: Int, rows: Int)
        case detach
        case forceDetach(sessionId: String)
        case killSession(sessionId: String)
        case renameSession(sessionId: String, name: String)
    }

    // MARK: - AgentService → CLI responses/events

    public enum ResponseMessage: Codable {
        // Responses
        case sessionList(sessions: [LocalSessionInfo])
        case createSessionResult(sessionId: String?, error: String?)
        case attachResult(success: Bool, error: String?, helperSocketPath: String? = nil)
        case ok
        // Unsolicited events (pushed to attached client)
        case output(sessionId: String, data: Data)
        case sessionExited(sessionId: String)
        case takenOver(sessionId: String)
        case sessionRenamed(sessionId: String, newName: String)
    }
}

#endif
