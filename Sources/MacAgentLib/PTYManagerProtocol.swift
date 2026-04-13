import Foundation
import RemoteDevCore

#if os(macOS)
/// Protocol abstracting PTYManager's public API so that AgentService
/// can talk to either an in-process PTYManager or a remote HelperClient.
public protocol PTYManagerProtocol: AnyObject, Sendable {
    var onOutput: ((String, Data) -> Void)? { get set }
    var onSessionExited: ((String) -> Void)? { get set }
    var workDir: String? { get set }
    var isEmpty: Bool { get }
    var sessionCount: Int { get }
    var maxSessions: Int { get }
    func updateMaxSessions(_ newMax: Int)

    @discardableResult
    func createSession(sessionId: String, name: String, cols: Int, rows: Int,
                       sessionWorkDir: String?, sessionType: SessionType,
                       parentSessionId: String?, branchName: String?,
                       parentRepoPath: String?, parentBranchName: String?) -> (success: Bool, error: String?)

    func write(_ data: Data, to sessionId: String)
    func resize(sessionId: String, cols: Int, rows: Int)
    func updateCwd(sessionId: String, directory: String)
    func getCwd(sessionId: String) -> String?
    func rename(sessionId: String, name: String)
    func destroy(sessionId: String)
    func destroyAll()

    func drainReplay(sessionId: String) -> Data
    func replayIncremental(sessionId: String, sinceOffset: UInt64?) -> (data: Data, currentOffset: UInt64, isFull: Bool)
    func currentOffset(sessionId: String) -> UInt64

    func sessionInfoList() -> [PTYSessionInfo]
    func slavePath(for sessionId: String) -> String?
    func getWorkDir(sessionId: String) -> String?
    func getParentRepoPath(sessionId: String) -> String?
    func getParentBranchName(sessionId: String) -> String?
    func getSize(sessionId: String) -> (cols: Int, rows: Int)
    func getSessionType(sessionId: String) -> SessionType
    func getParentSessionId(sessionId: String) -> String?
    func getBranchName(sessionId: String) -> String?
    func updateSessionType(sessionId: String, type: SessionType, branchName: String?)
    func updateSessionParent(sessionId: String, parentSessionId: String?,
                             parentRepoPath: String?, parentBranchName: String?)
    func hasSession(_ sessionId: String) -> Bool

    func switchToBufferOnly()
    func switchToLive()
    func defaultSessionId() -> String?
}
#endif
