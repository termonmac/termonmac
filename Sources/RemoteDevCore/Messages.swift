import Foundation

// MARK: - Client → Server (relay-level)

public struct RegisterRoomMessage: Encodable {
    public let type = "register_room"
    public let room_id: String
    public let secret_hash: String
    public let public_key: String
    public let session_nonce: String
    public let ephemeral_key: String
    public let pairing_token_hash: String?
    public let pairing_token_expires_at: Int?

    public init(room_id: String, secret_hash: String, public_key: String, session_nonce: String = "",
                ephemeral_key: String = "", pairing_token_hash: String? = nil,
                pairing_token_expires_at: Int? = nil) {
        self.room_id = room_id
        self.secret_hash = secret_hash
        self.public_key = public_key
        self.session_nonce = session_nonce
        self.ephemeral_key = ephemeral_key
        self.pairing_token_hash = pairing_token_hash
        self.pairing_token_expires_at = pairing_token_expires_at
    }
}

public struct JoinRoomMessage: Encodable {
    public let type = "join_room"
    public let room_id: String
    public let public_key: String
    public let secret_hash: String?
    public let session_nonce: String
    public let ephemeral_key: String
    public let pairing_token_hash: String?

    public init(room_id: String, public_key: String, secret_hash: String? = nil, session_nonce: String = "",
                ephemeral_key: String = "", pairing_token_hash: String? = nil) {
        self.room_id = room_id
        self.public_key = public_key
        self.secret_hash = secret_hash
        self.session_nonce = session_nonce
        self.ephemeral_key = ephemeral_key
        self.pairing_token_hash = pairing_token_hash
    }
}

public struct RelayClientMessage: Encodable {
    public let type = "relay"
    public let payload: String

    public init(payload: String) {
        self.payload = payload
    }
}

public struct RelayBatchClientMessage: Encodable {
    public let type = "relay_batch"
    public let payloads: [String]

    public init(payloads: [String]) {
        self.payloads = payloads
    }
}

public struct HeartbeatClientMessage: Encodable {
    public let type = "heartbeat"
    public init() {}
}

// MARK: - Server → Client (relay-level)

public enum ServerMessage {
    case roomRegistered(roomId: String, maxSessions: Int? = nil)
    case peerJoined(publicKey: String, sessionNonce: String, ephemeralKey: String)
    case relay(payload: String)
    case relayBatch(payloads: [String])
    case peerDisconnected(reason: String)
    case heartbeatAck(macConnected: Bool, accountMatch: String?, accountDeleted: Bool?)
    case error(code: String, message: String, macEmail: String?, iosEmail: String?)
    case quotaExceeded(usage: Int, limit: Int, period: String, resetsAt: String,
                       extraQuotaUsed: Int?, extraQuotaLimit: Int?, extraQuotaExpiresAt: String?)
}

extension ServerMessage: Decodable {
    private enum CodingKeys: String, CodingKey {
        case type, room_id, public_key, payload, payloads, reason, code, message, session_nonce, mac_connected, account_match, account_deleted, mac_email, ios_email, usage, limit, period, resets_at, extra_quota_used, extra_quota_limit, extra_quota_expires_at, ephemeral_key, max_sessions
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "room_registered":
            self = .roomRegistered(
                roomId: try c.decode(String.self, forKey: .room_id),
                maxSessions: try c.decodeIfPresent(Int.self, forKey: .max_sessions)
            )
        case "peer_joined":
            self = .peerJoined(
                publicKey: try c.decode(String.self, forKey: .public_key),
                sessionNonce: try c.decodeIfPresent(String.self, forKey: .session_nonce) ?? "",
                ephemeralKey: try c.decodeIfPresent(String.self, forKey: .ephemeral_key) ?? ""
            )
        case "relay":
            self = .relay(payload: try c.decode(String.self, forKey: .payload))
        case "relay_batch":
            self = .relayBatch(payloads: try c.decode([String].self, forKey: .payloads))
        case "peer_disconnected":
            self = .peerDisconnected(reason: try c.decode(String.self, forKey: .reason))
        case "heartbeat_ack":
            self = .heartbeatAck(
                macConnected: try c.decodeIfPresent(Bool.self, forKey: .mac_connected) ?? false,
                accountMatch: try c.decodeIfPresent(String.self, forKey: .account_match),
                accountDeleted: try c.decodeIfPresent(Bool.self, forKey: .account_deleted)
            )
        case "error":
            self = .error(
                code: try c.decode(String.self, forKey: .code),
                message: try c.decode(String.self, forKey: .message),
                macEmail: try c.decodeIfPresent(String.self, forKey: .mac_email),
                iosEmail: try c.decodeIfPresent(String.self, forKey: .ios_email)
            )
        case "quota_exceeded":
            self = .quotaExceeded(
                usage: try c.decode(Int.self, forKey: .usage),
                limit: try c.decode(Int.self, forKey: .limit),
                period: try c.decode(String.self, forKey: .period),
                resetsAt: try c.decode(String.self, forKey: .resets_at),
                extraQuotaUsed: try c.decodeIfPresent(Int.self, forKey: .extra_quota_used),
                extraQuotaLimit: try c.decodeIfPresent(Int.self, forKey: .extra_quota_limit),
                extraQuotaExpiresAt: try c.decodeIfPresent(String.self, forKey: .extra_quota_expires_at)
            )
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown type: \(type)")
        }
    }
}

// MARK: - Session Type

public enum SessionType: String, Codable, Sendable {
    case normal, git, worktree
}

// MARK: - Worktree Directory Layout

public enum WorktreeDirLayout: String, Codable, Sendable, CaseIterable {
    case grouped, sibling, flat
}

// MARK: - Git structs

public struct GitDetectInfo: Codable {
    public let isGitRepo: Bool
    public let isWorktree: Bool
    public let branchName: String?
    public let remoteUrl: String?
    public let repoRootPath: String?

    public init(isGitRepo: Bool, isWorktree: Bool, branchName: String?, remoteUrl: String?, repoRootPath: String?) {
        self.isGitRepo = isGitRepo
        self.isWorktree = isWorktree
        self.branchName = branchName
        self.remoteUrl = remoteUrl
        self.repoRootPath = repoRootPath
    }
}

public struct WorktreeSyncInfo: Codable {
    public let sessionId: String
    public let isSynced: Bool
    public let behindCount: Int
    public let aheadCount: Int

    public init(sessionId: String, isSynced: Bool, behindCount: Int, aheadCount: Int) {
        self.sessionId = sessionId
        self.isSynced = isSynced
        self.behindCount = behindCount
        self.aheadCount = aheadCount
    }
}

public struct WorktreeDirtyState: Codable {
    public let sessionId: String
    public let hasUnstagedChanges: Bool
    public let hasStagedChanges: Bool
    public let hasUntrackedFiles: Bool
    public let isSynced: Bool
    public let behindCount: Int
    public let aheadCount: Int
    public let summary: String
    public let checkFailed: Bool

    public var isDirty: Bool { hasUnstagedChanges || hasStagedChanges }
    public var needsWarning: Bool { isDirty || hasUntrackedFiles || !isSynced || checkFailed }

    public init(sessionId: String, hasUnstagedChanges: Bool, hasStagedChanges: Bool,
                hasUntrackedFiles: Bool, isSynced: Bool, behindCount: Int, aheadCount: Int,
                summary: String, checkFailed: Bool = false) {
        self.sessionId = sessionId
        self.hasUnstagedChanges = hasUnstagedChanges
        self.hasStagedChanges = hasStagedChanges
        self.hasUntrackedFiles = hasUntrackedFiles
        self.isSynced = isSynced
        self.behindCount = behindCount
        self.aheadCount = aheadCount
        self.summary = summary
        self.checkFailed = checkFailed
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try container.decode(String.self, forKey: .sessionId)
        hasUnstagedChanges = try container.decode(Bool.self, forKey: .hasUnstagedChanges)
        hasStagedChanges = try container.decode(Bool.self, forKey: .hasStagedChanges)
        hasUntrackedFiles = try container.decode(Bool.self, forKey: .hasUntrackedFiles)
        isSynced = try container.decode(Bool.self, forKey: .isSynced)
        behindCount = try container.decode(Int.self, forKey: .behindCount)
        aheadCount = try container.decode(Int.self, forKey: .aheadCount)
        summary = try container.decode(String.self, forKey: .summary)
        checkFailed = try container.decodeIfPresent(Bool.self, forKey: .checkFailed) ?? false
    }
}

public struct GitOperationResult: Codable {
    public let success: Bool
    public let message: String
    public let sessionId: String

    public init(success: Bool, message: String, sessionId: String) {
        self.success = success
        self.message = message
        self.sessionId = sessionId
    }
}

// MARK: - PTY Session Info (for multi-session support)

public struct PTYSessionInfo: Codable, Sendable {
    public let sessionId: String
    public let name: String
    public let cols: Int
    public let rows: Int
    public let sessionType: SessionType?
    public let cwd: String?
    public let isMacControlled: Bool?  // true when Mac CLI has attached this session

    public init(sessionId: String, name: String, cols: Int, rows: Int,
                sessionType: SessionType? = nil, cwd: String? = nil,
                isMacControlled: Bool? = nil) {
        self.sessionId = sessionId
        self.name = name
        self.cols = cols
        self.rows = rows
        self.sessionType = sessionType
        self.cwd = cwd
        self.isMacControlled = isMacControlled
    }
}

// MARK: - Room Config (bidirectional sync)

public struct RoomSessionConfig: Codable {
    public var sessionId: String
    public var name: String
    public var selectedTab: Int
    public var sessionType: SessionType?
    public var parentSessionId: String?
    public var worktreeDir: String?
    public var branchName: String?
    public var parentRepoPath: String?
    public var parentBranchName: String?

    public init(sessionId: String, name: String, selectedTab: Int = 0,
                sessionType: SessionType? = nil, parentSessionId: String? = nil,
                worktreeDir: String? = nil, branchName: String? = nil,
                parentRepoPath: String? = nil, parentBranchName: String? = nil) {
        self.sessionId = sessionId
        self.name = name
        self.selectedTab = selectedTab
        self.sessionType = sessionType
        self.parentSessionId = parentSessionId
        self.worktreeDir = worktreeDir
        self.branchName = branchName
        self.parentRepoPath = parentRepoPath
        self.parentBranchName = parentBranchName
    }
}

public struct RoomConfig: Codable {
    public var sessions: [RoomSessionConfig]
    public var activeSessionId: String?

    public init(sessions: [RoomSessionConfig] = [], activeSessionId: String? = nil) {
        self.sessions = sessions
        self.activeSessionId = activeSessionId
    }
}

// MARK: - Input Log

public struct InputLogEntry: Codable, Identifiable {
    public let id: UUID
    public let type: String              // "terminalInput" or "statusDescription"
    public let timestamp: Date
    public var sortOrder: Double
    public var text: String
    public let isControlSequence: Bool

    public init(id: UUID = UUID(), type: String, timestamp: Date = Date(),
                sortOrder: Double? = nil, text: String, isControlSequence: Bool = false) {
        self.id = id
        self.type = type
        self.timestamp = timestamp
        self.sortOrder = sortOrder ?? timestamp.timeIntervalSince1970
        self.text = text
        self.isControlSequence = isControlSequence
    }
}

public struct InputLogData: Codable {
    public let sessionId: String
    public var description: String
    public var entries: [InputLogEntry]

    public init(sessionId: String, description: String = "", entries: [InputLogEntry] = []) {
        self.sessionId = sessionId
        self.description = description
        self.entries = entries
    }
}

// MARK: - App-level (inside encrypted relay payload)

public enum AppMessage {
    case challenge(nonce: String)
    case challengeResponse(hmac: String)
    case authOk
    case pairingCredentials(secret: String)
    case ptyData(data: String, sessionId: String, offset: UInt64? = nil)      // base64-encoded
    case ptyInput(data: String, sessionId: String)     // base64-encoded
    case ptyResize(cols: Int, rows: Int, sessionId: String)
    // PTY session lifecycle
    case ptyCreate(sessionId: String, name: String, cols: Int = 80, rows: Int = 24, workDir: String? = nil)     // iOS → Mac
    case ptyRename(sessionId: String, name: String)    // iOS → Mac
    case ptyDestroy(sessionId: String)                  // iOS → Mac
    case ptyDestroyed(sessionId: String)                // Mac → iOS (process ended)
    case sessionTakenOver(sessionId: String, isTakenOver: Bool) // Mac → iOS (true=Mac took, false=released)
    case ptyCwd(sessionId: String, directory: String)   // iOS → Mac (OSC 7 cwd update)
    case ptySessions(sessions: [PTYSessionInfo])        // Mac → iOS (reconnect)
    // Build: iOS → Mac
    case buildListSchemes(workDir: String? = nil)
    case buildListSchemesForProject(projectPath: String)
    case buildListProjects(workDir: String? = nil)
    case buildStart(scheme: String, action: String, configuration: String?, sdk: String?, teamId: String?, workDir: String? = nil)
    case buildStartInProject(scheme: String, action: String, configuration: String?, sdk: String?, teamId: String?, projectPath: String)
    case buildCancel
    case buildGetSigningInfo(scheme: String, workDir: String? = nil)
    case buildGetSigningInfoForProject(scheme: String, projectPath: String)
    // Build: Mac → iOS
    case buildProjects(projects: [[String: String]])  // [{name, path, type}]
    case buildSchemes(schemes: [String], project: String)
    case buildOutput(data: String)  // base64-encoded log chunk
    case buildStatus(status: String, message: String, branch: String?, commit: String?,
                     action: String? = nil, pipelineSteps: [String]? = nil, pipelineCurrentIndex: Int? = nil)
    case buildSigningInfo(team: String, signingStyle: String, provisioningProfile: String, signingCertificate: String, bundleId: String, ascKeyConfigured: Bool, ascKeyFileExists: Bool, archiveExists: Bool)
    case ptyReady(cols: Int, rows: Int, sessionId: String)  // Mac → iOS: PTY created with these dimensions
    case ptyReplay(data: String, sessionId: String, offset: UInt64? = nil, isFullReplay: Bool? = nil)      // base64-encoded replay data (Mac → iOS)
    case ptyReplayRequest(sessionId: String, offset: UInt64? = nil)             // iOS → Mac, request replay
    case buildReplay(data: String, status: String, message: String, action: String, branch: String?, commit: String?, pipelineSteps: [String]?, pipelineCurrentIndex: Int?, stepStatuses: [String: String]? = nil)

    // Room config sync
    case roomConfig(config: RoomConfig)           // Mac → iOS on connect
    case roomConfigUpdate(config: RoomConfig)     // iOS → Mac on any change
    // Pipeline
    case pipelineConfig(config: PipelineConfig)                                    // Mac → iOS on connect
    case pipelineConfigUpdate(config: PipelineConfig)                              // iOS → Mac on edit
    case pipelineRunStep(step: String, workDir: String?, params: [String: String]?) // iOS → Mac
    case pipelineStart(steps: [String], workDir: String?, params: [String: String]?) // iOS → Mac
    case pipelineCancel                                                            // iOS → Mac
    case pipelineStateQuery                                                        // iOS → Mac
    case pipelineStateResponse(state: PipelineState?)                              // Mac → iOS
    // Git / Worktree: iOS → Mac
    case gitDetectRequest(sessionId: String)
    case worktreeCreate(sessionId: String, name: String, dirLayout: WorktreeDirLayout?)
    case worktreeCloseCheck(sessionId: String)
    case worktreeClose(sessionId: String, merge: Bool, ffOnly: Bool = false)
    case gitMergeCheck(sessionId: String, worktreeSessionId: String)
    case gitMerge(sessionId: String, worktreeSessionId: String, force: Bool = false, ffOnly: Bool = false)
    case gitRebase(sessionId: String)
    case worktreeSyncCheck(sessionId: String)
    // Git / Worktree: Mac → iOS
    case gitDetectResult(sessionId: String, info: GitDetectInfo)
    case worktreeCreateResult(success: Bool, sessionId: String, worktreeSessionId: String?, path: String?, branchName: String?, error: String?)
    case worktreeCloseCheckResult(sessionId: String, dirtyState: WorktreeDirtyState)
    case worktreeCloseResult(sessionId: String, result: GitOperationResult)
    case gitMergeCheckResult(sessionId: String, worktreeSessionId: String, dirtyState: WorktreeDirtyState)
    case gitMergeResult(sessionId: String, result: GitOperationResult)
    case gitRebaseResult(sessionId: String, result: GitOperationResult)
    case worktreeSyncStatus(info: WorktreeSyncInfo)
    // Input Log
    case inputLogSave(sessionId: String, entry: InputLogEntry)       // iOS → Mac
    case inputLogRequest(sessionId: String)                          // iOS → Mac
    case inputLogUpdate(sessionId: String, logData: InputLogData)    // iOS → Mac
    case inputLogResponse(sessionId: String, logData: InputLogData)  // Mac → iOS
    case inputLogSaveAck(sessionId: String, entryId: UUID)          // Mac → iOS
    // Directory listing
    case dirListRequest(path: String)                    // iOS → Mac
    case dirListResponse(path: String, dirs: [String])   // Mac → iOS
    // ASC Config
    case ascConfigReset                                                                          // iOS → Mac
    case ascConfigSet(keyId: String, issuerId: String, keyPath: String?, keyContent: String?)     // iOS → Mac
    case ascConfigResult(success: Bool, ascKeyConfigured: Bool, ascKeyFileExists: Bool, error: String?)  // Mac → iOS
    // Secret rotation
    case rotateSecret(newSecret: String)   // Mac → iOS (after first auth)
    case rotateSecretAck                   // iOS → Mac
    // Session limit
    case ptyCreateFailed(sessionId: String, reason: String)  // Mac → iOS
    case unknown                      // unknown message type (avoids decode throw)
}

extension AppMessage: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, nonce, hmac, data, cols, rows, sessionId, name, sessions, directory, secret
        case scheme, action, configuration, sdk, teamId, schemes, project, status, message, branch, commit
        case team, signingStyle, provisioningProfile, signingCertificate
        case bundleId, ascKeyConfigured, ascKeyFileExists, archiveExists

        case projectPath, projects, workDir, dirs
        case config
        case pipelineConfigPayload, step, steps, params, pipelineSteps, pipelineCurrentIndex, stepStatuses, pipelineState
        // Git / Worktree keys
        case info, merge, worktreeSessionId, path, branchName, error, success, result, force, ffOnly, dirtyState, dirLayout
        // Input Log keys
        case entry, logData, entryId
        // Incremental replay keys
        case offset, isFullReplay
        // ASC Config keys
        case keyId, issuerId, keyPath, keyContent
        // Secret rotation keys
        case newSecret
        // Session control keys
        case isTakenOver
        // Session limit keys
        case reason
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "challenge":
            self = .challenge(nonce: try c.decode(String.self, forKey: .nonce))
        case "challenge_response":
            self = .challengeResponse(hmac: try c.decode(String.self, forKey: .hmac))
        case "auth_ok":
            self = .authOk
        case "pairing_credentials":
            self = .pairingCredentials(secret: try c.decode(String.self, forKey: .secret))
        case "pty_data":
            self = .ptyData(
                data: try c.decode(String.self, forKey: .data),
                sessionId: try c.decodeIfPresent(String.self, forKey: .sessionId) ?? "",
                offset: try c.decodeIfPresent(UInt64.self, forKey: .offset)
            )
        case "pty_input":
            self = .ptyInput(
                data: try c.decode(String.self, forKey: .data),
                sessionId: try c.decodeIfPresent(String.self, forKey: .sessionId) ?? ""
            )
        case "pty_resize":
            self = .ptyResize(
                cols: try c.decode(Int.self, forKey: .cols),
                rows: try c.decode(Int.self, forKey: .rows),
                sessionId: try c.decodeIfPresent(String.self, forKey: .sessionId) ?? ""
            )
        case "pty_create":
            self = .ptyCreate(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                name: try c.decode(String.self, forKey: .name),
                cols: try c.decodeIfPresent(Int.self, forKey: .cols) ?? 80,
                rows: try c.decodeIfPresent(Int.self, forKey: .rows) ?? 24,
                workDir: try c.decodeIfPresent(String.self, forKey: .workDir)
            )
        case "pty_rename":
            self = .ptyRename(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                name: try c.decode(String.self, forKey: .name)
            )
        case "pty_destroy":
            self = .ptyDestroy(sessionId: try c.decode(String.self, forKey: .sessionId))
        case "pty_destroyed":
            self = .ptyDestroyed(sessionId: try c.decode(String.self, forKey: .sessionId))
        case "session_taken_over":
            self = .sessionTakenOver(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                isTakenOver: try c.decodeIfPresent(Bool.self, forKey: .isTakenOver) ?? true)
        case "pty_cwd":
            self = .ptyCwd(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                directory: try c.decode(String.self, forKey: .directory)
            )
        case "pty_sessions":
            self = .ptySessions(sessions: try c.decode([PTYSessionInfo].self, forKey: .sessions))
        case "build_list_schemes":
            self = .buildListSchemes(workDir: try c.decodeIfPresent(String.self, forKey: .workDir))
        case "build_list_schemes_for_project":
            self = .buildListSchemesForProject(
                projectPath: try c.decode(String.self, forKey: .projectPath)
            )
        case "build_list_projects":
            self = .buildListProjects(workDir: try c.decodeIfPresent(String.self, forKey: .workDir))
        case "build_start":
            self = .buildStart(
                scheme: try c.decode(String.self, forKey: .scheme),
                action: try c.decode(String.self, forKey: .action),
                configuration: try c.decodeIfPresent(String.self, forKey: .configuration),
                sdk: try c.decodeIfPresent(String.self, forKey: .sdk),
                teamId: try c.decodeIfPresent(String.self, forKey: .teamId),
                workDir: try c.decodeIfPresent(String.self, forKey: .workDir)
            )
        case "build_start_in_project":
            self = .buildStartInProject(
                scheme: try c.decode(String.self, forKey: .scheme),
                action: try c.decode(String.self, forKey: .action),
                configuration: try c.decodeIfPresent(String.self, forKey: .configuration),
                sdk: try c.decodeIfPresent(String.self, forKey: .sdk),
                teamId: try c.decodeIfPresent(String.self, forKey: .teamId),
                projectPath: try c.decode(String.self, forKey: .projectPath)
            )
        case "build_cancel":
            self = .buildCancel
        case "build_get_signing_info":
            self = .buildGetSigningInfo(
                scheme: try c.decode(String.self, forKey: .scheme),
                workDir: try c.decodeIfPresent(String.self, forKey: .workDir)
            )
        case "build_get_signing_info_for_project":
            self = .buildGetSigningInfoForProject(
                scheme: try c.decode(String.self, forKey: .scheme),
                projectPath: try c.decode(String.self, forKey: .projectPath)
            )
        case "build_projects":
            self = .buildProjects(
                projects: try c.decode([[String: String]].self, forKey: .projects)
            )
        case "build_schemes":
            self = .buildSchemes(
                schemes: try c.decode([String].self, forKey: .schemes),
                project: try c.decode(String.self, forKey: .project)
            )
        case "build_output":
            self = .buildOutput(data: try c.decode(String.self, forKey: .data))
        case "build_status":
            self = .buildStatus(
                status: try c.decode(String.self, forKey: .status),
                message: try c.decode(String.self, forKey: .message),
                branch: try c.decodeIfPresent(String.self, forKey: .branch),
                commit: try c.decodeIfPresent(String.self, forKey: .commit),
                action: try c.decodeIfPresent(String.self, forKey: .action),
                pipelineSteps: try c.decodeIfPresent([String].self, forKey: .pipelineSteps),
                pipelineCurrentIndex: try c.decodeIfPresent(Int.self, forKey: .pipelineCurrentIndex)
            )
        case "build_signing_info":
            self = .buildSigningInfo(
                team: try c.decode(String.self, forKey: .team),
                signingStyle: try c.decode(String.self, forKey: .signingStyle),
                provisioningProfile: try c.decode(String.self, forKey: .provisioningProfile),
                signingCertificate: try c.decode(String.self, forKey: .signingCertificate),
                bundleId: try c.decode(String.self, forKey: .bundleId),
                ascKeyConfigured: try c.decode(Bool.self, forKey: .ascKeyConfigured),
                ascKeyFileExists: try c.decode(Bool.self, forKey: .ascKeyFileExists),
                archiveExists: try c.decode(Bool.self, forKey: .archiveExists)
            )
        case "pty_ready":
            self = .ptyReady(
                cols: try c.decode(Int.self, forKey: .cols),
                rows: try c.decode(Int.self, forKey: .rows),
                sessionId: try c.decodeIfPresent(String.self, forKey: .sessionId) ?? ""
            )
        case "pty_replay":
            self = .ptyReplay(
                data: try c.decode(String.self, forKey: .data),
                sessionId: try c.decodeIfPresent(String.self, forKey: .sessionId) ?? "",
                offset: try c.decodeIfPresent(UInt64.self, forKey: .offset),
                isFullReplay: try c.decodeIfPresent(Bool.self, forKey: .isFullReplay)
            )
        case "pty_replay_request":
            self = .ptyReplayRequest(
                sessionId: try c.decodeIfPresent(String.self, forKey: .sessionId) ?? "",
                offset: try c.decodeIfPresent(UInt64.self, forKey: .offset)
            )
        case "build_replay":
            self = .buildReplay(
                data: try c.decode(String.self, forKey: .data),
                status: try c.decode(String.self, forKey: .status),
                message: try c.decode(String.self, forKey: .message),
                action: try c.decodeIfPresent(String.self, forKey: .action) ?? "",
                branch: try c.decodeIfPresent(String.self, forKey: .branch),
                commit: try c.decodeIfPresent(String.self, forKey: .commit),
                pipelineSteps: try c.decodeIfPresent([String].self, forKey: .pipelineSteps),
                pipelineCurrentIndex: try c.decodeIfPresent(Int.self, forKey: .pipelineCurrentIndex),
                stepStatuses: try c.decodeIfPresent([String: String].self, forKey: .stepStatuses)
            )

        case "room_config":
            self = .roomConfig(config: try c.decode(RoomConfig.self, forKey: .config))
        case "room_config_update":
            self = .roomConfigUpdate(config: try c.decode(RoomConfig.self, forKey: .config))
        case "pipeline_config":
            self = .pipelineConfig(config: try c.decode(PipelineConfig.self, forKey: .pipelineConfigPayload))
        case "pipeline_config_update":
            self = .pipelineConfigUpdate(config: try c.decode(PipelineConfig.self, forKey: .pipelineConfigPayload))
        case "pipeline_run_step":
            self = .pipelineRunStep(
                step: try c.decode(String.self, forKey: .step),
                workDir: try c.decodeIfPresent(String.self, forKey: .workDir),
                params: try c.decodeIfPresent([String: String].self, forKey: .params)
            )
        case "pipeline_start":
            self = .pipelineStart(
                steps: try c.decode([String].self, forKey: .steps),
                workDir: try c.decodeIfPresent(String.self, forKey: .workDir),
                params: try c.decodeIfPresent([String: String].self, forKey: .params)
            )
        case "pipeline_cancel":
            self = .pipelineCancel
        case "pipeline_state_query":
            self = .pipelineStateQuery
        case "pipeline_state_response":
            self = .pipelineStateResponse(
                state: try c.decodeIfPresent(PipelineState.self, forKey: .pipelineState)
            )
        // Git / Worktree decoding
        case "git_detect_request":
            self = .gitDetectRequest(sessionId: try c.decode(String.self, forKey: .sessionId))
        case "worktree_create":
            self = .worktreeCreate(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                name: try c.decode(String.self, forKey: .name),
                dirLayout: try c.decodeIfPresent(WorktreeDirLayout.self, forKey: .dirLayout)
            )
        case "worktree_close_check":
            self = .worktreeCloseCheck(sessionId: try c.decode(String.self, forKey: .sessionId))
        case "worktree_close":
            self = .worktreeClose(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                merge: try c.decodeIfPresent(Bool.self, forKey: .merge) ?? false,
                ffOnly: try c.decodeIfPresent(Bool.self, forKey: .ffOnly) ?? false
            )
        case "git_merge_check":
            self = .gitMergeCheck(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                worktreeSessionId: try c.decode(String.self, forKey: .worktreeSessionId)
            )
        case "git_merge":
            self = .gitMerge(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                worktreeSessionId: try c.decode(String.self, forKey: .worktreeSessionId),
                force: try c.decodeIfPresent(Bool.self, forKey: .force) ?? false,
                ffOnly: try c.decodeIfPresent(Bool.self, forKey: .ffOnly) ?? false
            )
        case "git_rebase":
            self = .gitRebase(sessionId: try c.decode(String.self, forKey: .sessionId))
        case "worktree_sync_check":
            self = .worktreeSyncCheck(sessionId: try c.decode(String.self, forKey: .sessionId))
        case "git_detect_result":
            self = .gitDetectResult(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                info: try c.decode(GitDetectInfo.self, forKey: .info)
            )
        case "worktree_create_result":
            self = .worktreeCreateResult(
                success: try c.decode(Bool.self, forKey: .success),
                sessionId: try c.decode(String.self, forKey: .sessionId),
                worktreeSessionId: try c.decodeIfPresent(String.self, forKey: .worktreeSessionId),
                path: try c.decodeIfPresent(String.self, forKey: .path),
                branchName: try c.decodeIfPresent(String.self, forKey: .branchName),
                error: try c.decodeIfPresent(String.self, forKey: .error)
            )
        case "worktree_close_check_result":
            self = .worktreeCloseCheckResult(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                dirtyState: try c.decode(WorktreeDirtyState.self, forKey: .dirtyState)
            )
        case "worktree_close_result":
            self = .worktreeCloseResult(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                result: try c.decode(GitOperationResult.self, forKey: .result)
            )
        case "git_merge_check_result":
            self = .gitMergeCheckResult(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                worktreeSessionId: try c.decode(String.self, forKey: .worktreeSessionId),
                dirtyState: try c.decode(WorktreeDirtyState.self, forKey: .dirtyState)
            )
        case "git_merge_result":
            self = .gitMergeResult(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                result: try c.decode(GitOperationResult.self, forKey: .result)
            )
        case "git_rebase_result":
            self = .gitRebaseResult(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                result: try c.decode(GitOperationResult.self, forKey: .result)
            )
        case "worktree_sync_status":
            self = .worktreeSyncStatus(info: try c.decode(WorktreeSyncInfo.self, forKey: .info))
        // Input Log decoding
        case "input_log_save":
            self = .inputLogSave(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                entry: try c.decode(InputLogEntry.self, forKey: .entry)
            )
        case "input_log_request":
            self = .inputLogRequest(sessionId: try c.decode(String.self, forKey: .sessionId))
        case "input_log_update":
            self = .inputLogUpdate(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                logData: try c.decode(InputLogData.self, forKey: .logData)
            )
        case "input_log_response":
            self = .inputLogResponse(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                logData: try c.decode(InputLogData.self, forKey: .logData)
            )
        case "input_log_save_ack":
            self = .inputLogSaveAck(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                entryId: try c.decode(UUID.self, forKey: .entryId)
            )
        // Directory listing decoding
        case "dir_list_request":
            self = .dirListRequest(path: try c.decode(String.self, forKey: .path))
        case "dir_list_response":
            self = .dirListResponse(
                path: try c.decode(String.self, forKey: .path),
                dirs: try c.decode([String].self, forKey: .dirs)
            )
        // ASC Config decoding
        case "asc_config_reset":
            self = .ascConfigReset
        case "asc_config_set":
            self = .ascConfigSet(
                keyId: try c.decode(String.self, forKey: .keyId),
                issuerId: try c.decode(String.self, forKey: .issuerId),
                keyPath: try c.decodeIfPresent(String.self, forKey: .keyPath),
                keyContent: try c.decodeIfPresent(String.self, forKey: .keyContent)
            )
        case "asc_config_result":
            self = .ascConfigResult(
                success: try c.decode(Bool.self, forKey: .success),
                ascKeyConfigured: try c.decode(Bool.self, forKey: .ascKeyConfigured),
                ascKeyFileExists: try c.decode(Bool.self, forKey: .ascKeyFileExists),
                error: try c.decodeIfPresent(String.self, forKey: .error)
            )
        // Secret rotation
        case "rotate_secret":
            self = .rotateSecret(newSecret: try c.decode(String.self, forKey: .newSecret))
        case "rotate_secret_ack":
            self = .rotateSecretAck
        case "pty_create_failed":
            self = .ptyCreateFailed(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                reason: try c.decodeIfPresent(String.self, forKey: .reason) ?? "unknown"
            )
        default:
            self = .unknown
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .challenge(let nonce):
            try c.encode("challenge", forKey: .type)
            try c.encode(nonce, forKey: .nonce)
        case .challengeResponse(let hmac):
            try c.encode("challenge_response", forKey: .type)
            try c.encode(hmac, forKey: .hmac)
        case .authOk:
            try c.encode("auth_ok", forKey: .type)
        case .pairingCredentials(let secret):
            try c.encode("pairing_credentials", forKey: .type)
            try c.encode(secret, forKey: .secret)
        case .ptyData(let data, let sessionId, let offset):
            try c.encode("pty_data", forKey: .type)
            try c.encode(data, forKey: .data)
            try c.encode(sessionId, forKey: .sessionId)
            try c.encodeIfPresent(offset, forKey: .offset)
        case .ptyInput(let data, let sessionId):
            try c.encode("pty_input", forKey: .type)
            try c.encode(data, forKey: .data)
            try c.encode(sessionId, forKey: .sessionId)
        case .ptyResize(let cols, let rows, let sessionId):
            try c.encode("pty_resize", forKey: .type)
            try c.encode(cols, forKey: .cols)
            try c.encode(rows, forKey: .rows)
            try c.encode(sessionId, forKey: .sessionId)
        case .ptyCreate(let sessionId, let name, let cols, let rows, let workDir):
            try c.encode("pty_create", forKey: .type)
            try c.encode(sessionId, forKey: .sessionId)
            try c.encode(name, forKey: .name)
            try c.encode(cols, forKey: .cols)
            try c.encode(rows, forKey: .rows)
            try c.encodeIfPresent(workDir, forKey: .workDir)
        case .ptyRename(let sessionId, let name):
            try c.encode("pty_rename", forKey: .type)
            try c.encode(sessionId, forKey: .sessionId)
            try c.encode(name, forKey: .name)
        case .ptyDestroy(let sessionId):
            try c.encode("pty_destroy", forKey: .type)
            try c.encode(sessionId, forKey: .sessionId)
        case .ptyDestroyed(let sessionId):
            try c.encode("pty_destroyed", forKey: .type)
            try c.encode(sessionId, forKey: .sessionId)
        case .sessionTakenOver(let sessionId, let isTakenOver):
            try c.encode("session_taken_over", forKey: .type)
            try c.encode(sessionId, forKey: .sessionId)
            try c.encode(isTakenOver, forKey: .isTakenOver)
        case .ptyCwd(let sessionId, let directory):
            try c.encode("pty_cwd", forKey: .type)
            try c.encode(sessionId, forKey: .sessionId)
            try c.encode(directory, forKey: .directory)
        case .ptySessions(let sessions):
            try c.encode("pty_sessions", forKey: .type)
            try c.encode(sessions, forKey: .sessions)
        case .buildListSchemes(let workDir):
            try c.encode("build_list_schemes", forKey: .type)
            try c.encodeIfPresent(workDir, forKey: .workDir)
        case .buildListSchemesForProject(let projectPath):
            try c.encode("build_list_schemes_for_project", forKey: .type)
            try c.encode(projectPath, forKey: .projectPath)
        case .buildListProjects(let workDir):
            try c.encode("build_list_projects", forKey: .type)
            try c.encodeIfPresent(workDir, forKey: .workDir)
        case .buildStart(let scheme, let action, let configuration, let sdk, let teamId, let workDir):
            try c.encode("build_start", forKey: .type)
            try c.encode(scheme, forKey: .scheme)
            try c.encode(action, forKey: .action)
            try c.encodeIfPresent(configuration, forKey: .configuration)
            try c.encodeIfPresent(sdk, forKey: .sdk)
            try c.encodeIfPresent(teamId, forKey: .teamId)
            try c.encodeIfPresent(workDir, forKey: .workDir)
        case .buildStartInProject(let scheme, let action, let configuration, let sdk, let teamId, let projectPath):
            try c.encode("build_start_in_project", forKey: .type)
            try c.encode(scheme, forKey: .scheme)
            try c.encode(action, forKey: .action)
            try c.encodeIfPresent(configuration, forKey: .configuration)
            try c.encodeIfPresent(sdk, forKey: .sdk)
            try c.encodeIfPresent(teamId, forKey: .teamId)
            try c.encode(projectPath, forKey: .projectPath)
        case .buildCancel:
            try c.encode("build_cancel", forKey: .type)
        case .buildGetSigningInfo(let scheme, let workDir):
            try c.encode("build_get_signing_info", forKey: .type)
            try c.encode(scheme, forKey: .scheme)
            try c.encodeIfPresent(workDir, forKey: .workDir)
        case .buildGetSigningInfoForProject(let scheme, let projectPath):
            try c.encode("build_get_signing_info_for_project", forKey: .type)
            try c.encode(scheme, forKey: .scheme)
            try c.encode(projectPath, forKey: .projectPath)
        case .buildProjects(let projects):
            try c.encode("build_projects", forKey: .type)
            try c.encode(projects, forKey: .projects)
        case .buildSchemes(let schemes, let project):
            try c.encode("build_schemes", forKey: .type)
            try c.encode(schemes, forKey: .schemes)
            try c.encode(project, forKey: .project)
        case .buildOutput(let data):
            try c.encode("build_output", forKey: .type)
            try c.encode(data, forKey: .data)
        case .buildStatus(let status, let message, let branch, let commit, let action, let pipelineSteps, let pipelineCurrentIndex):
            try c.encode("build_status", forKey: .type)
            try c.encode(status, forKey: .status)
            try c.encode(message, forKey: .message)
            try c.encodeIfPresent(branch, forKey: .branch)
            try c.encodeIfPresent(commit, forKey: .commit)
            try c.encodeIfPresent(action, forKey: .action)
            try c.encodeIfPresent(pipelineSteps, forKey: .pipelineSteps)
            try c.encodeIfPresent(pipelineCurrentIndex, forKey: .pipelineCurrentIndex)
        case .buildSigningInfo(let team, let signingStyle, let provisioningProfile, let signingCertificate, let bundleId, let ascKeyConfigured, let ascKeyFileExists, let archiveExists):
            try c.encode("build_signing_info", forKey: .type)
            try c.encode(team, forKey: .team)
            try c.encode(signingStyle, forKey: .signingStyle)
            try c.encode(provisioningProfile, forKey: .provisioningProfile)
            try c.encode(signingCertificate, forKey: .signingCertificate)
            try c.encode(bundleId, forKey: .bundleId)
            try c.encode(ascKeyConfigured, forKey: .ascKeyConfigured)
            try c.encode(ascKeyFileExists, forKey: .ascKeyFileExists)
            try c.encode(archiveExists, forKey: .archiveExists)
        case .ptyReady(let cols, let rows, let sessionId):
            try c.encode("pty_ready", forKey: .type)
            try c.encode(cols, forKey: .cols)
            try c.encode(rows, forKey: .rows)
            try c.encode(sessionId, forKey: .sessionId)
        case .ptyReplay(let data, let sessionId, let offset, let isFullReplay):
            try c.encode("pty_replay", forKey: .type)
            try c.encode(data, forKey: .data)
            try c.encode(sessionId, forKey: .sessionId)
            try c.encodeIfPresent(offset, forKey: .offset)
            try c.encodeIfPresent(isFullReplay, forKey: .isFullReplay)
        case .ptyReplayRequest(let sessionId, let offset):
            try c.encode("pty_replay_request", forKey: .type)
            try c.encode(sessionId, forKey: .sessionId)
            try c.encodeIfPresent(offset, forKey: .offset)
        case .buildReplay(let data, let status, let message, let action, let branch, let commit, let pipelineSteps, let pipelineCurrentIndex, let stepStatuses):
            try c.encode("build_replay", forKey: .type)
            try c.encode(data, forKey: .data)
            try c.encode(status, forKey: .status)
            try c.encode(message, forKey: .message)
            try c.encode(action, forKey: .action)
            try c.encodeIfPresent(branch, forKey: .branch)
            try c.encodeIfPresent(commit, forKey: .commit)
            try c.encodeIfPresent(pipelineSteps, forKey: .pipelineSteps)
            try c.encodeIfPresent(pipelineCurrentIndex, forKey: .pipelineCurrentIndex)
            try c.encodeIfPresent(stepStatuses, forKey: .stepStatuses)

        case .roomConfig(let config):
            try c.encode("room_config", forKey: .type)
            try c.encode(config, forKey: .config)
        case .roomConfigUpdate(let config):
            try c.encode("room_config_update", forKey: .type)
            try c.encode(config, forKey: .config)
        case .pipelineConfig(let config):
            try c.encode("pipeline_config", forKey: .type)
            try c.encode(config, forKey: .pipelineConfigPayload)
        case .pipelineConfigUpdate(let config):
            try c.encode("pipeline_config_update", forKey: .type)
            try c.encode(config, forKey: .pipelineConfigPayload)
        case .pipelineRunStep(let step, let workDir, let params):
            try c.encode("pipeline_run_step", forKey: .type)
            try c.encode(step, forKey: .step)
            try c.encodeIfPresent(workDir, forKey: .workDir)
            try c.encodeIfPresent(params, forKey: .params)
        case .pipelineStart(let steps, let workDir, let params):
            try c.encode("pipeline_start", forKey: .type)
            try c.encode(steps, forKey: .steps)
            try c.encodeIfPresent(workDir, forKey: .workDir)
            try c.encodeIfPresent(params, forKey: .params)
        case .pipelineCancel:
            try c.encode("pipeline_cancel", forKey: .type)
        case .pipelineStateQuery:
            try c.encode("pipeline_state_query", forKey: .type)
        case .pipelineStateResponse(let state):
            try c.encode("pipeline_state_response", forKey: .type)
            try c.encodeIfPresent(state, forKey: .pipelineState)
        // Git / Worktree encoding
        case .gitDetectRequest(let sessionId):
            try c.encode("git_detect_request", forKey: .type)
            try c.encode(sessionId, forKey: .sessionId)
        case .worktreeCreate(let sessionId, let name, let dirLayout):
            try c.encode("worktree_create", forKey: .type)
            try c.encode(sessionId, forKey: .sessionId)
            try c.encode(name, forKey: .name)
            try c.encodeIfPresent(dirLayout, forKey: .dirLayout)
        case .worktreeCloseCheck(let sessionId):
            try c.encode("worktree_close_check", forKey: .type)
            try c.encode(sessionId, forKey: .sessionId)
        case .worktreeClose(let sessionId, let merge, let ffOnly):
            try c.encode("worktree_close", forKey: .type)
            try c.encode(sessionId, forKey: .sessionId)
            try c.encode(merge, forKey: .merge)
            try c.encode(ffOnly, forKey: .ffOnly)
        case .gitMergeCheck(let sessionId, let worktreeSessionId):
            try c.encode("git_merge_check", forKey: .type)
            try c.encode(sessionId, forKey: .sessionId)
            try c.encode(worktreeSessionId, forKey: .worktreeSessionId)
        case .gitMerge(let sessionId, let worktreeSessionId, let force, let ffOnly):
            try c.encode("git_merge", forKey: .type)
            try c.encode(sessionId, forKey: .sessionId)
            try c.encode(worktreeSessionId, forKey: .worktreeSessionId)
            try c.encode(force, forKey: .force)
            try c.encode(ffOnly, forKey: .ffOnly)
        case .gitRebase(let sessionId):
            try c.encode("git_rebase", forKey: .type)
            try c.encode(sessionId, forKey: .sessionId)
        case .worktreeSyncCheck(let sessionId):
            try c.encode("worktree_sync_check", forKey: .type)
            try c.encode(sessionId, forKey: .sessionId)
        case .gitDetectResult(let sessionId, let info):
            try c.encode("git_detect_result", forKey: .type)
            try c.encode(sessionId, forKey: .sessionId)
            try c.encode(info, forKey: .info)
        case .worktreeCreateResult(let success, let sessionId, let worktreeSessionId, let path, let branchName, let error):
            try c.encode("worktree_create_result", forKey: .type)
            try c.encode(success, forKey: .success)
            try c.encode(sessionId, forKey: .sessionId)
            try c.encodeIfPresent(worktreeSessionId, forKey: .worktreeSessionId)
            try c.encodeIfPresent(path, forKey: .path)
            try c.encodeIfPresent(branchName, forKey: .branchName)
            try c.encodeIfPresent(error, forKey: .error)
        case .worktreeCloseCheckResult(let sessionId, let dirtyState):
            try c.encode("worktree_close_check_result", forKey: .type)
            try c.encode(sessionId, forKey: .sessionId)
            try c.encode(dirtyState, forKey: .dirtyState)
        case .worktreeCloseResult(let sessionId, let result):
            try c.encode("worktree_close_result", forKey: .type)
            try c.encode(sessionId, forKey: .sessionId)
            try c.encode(result, forKey: .result)
        case .gitMergeCheckResult(let sessionId, let worktreeSessionId, let dirtyState):
            try c.encode("git_merge_check_result", forKey: .type)
            try c.encode(sessionId, forKey: .sessionId)
            try c.encode(worktreeSessionId, forKey: .worktreeSessionId)
            try c.encode(dirtyState, forKey: .dirtyState)
        case .gitMergeResult(let sessionId, let result):
            try c.encode("git_merge_result", forKey: .type)
            try c.encode(sessionId, forKey: .sessionId)
            try c.encode(result, forKey: .result)
        case .gitRebaseResult(let sessionId, let result):
            try c.encode("git_rebase_result", forKey: .type)
            try c.encode(sessionId, forKey: .sessionId)
            try c.encode(result, forKey: .result)
        case .worktreeSyncStatus(let info):
            try c.encode("worktree_sync_status", forKey: .type)
            try c.encode(info, forKey: .info)
        // Input Log encoding
        case .inputLogSave(let sessionId, let entry):
            try c.encode("input_log_save", forKey: .type)
            try c.encode(sessionId, forKey: .sessionId)
            try c.encode(entry, forKey: .entry)
        case .inputLogRequest(let sessionId):
            try c.encode("input_log_request", forKey: .type)
            try c.encode(sessionId, forKey: .sessionId)
        case .inputLogUpdate(let sessionId, let logData):
            try c.encode("input_log_update", forKey: .type)
            try c.encode(sessionId, forKey: .sessionId)
            try c.encode(logData, forKey: .logData)
        case .inputLogResponse(let sessionId, let logData):
            try c.encode("input_log_response", forKey: .type)
            try c.encode(sessionId, forKey: .sessionId)
            try c.encode(logData, forKey: .logData)
        case .inputLogSaveAck(let sessionId, let entryId):
            try c.encode("input_log_save_ack", forKey: .type)
            try c.encode(sessionId, forKey: .sessionId)
            try c.encode(entryId, forKey: .entryId)
        // Directory listing encoding
        case .dirListRequest(let path):
            try c.encode("dir_list_request", forKey: .type)
            try c.encode(path, forKey: .path)
        case .dirListResponse(let path, let dirs):
            try c.encode("dir_list_response", forKey: .type)
            try c.encode(path, forKey: .path)
            try c.encode(dirs, forKey: .dirs)
        // ASC Config encoding
        case .ascConfigReset:
            try c.encode("asc_config_reset", forKey: .type)
        case .ascConfigSet(let keyId, let issuerId, let keyPath, let keyContent):
            try c.encode("asc_config_set", forKey: .type)
            try c.encode(keyId, forKey: .keyId)
            try c.encode(issuerId, forKey: .issuerId)
            try c.encodeIfPresent(keyPath, forKey: .keyPath)
            try c.encodeIfPresent(keyContent, forKey: .keyContent)
        case .ascConfigResult(let success, let ascKeyConfigured, let ascKeyFileExists, let error):
            try c.encode("asc_config_result", forKey: .type)
            try c.encode(success, forKey: .success)
            try c.encode(ascKeyConfigured, forKey: .ascKeyConfigured)
            try c.encode(ascKeyFileExists, forKey: .ascKeyFileExists)
            try c.encodeIfPresent(error, forKey: .error)
        // Secret rotation encoding
        case .rotateSecret(let newSecret):
            try c.encode("rotate_secret", forKey: .type)
            try c.encode(newSecret, forKey: .newSecret)
        case .rotateSecretAck:
            try c.encode("rotate_secret_ack", forKey: .type)
        case .ptyCreateFailed(let sessionId, let reason):
            try c.encode("pty_create_failed", forKey: .type)
            try c.encode(sessionId, forKey: .sessionId)
            try c.encode(reason, forKey: .reason)
        case .unknown:
            try c.encode("unknown", forKey: .type)
        }
    }
}
