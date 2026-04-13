import Foundation
import RemoteDevCore

#if os(macOS)

/// IPC protocol version. Bump when making breaking changes to HelperRequest/HelperMessage.
public let ipcProtocolVersion: Int = 1

// MARK: - Session detail (full metadata returned by helper)

public struct SessionDetail: Codable, Sendable {
    public let sessionId: String
    public let name: String
    public let cols: Int
    public let rows: Int
    public let cwd: String?
    public let workDir: String?
    public let sessionType: SessionType
    public let parentSessionId: String?
    public let branchName: String?
    public let parentRepoPath: String?
    public let parentBranchName: String?

    public init(sessionId: String, name: String, cols: Int, rows: Int,
                cwd: String?, workDir: String?, sessionType: SessionType,
                parentSessionId: String?, branchName: String?,
                parentRepoPath: String?, parentBranchName: String?) {
        self.sessionId = sessionId
        self.name = name
        self.cols = cols
        self.rows = rows
        self.cwd = cwd
        self.workDir = workDir
        self.sessionType = sessionType
        self.parentSessionId = parentSessionId
        self.branchName = branchName
        self.parentRepoPath = parentRepoPath
        self.parentBranchName = parentBranchName
    }
}

// MARK: - IPC request/response envelopes

public struct IPCRequest: Codable {
    public let id: UInt64
    public let request: HelperRequest

    public init(id: UInt64, request: HelperRequest) {
        self.id = id
        self.request = request
    }
}

public struct IPCResponse: Codable {
    public let id: UInt64?
    public let message: HelperMessage

    public init(id: UInt64?, message: HelperMessage) {
        self.id = id
        self.message = message
    }
}

// MARK: - Main → Helper requests

public enum HelperRequest: Codable {
    case createSession(sessionId: String, name: String, cols: Int, rows: Int,
                       workDir: String?, sessionType: String?,
                       parentSessionId: String?, branchName: String?,
                       parentRepoPath: String?, parentBranchName: String?)
    case destroySession(sessionId: String)
    case destroyAll
    case writeInput(sessionId: String, data: Data)
    case resize(sessionId: String, cols: Int, rows: Int)
    case rename(sessionId: String, name: String)
    case updateCwd(sessionId: String, directory: String)
    case updateSessionType(sessionId: String, type: String, branchName: String?)
    case updateSessionParent(sessionId: String, parentSessionId: String?,
                             parentRepoPath: String?, parentBranchName: String?)
    case switchToBufferOnly
    case switchToLive
    case replayRequest(sessionId: String, sinceOffset: UInt64?)
    case replayDrain(sessionId: String)
    case currentOffset(sessionId: String)
    case listSessions
    case ping
    case shutdown
    case version
    // fd passing: CLI requests PTY master fd for zero-latency direct I/O
    case requestPtyFd(sessionId: String)
    case teeOutput(sessionId: String, data: Data, offset: UInt64)
    case releasePtyFd(sessionId: String)
    case updateMaxSessions(maxSessions: Int)
}

// MARK: - Helper → Main responses/events

public enum HelperMessage: Codable {
    // Responses
    case ok
    /// Returned by HelperClient when IPC communication with pty-helper fails.
    /// Never sent over the wire — purely a client-side sentinel.
    case ipcError(String)
    case createResult(sessionId: String, success: Bool, error: String?)
    case replayResult(sessionId: String, data: Data, currentOffset: UInt64, isFull: Bool)
    case drainResult(sessionId: String, data: Data)
    case offsetResult(sessionId: String, offset: UInt64)
    case sessionList(sessions: [SessionDetail])
    case pong
    case versionResult(version: Int)
    // Unsolicited events
    case ptyOutput(sessionId: String, data: Data, offset: UInt64)
    case sessionExited(sessionId: String)
    // fd passing: confirms master fd sent via SCM_RIGHTS ancillary data
    case ptyFdReady(sessionId: String)
}

// MARK: - Length-prefixed framing

public enum IPCFraming {
    /// Write a length-prefixed JSON frame to a file descriptor.
    public static func writeFrame<T: Encodable>(_ value: T, to fd: Int32) throws {
        let data = try JSONEncoder().encode(value)
        var length = UInt32(data.count).bigEndian
        let header = Data(bytes: &length, count: 4)

        let combined = header + data
        try combined.withUnsafeBytes { buf in
            var totalWritten = 0
            while totalWritten < buf.count {
                let ptr = buf.baseAddress!.advanced(by: totalWritten)
                let remaining = buf.count - totalWritten
                let n = Darwin.write(fd, ptr, remaining)
                if n > 0 {
                    totalWritten += n
                } else if n < 0 {
                    if errno == EINTR { continue }
                    throw IPCError.writeFailed(errno)
                } else {
                    throw IPCError.connectionClosed
                }
            }
        }
    }

    /// Read exactly `count` bytes from fd into `buffer` starting at `offset`.
    /// Returns false on EOF before any bytes read (only when offset == 0).
    private static func readExact(fd: Int32, buffer: UnsafeMutablePointer<UInt8>, count: Int) throws -> Bool {
        var offset = 0
        while offset < count {
            let n = Darwin.read(fd, buffer.advanced(by: offset), count - offset)
            if n > 0 {
                offset += n
            } else if n == 0 {
                if offset == 0 { return false }  // clean EOF
                throw IPCError.connectionClosed
            } else {
                if errno == EINTR || errno == EAGAIN { continue }
                throw IPCError.readFailed(errno)
            }
        }
        return true
    }

    /// Read a length-prefixed JSON frame from a file descriptor.
    /// Returns nil on EOF.
    public static func readFrame<T: Decodable>(_ type: T.Type, from fd: Int32) throws -> T? {
        // Read 4-byte length header
        var headerBuf = [UInt8](repeating: 0, count: 4)
        let gotHeader = try headerBuf.withUnsafeMutableBufferPointer { ptr in
            try readExact(fd: fd, buffer: ptr.baseAddress!, count: 4)
        }
        guard gotHeader else { return nil }

        let length = Int(UInt32(bigEndian: headerBuf.withUnsafeBytes { $0.load(as: UInt32.self) }))
        guard length > 0, length < 10_000_000 else {
            throw IPCError.invalidFrameLength(length)
        }

        // Read payload
        var payload = [UInt8](repeating: 0, count: length)
        try payload.withUnsafeMutableBufferPointer { ptr in
            let ok = try readExact(fd: fd, buffer: ptr.baseAddress!, count: length)
            if !ok { throw IPCError.connectionClosed }
        }

        return try JSONDecoder().decode(type, from: Data(payload))
    }

    public enum IPCError: Error {
        case writeFailed(Int32)
        case readFailed(Int32)
        case connectionClosed
        case invalidFrameLength(Int)
    }
}

#endif
