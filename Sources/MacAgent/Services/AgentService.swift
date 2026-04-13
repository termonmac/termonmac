import Foundation
import RemoteDevCore
import BuildKit
import MacAgentLib

/// Convert a file URL string (e.g. "file://hostname/Users/...") to a plain path.
/// Returns the input unchanged if it's already a plain path.
func stripFileURL(_ path: String) -> String {
    guard path.hasPrefix("file://") else { return path }
    if let url = URL(string: path), url.scheme == "file" {
        return url.path
    }
    // Fallback: URL(string:) can fail for some inputs
    let afterScheme = path.dropFirst(7) // drop "file://"
    if let slashIdx = afterScheme.firstIndex(of: "/") {
        return String(afterScheme[slashIdx...])
    }
    return path
}

#if os(macOS)
final class AgentService {
    func run(serverURL: String, workDir: String, apiKey: String?,
             sandboxKey: String? = nil,
             refreshToken: String? = nil,
             crypto: SessionCrypto, roomID: String, roomSecret: String,
             configDir: String, roomCredentialStore: RoomCredentialStore? = nil,
             refreshCount: Int = 0) async {
        let sleepManager = SleepManager()
        sleepManager.preventIdleSleep()

        let relay = RelayConnection(serverURL: serverURL, workDir: workDir,
                                     apiKey: apiKey, sandboxKey: sandboxKey,
                                     crypto: crypto,
                                     roomID: roomID, roomSecret: roomSecret,
                                     configDir: configDir)

        // Set up secret rotation state from persisted credentials
        if let creds = roomCredentialStore?.load(), creds.secretRotated == true {
            relay.secretRotated = true
        }
        relay.onSecretRotated = { newSecret in
            _ = roomCredentialStore?.updateSecret(newSecret)
        }

        let ptyManager: PTYManagerProtocol = Self.connectToHelper(configDir: configDir, workDir: workDir)

        relay.onMaxSessionsUpdated = { max in
            ptyManager.updateMaxSessions(max)
            log("[agent] tier max_sessions from server: \(max)")
        }

        // MARK: - Per-session controller tracking
        // Tracks who currently controls each session's I/O (iOS, Mac, or none).
        var sessionControllers: [String: SessionController] = [:]
        // Tracks iOS's last-seen output offset per session, for replay on reclaim.
        var iosLastOffsets: [String: UInt64] = [:]
        let controllerLock = NSLock()

        // pty_helper.sock path — Mac CLI connects directly for fd-pass mode.
        // HelperServer now supports multiple concurrent clients, so AgentService
        // keeps its HelperClient connection while Mac CLI connects independently.
        let helperSocketPath = Self.socketPath(for: configDir)

        func getController(_ sessionId: String) -> SessionController {
            controllerLock.lock()
            defer { controllerLock.unlock() }
            return sessionControllers[sessionId] ?? .ios
        }

        func setController(_ sessionId: String, _ controller: SessionController) {
            controllerLock.lock()
            sessionControllers[sessionId] = controller
            controllerLock.unlock()
            log("[controller] session \(sessionId) → \(controller.rawValue)")
        }

        /// Replay output iOS missed while a session was under Mac control.
        func replayToIOS(_ sessionId: String) {
            controllerLock.lock()
            let lastOffset = iosLastOffsets[sessionId]
            controllerLock.unlock()
            let replay = ptyManager.replayIncremental(sessionId: sessionId, sinceOffset: lastOffset)
            if !replay.data.isEmpty {
                let b64 = replay.data.base64EncodedString()
                try? relay.sendEncrypted(.ptyReplay(
                    data: b64, sessionId: sessionId,
                    offset: replay.currentOffset, isFullReplay: replay.isFull))
            }
        }

        /// iOS reclaims a session from Mac: replay BEFORE switching controller
        /// to avoid out-of-order output.
        func iosReclaim(_ sessionId: String) {
            // 1. Replay missed output to iOS (controller still .mac)
            replayToIOS(sessionId)
            // 2. Notify Mac
            localSocket.pushEvent(.takenOver(sessionId: sessionId), sessionId: sessionId)
            // 3. Switch controller — from here new output routes to iOS
            setController(sessionId, .ios)
            // 4. Notify iOS that session is released
            try? relay.sendEncrypted(.sessionTakenOver(sessionId: sessionId, isTakenOver: false))
        }

        // Local socket for termonmac sessions/attach
        let localSocket = LocalSocketServer(socketPath: configDir + "/agent.sock")

        localSocket.onListSessions = { [weak ptyManager] in
            guard let ptyManager else { return [] }
            return ptyManager.sessionInfoList().map { info in
                LocalSessionInfo(
                    sessionId: info.sessionId, name: info.name,
                    cols: info.cols, rows: info.rows,
                    sessionType: info.sessionType, cwd: info.cwd,
                    controller: getController(info.sessionId),
                    slavePath: ptyManager.slavePath(for: info.sessionId))
            }
        }

        localSocket.onAttach = { [weak ptyManager] sessionId in
            guard let ptyManager, ptyManager.hasSession(sessionId) else {
                return (false, "session not found", nil, nil)
            }
            // Get replay data BEFORE switching controller to avoid duplicate output.
            let replay = ptyManager.replayIncremental(sessionId: sessionId, sinceOffset: nil)
            setController(sessionId, .mac)
            // Notify iOS that this session has been taken over
            try? relay.sendEncrypted(.sessionTakenOver(sessionId: sessionId, isTakenOver: true))
            // HelperServer supports multiple concurrent clients — no need to yield.
            // Mac CLI connects independently to pty_helper.sock for fd-pass/direct mode.
            if ptyManager is HelperClient {
                log("[attach] Mac CLI direct-connect (agent stays connected)")
                return (true, nil, nil, helperSocketPath)
            }
            // Fallback (in-process PTYManager): proxy mode
            return (true, nil, replay.data.isEmpty ? nil : replay.data, nil)
        }

        localSocket.onInput = { [weak ptyManager] sessionId, data in
            ptyManager?.write(data, to: sessionId)
        }

        localSocket.onResize = { [weak ptyManager] sessionId, cols, rows in
            ptyManager?.resize(sessionId: sessionId, cols: cols, rows: rows)
        }

        let roomConfigStore = RoomConfigStore(configDir: configDir)
        let gitManager = GitManager()

        localSocket.onDetach = { (detachedSessionId: String?) in
            guard let detachedSessionId else { return }  // query-only client — nothing to do

            // Agent stays connected to helper throughout Mac attach — just replay and reset.
            if getController(detachedSessionId) == .mac {
                replayToIOS(detachedSessionId)
                setController(detachedSessionId, .ios)
                try? relay.sendEncrypted(.sessionTakenOver(sessionId: detachedSessionId, isTakenOver: false))
            }
        }

        do {
            try localSocket.start()
        } catch {
            log("[localSocket] failed to start: \(error)")
        }

        let buildManager = BuildManager()
        let ascStore = ASCConfigStore(configDir: configDir)
        buildManager.ascConfigState = ascStore.loadState()
        if case .configured(let config) = buildManager.ascConfigState {
            log("[asc] Loaded ASC config: keyId=\(config.keyId)")
        }

        let pipelineConfigStore = PipelineConfigStore()
        let pipelineStateStore = PipelineStateStore()
        let pipelineExecutor = PipelineExecutor(buildManager: buildManager)

        // Shared: detect git repo and resolve worktree parent for a session
        func detectAndResolveGit(sessionId: String, ptyManager: PTYManagerProtocol) {
            let effectiveDir = ptyManager.getWorkDir(sessionId: sessionId) ?? workDir
            let info = gitManager.detectGitRepo(at: effectiveDir)
            if info.isGitRepo {
                let sType: SessionType = info.isWorktree ? .worktree : .git
                ptyManager.updateSessionType(sessionId: sessionId, type: sType, branchName: info.branchName)
                roomConfigStore.updateSessionType(sessionId: sessionId, sessionType: sType, branchName: info.branchName)
                // Resolve worktree parent: find main repo and match to existing session
                if info.isWorktree, let parentInfo = gitManager.resolveWorktreeParent(worktreePath: effectiveDir) {
                    let allSessions = ptyManager.sessionInfoList()
                    let parentSession = allSessions.first { s in
                        guard s.sessionId != sessionId else { return false }
                        return ptyManager.getWorkDir(sessionId: s.sessionId) == parentInfo.parentRepoPath
                    }
                    ptyManager.updateSessionParent(sessionId: sessionId,
                                                   parentSessionId: parentSession?.sessionId,
                                                   parentRepoPath: parentInfo.parentRepoPath,
                                                   parentBranchName: parentInfo.parentBranchName)
                    roomConfigStore.updateSessionParent(sessionId: sessionId,
                                                        parentSessionId: parentSession?.sessionId,
                                                        parentRepoPath: parentInfo.parentRepoPath,
                                                        parentBranchName: parentInfo.parentBranchName)
                    log("[git] worktree parent resolved: repo=\(parentInfo.parentRepoPath) parent=\(parentSession?.sessionId ?? "none")")
                }
            }
            try? relay.sendEncrypted(.gitDetectResult(sessionId: sessionId, info: info))
        }

        localSocket.onCreateSession = { [weak ptyManager] name, cols, rows, sessionWorkDir in
            guard let ptyManager else { return (nil, "service not ready") }
            let sessionId = UUID().uuidString
            let result = ptyManager.createSession(
                sessionId: sessionId, name: name, cols: cols, rows: rows,
                sessionWorkDir: sessionWorkDir, sessionType: .normal,
                parentSessionId: nil, branchName: nil,
                parentRepoPath: nil, parentBranchName: nil)
            guard result.success else {
                return (nil, result.error ?? "session creation failed")
            }
            roomConfigStore.addSession(sessionId: sessionId, name: name)
            roomConfigStore.updateWorktreeDir(sessionId: sessionId, directory: sessionWorkDir)
            ptyManager.switchToLive()
            try? relay.sendEncrypted(.ptyReady(cols: cols, rows: rows, sessionId: sessionId))
            try? relay.sendEncrypted(.roomConfig(config: roomConfigStore.current))
            DispatchQueue.global().async {
                detectAndResolveGit(sessionId: sessionId, ptyManager: ptyManager)
                // Send updated roomConfig with parent info
                try? relay.sendEncrypted(.roomConfig(config: roomConfigStore.current))
            }
            log("[localSocket] created session \(sessionId) (\(name))")
            return (sessionId, nil)
        }
        let inputLogStore = InputLogStore()

        localSocket.onKillSession = { [weak ptyManager] sessionId in
            guard let ptyManager else { return }
            ptyManager.destroy(sessionId: sessionId)
            roomConfigStore.removeSession(sessionId: sessionId)
            inputLogStore.removeLog(sessionId: sessionId)
            try? relay.sendEncrypted(.ptyDestroyed(sessionId: sessionId))
            log("[localSocket] killed session \(sessionId)")
        }

        localSocket.onRenameSession = { [weak ptyManager] sessionId, name in
            guard let ptyManager else { return }
            ptyManager.rename(sessionId: sessionId, name: name)
            roomConfigStore.renameSession(sessionId: sessionId, name: name)
            try? relay.sendEncrypted(.roomConfig(config: roomConfigStore.current))
            localSocket.pushEvent(.sessionRenamed(sessionId: sessionId, newName: name), sessionId: sessionId)
            log("[localSocket] renamed session \(sessionId) to '\(name)'")
        }

        func resolveParentRepoPath(worktreeSessionId: String) -> String {
            return ptyManager.getParentRepoPath(sessionId: worktreeSessionId)
                ?? ptyManager.getParentSessionId(sessionId: worktreeSessionId)
                    .flatMap { ptyManager.getWorkDir(sessionId: $0) }
                ?? workDir
        }

        func resolveParentBranchName(worktreeSessionId: String) -> String {
            return ptyManager.getParentBranchName(sessionId: worktreeSessionId)
                ?? ptyManager.getParentSessionId(sessionId: worktreeSessionId)
                    .flatMap { ptyManager.getBranchName(sessionId: $0) }
                ?? "main"
        }

        // MARK: - Restore sessions from persisted config
        // Skip restoration when helper already has live sessions (crash recovery)

        let helperHadSessions = !ptyManager.isEmpty
        if !helperHadSessions {
            let storedSessions = roomConfigStore.storedSessions()
            if !storedSessions.isEmpty {
                log("[restore] found \(storedSessions.count) stored sessions — restoring PTY sessions")
                for sc in storedSessions {
                    let sessionWorkDir: String? = sc.worktreeDir
                    let restoreResult = ptyManager.createSession(
                        sessionId: sc.sessionId, name: sc.name,
                        cols: PTYManager.defaultCols, rows: PTYManager.defaultRows,
                        sessionWorkDir: sessionWorkDir,
                        sessionType: sc.sessionType ?? .normal,
                        parentSessionId: sc.parentSessionId,
                        branchName: sc.branchName,
                        parentRepoPath: sc.parentRepoPath,
                        parentBranchName: sc.parentBranchName
                    )
                    if restoreResult.success {
                        log("[restore] restored session \(sc.sessionId) (\(sc.name)) type=\(sc.sessionType?.rawValue ?? "normal")")
                    } else {
                        log("[restore] failed to restore session \(sc.sessionId) (\(sc.name)) — \(restoreResult.error ?? "unknown") — removing from config")
                        roomConfigStore.removeSession(sessionId: sc.sessionId)
                    }
                }
            }
        } else {
            log("[restore] helper has \(ptyManager.sessionCount) live sessions — skipping room_config restore")
        }

        // MARK: - PTYManager callbacks

        var peerConnected = false
        let peerConnectedLock = NSLock()

        ptyManager.onOutput = { sessionId, data in
            let controller = getController(sessionId)
            if controller == .mac {
                localSocket.pushEvent(.output(sessionId: sessionId, data: data), sessionId: sessionId)
            } else {
                relay.touchUserActivity()
                let b64 = data.base64EncodedString()
                let offset = ptyManager.currentOffset(sessionId: sessionId)
                try? relay.sendEncryptedBatched(.ptyData(data: b64, sessionId: sessionId, offset: offset))
                // Track iOS's last offset for replay on reclaim
                controllerLock.lock()
                iosLastOffsets[sessionId] = offset
                controllerLock.unlock()
            }
        }

        ptyManager.onSessionExited = { sessionId in
            let controller = getController(sessionId)
            if controller == .mac {
                localSocket.pushEvent(.sessionExited(sessionId: sessionId), sessionId: sessionId)
            }
            try? relay.sendEncrypted(.ptyDestroyed(sessionId: sessionId))
            log("[ptyManager] session \(sessionId) exited — sent ptyDestroyed")
        }

        // MARK: - HelperClient reconnect / restart

        if let helperClient = ptyManager as? HelperClient {
            helperClient.onRestartHelper = {
                log("[helper] attempting to restart helper process")
                Self.killStaleHelper(configDir: configDir)
                // Spawn new helper and wait for socket to become available
                let mainExe = ProcessInfo.processInfo.arguments[0]
                let exePath = URL(fileURLWithPath: mainExe).resolvingSymlinksInPath().path
                guard FileManager.default.isExecutableFile(atPath: exePath) else {
                    log("[helper] cannot find binary for restart at \(exePath)")
                    return false
                }
                let process = Process()
                process.executableURL = URL(fileURLWithPath: exePath)
                let roomId = RoomCredentialStore(configDir: configDir).load()?.roomId
                var helperArgs = [
                    "pty-helper",
                    "--socket", Self.socketPath(for: configDir),
                    "--pid-file", Self.pidFilePath(for: configDir),
                    "--work-dir", workDir
                ]
                if let roomId { helperArgs += ["--room-id", roomId] }
                process.arguments = helperArgs
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    log("[helper] failed to restart helper: \(error)")
                    return false
                }
                // Wait for socket to become available (up to 3 seconds)
                let socketPath = Self.socketPath(for: configDir)
                for _ in 0..<30 {
                    usleep(100_000)
                    if FileManager.default.fileExists(atPath: socketPath) {
                        log("[helper] restarted helper — socket available")
                        return true
                    }
                }
                log("[helper] restarted helper but socket not available after 3s")
                return false
            }

            helperClient.onReconnected = {
                peerConnectedLock.lock()
                let hasPeer = peerConnected
                peerConnectedLock.unlock()

                if hasPeer {
                    if ptyManager.isEmpty {
                        // All sessions lost due to helper restart — notify iOS
                        try? relay.sendEncrypted(.ptySessions(sessions: []))
                        log("[helper] reconnected after restart — all sessions lost, notified iOS")
                    } else {
                        ptyManager.switchToLive()
                        let infos = ptyManager.sessionInfoList().map { info in
                            PTYSessionInfo(sessionId: info.sessionId, name: info.name,
                                           cols: info.cols, rows: info.rows,
                                           sessionType: info.sessionType, cwd: info.cwd,
                                           isMacControlled: getController(info.sessionId) == .mac)
                        }
                        try? relay.sendEncrypted(.ptySessions(sessions: infos))
                        log("[helper] reconnected — restored live mode with \(infos.count) sessions")
                    }
                }
            }

            helperClient.onDisconnected = {
                log("[helper] lost connection to helper — all restart attempts failed")
            }
        }

        // MARK: - BuildManager callbacks

        buildManager.onOutput = { data in
            let b64 = data.base64EncodedString()
            try? relay.sendEncryptedBatched(.buildOutput(data: b64))
        }
        buildManager.onStatusChange = { status, message, branch, commit in
            try? relay.sendEncrypted(.buildStatus(status: status, message: message, branch: branch, commit: commit))
        }

        // MARK: - PipelineExecutor callbacks

        pipelineExecutor.onOutput = { data in
            let b64 = data.base64EncodedString()
            try? relay.sendEncryptedBatched(.buildOutput(data: b64))
        }
        pipelineExecutor.onStatusChange = { status, message, branch, commit, action, pipelineSteps, pipelineCurrentIndex in
            try? relay.sendEncrypted(.buildStatus(status: status, message: message, branch: branch, commit: commit, action: action, pipelineSteps: pipelineSteps, pipelineCurrentIndex: pipelineCurrentIndex))
        }
        pipelineExecutor.onStateChange = { state in
            pipelineStateStore.update(state)
        }

        // MARK: - Relay callbacks

        var qrWindowController: QRWindowController?

        relay.onRoomRegistered = { [weak relay] in
            // Dismiss any existing QR window before showing a new one
            qrWindowController?.dismiss()
            qrWindowController = nil

            let roomName = roomCredentialStore?.load()?.roomName
            // Token was already generated by RelayConnection before register_room.
            // Prefer expires_at from PairingTokenStore if it matches; otherwise
            // synthesize `now + ttl` (daemon-generated token hasn't migrated to
            // the JSON store yet — Phase III unifies this).
            if let pairingToken = relay?.activePairingToken {
                let expiration: Int
                if case .ok(let file) = PairingTokenStore.load(configDir: configDir),
                   file.token == pairingToken {
                    expiration = file.expires_at
                } else {
                    expiration = Int(Date().timeIntervalSince1970) + PairingTokenFile.ttlSeconds
                }
                let result = QRRenderer.showQR(
                    relayURL: serverURL, roomID: roomID,
                    pairingToken: pairingToken,
                    macPubkey: crypto.publicKeyBase64,
                    expiration: expiration,
                    roomName: roomName)
                if case .gui(let controller) = result {
                    qrWindowController = controller
                }
            }
            let idShort = String(roomID.prefix(6))
            if let name = roomName {
                log("[room] registered: \"\(name)\" (\(idShort))")
            } else {
                log("[room] registered: \(idShort)")
            }
        }

        relay.onRegisterAuthFailed = { [weak self] in
            guard let store = roomCredentialStore else {
                log("[room] AUTH_FAILED — room_id collision likely. Run 'termonmac reset-room' to fix.")
                return
            }
            log("[room] AUTH_FAILED — room_id collision detected, regenerating...")
            log("[room] iOS devices will need to re-scan the QR code.")
            let newCreds = store.regenerate(keepName: true)
            log("[room] New room ID: \(newCreds.roomId). Restarting agent...")
            relay.disconnect()
            // Re-launch with new credentials
            Task { [weak self] in
                await self?.run(serverURL: serverURL, workDir: workDir,
                                apiKey: apiKey, sandboxKey: sandboxKey,
                                refreshToken: refreshToken,
                                crypto: crypto,
                                roomID: newCreds.roomId, roomSecret: newCreds.roomSecret,
                                configDir: configDir, roomCredentialStore: store)
            }
        }

        relay.onTokenInvalid = { [weak self] in
            guard let rt = refreshToken, !rt.isEmpty else {
                log("[auth] API key rejected, no refresh token — will retry in 10 minutes")
                Self.sendExpiryNotification()
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(600))
                    guard let self else { return }
                    let currentSecret = roomCredentialStore?.load()?.roomSecret ?? roomSecret
                    await self.run(serverURL: serverURL, workDir: workDir,
                                    apiKey: apiKey, sandboxKey: sandboxKey,
                                    refreshToken: refreshToken,
                                    crypto: crypto, roomID: roomID, roomSecret: currentSecret,
                                    configDir: configDir, roomCredentialStore: roomCredentialStore,
                                    refreshCount: 0)
                }
                return
            }
            let nextRefreshCount = refreshCount + 1
            let maxRefreshCycles = 3
            guard nextRefreshCount <= maxRefreshCycles else {
                log("[auth] exceeded \(maxRefreshCycles) consecutive refresh cycles — backing off 30 minutes")
                Self.sendExpiryNotification()
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(1800))
                    guard let self else { return }
                    let currentSecret = roomCredentialStore?.load()?.roomSecret ?? roomSecret
                    await self.run(serverURL: serverURL, workDir: workDir,
                                    apiKey: apiKey, sandboxKey: sandboxKey,
                                    refreshToken: refreshToken,
                                    crypto: crypto, roomID: roomID, roomSecret: currentSecret,
                                    configDir: configDir, roomCredentialStore: roomCredentialStore,
                                    refreshCount: 0)
                }
                return
            }
            log("[auth] API key expired, attempting auto-refresh...")
            Task { [weak self] in
                if let result = await Self.refreshAPIKey(serverURL: serverURL, refreshToken: rt, configDir: configDir, sandboxKey: sandboxKey) {
                    guard let self else {
                        log("[auth] refresh succeeded but AgentService was deallocated — cannot restart")
                        return
                    }
                    log("[auth] refresh succeeded, reconnecting...")
                    let currentSecret = roomCredentialStore?.load()?.roomSecret ?? roomSecret
                    await self.run(serverURL: serverURL, workDir: workDir,
                                    apiKey: result.apiKey, sandboxKey: sandboxKey,
                                    refreshToken: result.refreshToken,
                                    crypto: crypto, roomID: roomID, roomSecret: currentSecret,
                                    configDir: configDir, roomCredentialStore: roomCredentialStore,
                                    refreshCount: nextRefreshCount)
                } else {
                    log("[auth] refresh failed — will retry in 10 minutes")
                    Self.sendExpiryNotification()
                    try? await Task.sleep(for: .seconds(600))
                    guard let self else { return }
                    let currentSecret = roomCredentialStore?.load()?.roomSecret ?? roomSecret
                    await self.run(serverURL: serverURL, workDir: workDir,
                                    apiKey: apiKey, sandboxKey: sandboxKey,
                                    refreshToken: rt,
                                    crypto: crypto, roomID: roomID, roomSecret: currentSecret,
                                    configDir: configDir, roomCredentialStore: roomCredentialStore,
                                    refreshCount: nextRefreshCount)
                }
            }
        }

        relay.onAccountDeleted = {
            log("[auth] account has been deleted (HTTP 410)")
            Self.sendAccountDeletedAlert()
        }

        // Flag to track whether iOS has sent ptyReplayRequest (for backward compat fallback)
        var replayRequestReceived = false
        let replayRequestLock = NSLock()

        relay.onPairingComplete = {
            log("[pairing] ✓ Secret exchange confirmed — pairing complete")
            qrWindowController?.dismiss()
            qrWindowController = nil
            // Write marker file so CLI (setupWizard / pair command) can detect completion
            let markerPath = configDir + "/pairing_ok"
            FileManager.default.createFile(
                atPath: markerPath,
                contents: Data("\(Date().timeIntervalSince1970)".utf8),
                attributes: [.posixPermissions: 0o600])
        }

        relay.onPairingFailed = {
            log("[pairing] ✗ Secret exchange failed — iOS did not acknowledge")
        }

        relay.onPeerAuthenticated = {
            qrWindowController?.dismiss()
            qrWindowController = nil

            peerConnectedLock.lock()
            peerConnected = true
            peerConnectedLock.unlock()
            log("[peer] iPhone connected")
            if !ptyManager.isEmpty {
                // Reconnect: send session list, defer replay to ptyReplayRequest from iOS
                ptyManager.switchToLive()
                let infos = ptyManager.sessionInfoList()
                // Reconcile room config first so it has canonical session ordering
                roomConfigStore.reconcile(with: infos.map { (id: $0.sessionId, name: $0.name) })
                // Reorder infos to match roomConfig session order (stable, user-intended order)
                let orderedInfos = roomConfigStore.current.sessions.compactMap { sc in
                    infos.first(where: { $0.sessionId == sc.sessionId })
                }

                // Reset fallback flag for this connection
                replayRequestLock.lock()
                replayRequestReceived = false
                replayRequestLock.unlock()

                // Tag sessions with controller state so iOS knows which are Mac-controlled
                let taggedInfos = orderedInfos.map { info in
                    PTYSessionInfo(sessionId: info.sessionId, name: info.name,
                                   cols: info.cols, rows: info.rows,
                                   sessionType: info.sessionType, cwd: info.cwd,
                                   isMacControlled: getController(info.sessionId) == .mac)
                }
                try? relay.sendEncrypted(.ptySessions(sessions: taggedInfos))
                try? relay.sendEncrypted(.roomConfig(config: roomConfigStore.current))
                log("[pty] reconnected — sent \(taggedInfos.count) sessions (replay deferred to ptyReplayRequest)")
                try? relay.sendEncrypted(.pipelineConfig(config: pipelineConfigStore.current))

                // Re-detect git info for restored sessions (branch may have changed)
                for info in orderedInfos where info.sessionType == .git || info.sessionType == .worktree {
                    DispatchQueue.global().async {
                        let effectiveDir = ptyManager.getWorkDir(sessionId: info.sessionId) ?? workDir
                        let detected = gitManager.detectGitRepo(at: effectiveDir)
                        if detected.isGitRepo {
                            let sType: SessionType = detected.isWorktree ? .worktree : .git
                            ptyManager.updateSessionType(sessionId: info.sessionId, type: sType, branchName: detected.branchName)
                            roomConfigStore.updateSessionType(sessionId: info.sessionId, sessionType: sType, branchName: detected.branchName)
                        }
                        try? relay.sendEncrypted(.gitDetectResult(sessionId: info.sessionId, info: detected))
                    }
                }

                // Fallback for old iOS that doesn't send ptyReplayRequest:
                // After 2 seconds, if no request received, send full replay for all sessions.
                let sessionIds = orderedInfos.map { $0.sessionId }
                DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) {
                    replayRequestLock.lock()
                    let received = replayRequestReceived
                    replayRequestLock.unlock()
                    guard !received else { return }
                    log("[pty] no ptyReplayRequest received — falling back to full replay (old iOS?)")
                    for sid in sessionIds {
                        let result = ptyManager.replayIncremental(sessionId: sid, sinceOffset: nil)
                        if !result.data.isEmpty {
                            let b64 = result.data.base64EncodedString()
                            try? relay.sendEncrypted(.ptyReplay(data: b64, sessionId: sid))
                        }
                    }
                }
            } else {
                // First connect: wait for ptyCreate from iOS
                log("[pty] waiting for ptyCreate from iOS")
                try? relay.sendEncrypted(.pipelineConfig(config: pipelineConfigStore.current))
            }

            // Ensure .remotedev is in git exclude
            DispatchQueue.global().async {
                inputLogStore.ensureGitExclude(workDir: workDir)
            }

            // Send build replay if there's any buffered build output or status
            let (buildData, status, msg, action, branch, commit) = buildManager.buildReplayInfo()
            let plSteps: [String]?
            let plIndex: Int?
            let plStepStatuses: [String: String]?
            if pipelineExecutor.isPipelineRunning {
                plSteps = pipelineExecutor.pipelineSteps
                plIndex = pipelineExecutor.pipelineCurrentIndex
                plStepStatuses = pipelineExecutor.currentStepStatuses
            } else if let persisted = pipelineStateStore.current {
                plSteps = persisted.steps
                plIndex = persisted.currentIndex
                plStepStatuses = persisted.stepStatuses
            } else {
                plSteps = nil
                plIndex = nil
                plStepStatuses = nil
            }
            if !buildData.isEmpty || !status.isEmpty || plSteps != nil {
                let b64 = buildData.base64EncodedString()
                try? relay.sendEncrypted(.buildReplay(data: b64, status: status, message: msg, action: action, branch: branch, commit: commit, pipelineSteps: plSteps, pipelineCurrentIndex: plIndex, stepStatuses: plStepStatuses))
                log("[build] sent build replay — \(buildData.count) bytes, status=\(status), pipeline=\(pipelineExecutor.isPipelineRunning)")
            }
        }

        relay.onEncryptedMessage = { msg in
            switch msg {
            case .ptyCreate(let sessionId, let name, let cols, let rows, let sessionWorkDir):
                let createResult = ptyManager.createSession(sessionId: sessionId, name: name, cols: cols, rows: rows,
                                               sessionWorkDir: sessionWorkDir, sessionType: .normal,
                                               parentSessionId: nil, branchName: nil,
                                               parentRepoPath: nil, parentBranchName: nil)
                guard createResult.success else {
                    let reason = createResult.error ?? "session creation failed"
                    log("[agent] ptyCreate failed for \(sessionId) — \(reason)")
                    try? relay.sendEncrypted(.ptyCreateFailed(sessionId: sessionId, reason: reason))
                    break
                }
                roomConfigStore.addSession(sessionId: sessionId, name: name)
                roomConfigStore.updateWorktreeDir(sessionId: sessionId, directory: sessionWorkDir ?? workDir)
                // Ensure live mode so PTYHelper forwards output to agent
                ptyManager.switchToLive()
                try? relay.sendEncrypted(.ptyReady(cols: cols, rows: rows, sessionId: sessionId))
                // Send updated roomConfig so iOS gets the working directory immediately
                try? relay.sendEncrypted(.roomConfig(config: roomConfigStore.current))
                // Auto-detect git repo and resolve worktree parent
                DispatchQueue.global().async {
                    detectAndResolveGit(sessionId: sessionId, ptyManager: ptyManager)
                    try? relay.sendEncrypted(.roomConfig(config: roomConfigStore.current))
                }

            case .ptyRename(let sessionId, let name):
                ptyManager.rename(sessionId: sessionId, name: name)
                roomConfigStore.renameSession(sessionId: sessionId, name: name)
                localSocket.pushEvent(.sessionRenamed(sessionId: sessionId, newName: name), sessionId: sessionId)

            case .ptyInput(let data, let sessionId):
                if let raw = Data(base64Encoded: data) {
                    // iOS sends input → reclaim session if Mac has control
                    if getController(sessionId) == .mac {
                        iosReclaim(sessionId)
                    }
                    ptyManager.write(raw, to: sessionId)
                }

            case .ptyResize(let cols, let rows, let sessionId):
                if getController(sessionId) == .mac {
                    iosReclaim(sessionId)
                }
                ptyManager.resize(sessionId: sessionId, cols: cols, rows: rows)

            case .ptyDestroy(let sessionId):
                ptyManager.destroy(sessionId: sessionId)
                roomConfigStore.removeSession(sessionId: sessionId)
                try? relay.sendEncrypted(.ptyDestroyed(sessionId: sessionId))

            case .ptyCwd(let sessionId, let directory):
                let cleanDir = stripFileURL(directory)
                ptyManager.updateCwd(sessionId: sessionId, directory: cleanDir)

            case .ptyReplayRequest(let sessionId, let offset):
                replayRequestLock.lock()
                replayRequestReceived = true
                replayRequestLock.unlock()

                // Skip replay for Mac-controlled sessions — iOS should not receive
                // output for sessions attached by the Mac CLI.
                if getController(sessionId) == .mac {
                    log("[pty] replay skipped for \(sessionId) — Mac-controlled")
                    break
                }

                let result = ptyManager.replayIncremental(sessionId: sessionId, sinceOffset: offset)
                if !result.data.isEmpty {
                    let b64 = result.data.base64EncodedString()
                    try? relay.sendEncrypted(.ptyReplay(
                        data: b64, sessionId: sessionId,
                        offset: result.currentOffset, isFullReplay: result.isFull
                    ))
                    log("[pty] replay for \(sessionId) — \(result.data.count) bytes, full=\(result.isFull), offset=\(result.currentOffset)")
                } else {
                    // Send empty replay with offset so iOS can update its tracking
                    try? relay.sendEncrypted(.ptyReplay(
                        data: "", sessionId: sessionId,
                        offset: result.currentOffset, isFullReplay: false
                    ))
                    log("[pty] replay for \(sessionId) — already up to date, offset=\(result.currentOffset)")
                }

            case .buildListSchemes(let msgWorkDir):
                let effectiveWorkDir = stripFileURL(msgWorkDir ?? workDir)
                log("[build] received buildListSchemes, workDir=\(effectiveWorkDir)")
                DispatchQueue.global().async {
                    do {
                        let result = try buildManager.listSchemes(workDir: effectiveWorkDir)
                        log("[build] listSchemes returned \(result.schemes.count) schemes")
                        try relay.sendEncrypted(.buildSchemes(schemes: result.schemes, project: result.project))
                    } catch {
                        log("[build] listSchemes failed: \(error)")
                        try? relay.sendEncrypted(.buildStatus(status: "failed", message: error.localizedDescription, branch: nil, commit: nil))
                    }
                }

            case .buildListSchemesForProject(let projectPath):
                log("[build] received buildListSchemesForProject, path=\(projectPath)")
                DispatchQueue.global().async {
                    do {
                        let result = try buildManager.listSchemesForProject(projectPath: projectPath)
                        try relay.sendEncrypted(.buildSchemes(schemes: result.schemes, project: result.project))
                    } catch {
                        log("[build] listSchemesForProject failed: \(error)")
                        try? relay.sendEncrypted(.buildStatus(status: "failed", message: error.localizedDescription, branch: nil, commit: nil))
                    }
                }

            case .buildListProjects(let msgWorkDir):
                let effectiveWorkDir = stripFileURL(msgWorkDir ?? workDir)
                log("[build] received buildListProjects, workDir=\(effectiveWorkDir)")
                DispatchQueue.global().async {
                    do {
                        let projects = try buildManager.listProjects(workDir: effectiveWorkDir)
                        try relay.sendEncrypted(.buildProjects(projects: projects))
                    } catch {
                        log("[build] listProjects failed: \(error)")
                        try? relay.sendEncrypted(.buildStatus(status: "failed", message: error.localizedDescription, branch: nil, commit: nil))
                    }
                }

            case .buildStart(let scheme, let action, let configuration, let sdk, let teamId, let msgWorkDir):
                let effectiveWorkDir = stripFileURL(msgWorkDir ?? workDir)
                DispatchQueue.global().async {
                    do {
                        try buildManager.startBuild(scheme: scheme, action: action, configuration: configuration, sdk: sdk, teamId: teamId, workDir: effectiveWorkDir)
                    } catch {
                        log("[build] startBuild failed: \(error)")
                        try? relay.sendEncrypted(.buildStatus(status: "failed", message: error.localizedDescription, branch: nil, commit: nil))
                    }
                }

            case .buildStartInProject(let scheme, let action, let configuration, let sdk, let teamId, let projectPath):
                DispatchQueue.global().async {
                    do {
                        try buildManager.startBuildInProject(scheme: scheme, action: action, configuration: configuration, sdk: sdk, teamId: teamId, projectPath: projectPath)
                    } catch {
                        log("[build] startBuildInProject failed: \(error)")
                        try? relay.sendEncrypted(.buildStatus(status: "failed", message: error.localizedDescription, branch: nil, commit: nil))
                    }
                }

            case .buildGetSigningInfo(let scheme, let msgWorkDir):
                let effectiveWorkDir = stripFileURL(msgWorkDir ?? workDir)
                DispatchQueue.global().async {
                    // Reload ASC config state from file inside the background thread so
                    // concurrent resets are picked up.
                    buildManager.ascConfigState = ascStore.loadState()
                    do {
                        let info = try buildManager.getSigningInfo(scheme: scheme, workDir: effectiveWorkDir)
                        try relay.sendEncrypted(.buildSigningInfo(
                            team: info.team, signingStyle: info.style,
                            provisioningProfile: info.profile, signingCertificate: info.cert,
                            bundleId: info.bundleId, ascKeyConfigured: info.ascKeyConfigured,
                            ascKeyFileExists: info.ascKeyFileExists, archiveExists: info.archiveExists
                        ))
                    } catch {
                        log("[build] getSigningInfo failed: \(error)")
                        try? relay.sendEncrypted(.buildStatus(status: "failed", message: error.localizedDescription, branch: nil, commit: nil))
                    }
                }

            case .buildGetSigningInfoForProject(let scheme, let projectPath):
                DispatchQueue.global().async {
                    // Reload ASC config state from file inside the background thread so
                    // concurrent resets are picked up.
                    buildManager.ascConfigState = ascStore.loadState()
                    do {
                        let info = try buildManager.getSigningInfoForProject(scheme: scheme, projectPath: projectPath)
                        try relay.sendEncrypted(.buildSigningInfo(
                            team: info.team, signingStyle: info.style,
                            provisioningProfile: info.profile, signingCertificate: info.cert,
                            bundleId: info.bundleId, ascKeyConfigured: info.ascKeyConfigured,
                            ascKeyFileExists: info.ascKeyFileExists, archiveExists: info.archiveExists
                        ))
                    } catch {
                        log("[build] getSigningInfoForProject failed: \(error)")
                        try? relay.sendEncrypted(.buildStatus(status: "failed", message: error.localizedDescription, branch: nil, commit: nil))
                    }
                }

            case .ascConfigReset:
                ascStore.markDisabled()
                buildManager.ascConfigState = .disabled
                log("[asc] ASC config reset (disabled) from iOS")
                try? relay.sendEncrypted(.ascConfigResult(success: true, ascKeyConfigured: false, ascKeyFileExists: false, error: nil))

            case .ascConfigSet(let keyId, let issuerId, let keyPath, let keyContent):
                guard !keyId.isEmpty, !issuerId.isEmpty else {
                    try? relay.sendEncrypted(.ascConfigResult(success: false, ascKeyConfigured: false, ascKeyFileExists: false, error: "Key ID and Issuer ID are required"))
                    break
                }
                // If keyContent is provided, write it to ~/.private_keys/AuthKey_{keyId}.p8
                var effectiveKeyPath = keyPath
                if let content = keyContent, !content.isEmpty {
                    let fm = FileManager.default
                    let privateKeysDir = NSHomeDirectory() + "/.private_keys"
                    let keyFilePath = privateKeysDir + "/AuthKey_\(keyId).p8"
                    do {
                        if !fm.fileExists(atPath: privateKeysDir) {
                            try fm.createDirectory(atPath: privateKeysDir, withIntermediateDirectories: true)
                            // Set directory permissions to 0700
                            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: privateKeysDir)
                        }
                        try content.write(toFile: keyFilePath, atomically: true, encoding: .utf8)
                        // Set file permissions to 0600
                        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyFilePath)
                        effectiveKeyPath = keyFilePath
                        log("[asc] wrote key content to \(keyFilePath)")
                    } catch {
                        log("[asc] failed to write key content: \(error)")
                        try? relay.sendEncrypted(.ascConfigResult(success: false, ascKeyConfigured: false, ascKeyFileExists: false, error: "Failed to write key file: \(error.localizedDescription)"))
                        break
                    }
                }
                let config = ASCConfigStore.Config(keyId: keyId, issuerId: issuerId, keyPath: effectiveKeyPath)
                ascStore.save(config)
                let resolvedPath = ascStore.resolvedKeyPath(for: config)
                let fileExists = FileManager.default.fileExists(atPath: resolvedPath)
                buildManager.ascConfigState = .configured(ASCConfig(keyId: keyId, issuerId: issuerId, keyPath: resolvedPath))
                log("[asc] ASC config set from iOS: keyId=\(keyId) fileExists=\(fileExists)")
                try? relay.sendEncrypted(.ascConfigResult(success: true, ascKeyConfigured: true, ascKeyFileExists: fileExists, error: nil))

            case .buildCancel:
                buildManager.cancel()

            case .roomConfigUpdate(let config):
                roomConfigStore.applyUpdate(config)
                log("[roomConfig] applied update from iOS — \(config.sessions.count) sessions")

            case .pipelineConfigUpdate(let config):
                pipelineConfigStore.applyUpdate(config)
                log("[pipeline] config update from iOS")

            case .pipelineRunStep(let step, let msgWorkDir, let params):
                let effectiveWorkDir = stripFileURL(msgWorkDir ?? workDir)
                let config = pipelineConfigStore.current
                guard let stepConfig = config.steps[step] else {
                    try? relay.sendEncrypted(.buildStatus(status: "failed", message: "Unknown pipeline step: \(step)", branch: nil, commit: nil))
                    break
                }
                log("[pipeline] running step '\(step)' with \(stepConfig.tasks.count) tasks")
                DispatchQueue.global().async {
                    pipelineExecutor.runStep(step: step, tasks: stepConfig.tasks, workDir: effectiveWorkDir, params: params)
                }

            case .pipelineStart(let steps, let msgWorkDir, let params):
                let effectiveWorkDir = stripFileURL(msgWorkDir ?? workDir)
                let config = pipelineConfigStore.current
                log("[pipeline] starting pipeline with steps: \(steps)")
                DispatchQueue.global().async {
                    pipelineExecutor.runPipeline(steps: steps, config: config, workDir: effectiveWorkDir, params: params)
                }

            case .pipelineCancel:
                pipelineExecutor.cancel()
                log("[pipeline] cancelled")

            case .pipelineStateQuery:
                let state: PipelineState?
                if pipelineExecutor.isPipelineRunning {
                    state = PipelineState(
                        steps: pipelineExecutor.pipelineSteps,
                        currentIndex: pipelineExecutor.pipelineCurrentIndex,
                        overallStatus: "running",
                        stepStatuses: pipelineExecutor.currentStepStatuses
                    )
                } else {
                    state = pipelineStateStore.current
                }
                try? relay.sendEncrypted(.pipelineStateResponse(state: state))

            // MARK: - Git / Worktree handlers

            case .gitDetectRequest(let sessionId):
                DispatchQueue.global().async {
                    let effectiveDir = ptyManager.getWorkDir(sessionId: sessionId) ?? workDir
                    let info = gitManager.detectGitRepo(at: effectiveDir)
                    if info.isGitRepo {
                        let sType: SessionType = info.isWorktree ? .worktree : .git
                        ptyManager.updateSessionType(sessionId: sessionId, type: sType, branchName: info.branchName)
                        roomConfigStore.updateSessionType(sessionId: sessionId, sessionType: sType, branchName: info.branchName)
                    }
                    try? relay.sendEncrypted(.gitDetectResult(sessionId: sessionId, info: info))
                }

            case .worktreeCreate(let parentSessionId, let name, let dirLayout):
                DispatchQueue.global().async {
                    let repoPath = ptyManager.getWorkDir(sessionId: parentSessionId) ?? workDir
                    let parentBranch = ptyManager.getBranchName(sessionId: parentSessionId) ?? "main"
                    let result = gitManager.createWorktree(repoPath: repoPath, name: name, dirLayout: dirLayout ?? .grouped)
                    if result.success, let wtPath = result.path, let branch = result.branchName {
                        let wtSessionId = UUID().uuidString
                        let wtName = "wt-\(branch)"
                        let parentSize = ptyManager.getSize(sessionId: parentSessionId)
                        ptyManager.createSession(sessionId: wtSessionId, name: wtName, cols: parentSize.cols, rows: parentSize.rows,
                                                 sessionWorkDir: wtPath, sessionType: .worktree,
                                                 parentSessionId: parentSessionId, branchName: branch,
                                                 parentRepoPath: repoPath, parentBranchName: parentBranch)
                        roomConfigStore.addSession(sessionId: wtSessionId, name: wtName, sessionType: .worktree,
                                                   parentSessionId: parentSessionId, worktreeDir: wtPath, branchName: branch,
                                                   parentRepoPath: repoPath, parentBranchName: parentBranch)
                        try? relay.sendEncrypted(.ptyReady(cols: parentSize.cols, rows: parentSize.rows, sessionId: wtSessionId))
                        try? relay.sendEncrypted(.worktreeCreateResult(
                            success: true, sessionId: parentSessionId, worktreeSessionId: wtSessionId,
                            path: wtPath, branchName: branch, error: nil
                        ))
                        log("[git] worktree created: \(wtPath) branch=\(branch) session=\(wtSessionId)")
                    } else {
                        try? relay.sendEncrypted(.worktreeCreateResult(
                            success: false, sessionId: parentSessionId, worktreeSessionId: nil,
                            path: nil, branchName: nil, error: result.error
                        ))
                        log("[git] worktree create failed: \(result.error ?? "unknown")")
                    }
                }

            case .worktreeCloseCheck(let sessionId):
                DispatchQueue.global().async {
                    log("[git] worktreeCloseCheck: session=\(sessionId)")
                    let wtPath = ptyManager.getWorkDir(sessionId: sessionId) ?? ""
                    let parentPath = resolveParentRepoPath(worktreeSessionId: sessionId)
                    let wtBranch = ptyManager.getBranchName(sessionId: sessionId) ?? ""
                    let parentBranch = resolveParentBranchName(worktreeSessionId: sessionId)
                    let dirtyState = gitManager.checkDirtyState(worktreePath: wtPath, parentRepoPath: parentPath,
                                                                 parentBranch: parentBranch, worktreeBranch: wtBranch,
                                                                 sessionId: sessionId)
                    log("[git] close check for \(sessionId): isDirty=\(dirtyState.isDirty) aheadCount=\(dirtyState.aheadCount)")
                    try? relay.sendEncrypted(.worktreeCloseCheckResult(sessionId: sessionId, dirtyState: dirtyState))
                }

            case .worktreeClose(let sessionId, let merge, let ffOnly):
                DispatchQueue.global().async {
                    log("[git] worktreeClose: session=\(sessionId) merge=\(merge) ffOnly=\(ffOnly)")
                    let parentId = ptyManager.getParentSessionId(sessionId: sessionId)
                    let parentPath = resolveParentRepoPath(worktreeSessionId: sessionId)
                    let wtPath = ptyManager.getWorkDir(sessionId: sessionId) ?? ""
                    let branchName = ptyManager.getBranchName(sessionId: sessionId) ?? ""

                    if merge, !branchName.isEmpty {
                        let mergeResult = gitManager.mergeBranch(repoPath: parentPath, branchName: branchName, ffOnly: ffOnly)
                        if !mergeResult.success {
                            let opResult = GitOperationResult(success: false, message: mergeResult.message, sessionId: sessionId)
                            try? relay.sendEncrypted(.worktreeCloseResult(sessionId: sessionId, result: opResult))
                            return
                        }
                    }

                    // Log to both worktree and parent session input logs
                    let logText = merge
                        ? "Merged worktree branch '\(branchName)' and closed session"
                        : "Closed worktree session (branch '\(branchName)', not merged)"
                    let logEntry = InputLogEntry(type: "statusDescription", text: logText)

                    if !wtPath.isEmpty {
                        inputLogStore.appendEntry(logEntry, sessionId: sessionId, workDir: wtPath)
                        inputLogStore.flushToDisk(sessionId: sessionId, workDir: wtPath)
                    }

                    if let parentId = parentId {
                        inputLogStore.appendEntry(logEntry, sessionId: parentId, workDir: parentPath)
                        let parentLogData = inputLogStore.loadLog(sessionId: parentId, workDir: parentPath)
                        try? relay.sendEncrypted(.inputLogResponse(sessionId: parentId, logData: parentLogData))
                    }

                    ptyManager.destroy(sessionId: sessionId)
                    roomConfigStore.removeSession(sessionId: sessionId)
                    inputLogStore.removeLog(sessionId: sessionId)
                    try? relay.sendEncrypted(.ptyDestroyed(sessionId: sessionId))
                    let opResult = GitOperationResult(success: true, message: merge ? "Merged and closed" : "Session closed", sessionId: sessionId)
                    try? relay.sendEncrypted(.worktreeCloseResult(sessionId: sessionId, result: opResult))
                    log("[git] worktree close: success — \(opResult.message)")
                }

            case .gitMergeCheck(let parentSessionId, let worktreeSessionId):
                DispatchQueue.global().async {
                    let wtPath = ptyManager.getWorkDir(sessionId: worktreeSessionId) ?? ""
                    let parentPath = resolveParentRepoPath(worktreeSessionId: worktreeSessionId)
                    let wtBranch = ptyManager.getBranchName(sessionId: worktreeSessionId) ?? ""
                    let parentBranch = resolveParentBranchName(worktreeSessionId: worktreeSessionId)
                    let dirtyState = gitManager.checkDirtyState(
                        worktreePath: wtPath, parentRepoPath: parentPath,
                        parentBranch: parentBranch, worktreeBranch: wtBranch,
                        sessionId: worktreeSessionId)
                    try? relay.sendEncrypted(.gitMergeCheckResult(
                        sessionId: parentSessionId,
                        worktreeSessionId: worktreeSessionId,
                        dirtyState: dirtyState))
                }

            case .gitMerge(let parentSessionId, let worktreeSessionId, _, let ffOnly):
                DispatchQueue.global().async {
                    let parentPath = resolveParentRepoPath(worktreeSessionId: worktreeSessionId)
                    guard let branch = ptyManager.getBranchName(sessionId: worktreeSessionId) else {
                        let opResult = GitOperationResult(success: false, message: "No branch found for worktree", sessionId: parentSessionId)
                        try? relay.sendEncrypted(.gitMergeResult(sessionId: parentSessionId, result: opResult))
                        return
                    }

                    let result = gitManager.mergeBranch(repoPath: parentPath, branchName: branch, ffOnly: ffOnly)
                    let opResult = GitOperationResult(success: result.success, message: result.message, sessionId: parentSessionId)
                    try? relay.sendEncrypted(.gitMergeResult(sessionId: parentSessionId, result: opResult))

                    if result.success {
                        let logEntry = InputLogEntry(type: "statusDescription", text: "Merged worktree branch '\(branch)' into parent")

                        inputLogStore.appendEntry(logEntry, sessionId: parentSessionId, workDir: parentPath)
                        let parentLogData = inputLogStore.loadLog(sessionId: parentSessionId, workDir: parentPath)
                        try? relay.sendEncrypted(.inputLogResponse(sessionId: parentSessionId, logData: parentLogData))

                        let wtPath = ptyManager.getWorkDir(sessionId: worktreeSessionId) ?? ""
                        if !wtPath.isEmpty {
                            inputLogStore.appendEntry(logEntry, sessionId: worktreeSessionId, workDir: wtPath)
                            let wtLogData = inputLogStore.loadLog(sessionId: worktreeSessionId, workDir: wtPath)
                            try? relay.sendEncrypted(.inputLogResponse(sessionId: worktreeSessionId, logData: wtLogData))
                        }
                    }

                    log("[git] merge \(branch): \(result.success) — \(result.message)")
                }

            case .gitRebase(let sessionId):
                DispatchQueue.global().async {
                    let wtPath = ptyManager.getWorkDir(sessionId: sessionId) ?? ""
                    let parentBranch = resolveParentBranchName(worktreeSessionId: sessionId)
                    let result = gitManager.rebaseOnto(worktreePath: wtPath, targetBranch: parentBranch)
                    let opResult = GitOperationResult(success: result.success, message: result.message, sessionId: sessionId)
                    try? relay.sendEncrypted(.gitRebaseResult(sessionId: sessionId, result: opResult))
                    log("[git] rebase onto \(parentBranch): \(result.success) — \(result.message)")
                }

            case .worktreeSyncCheck(let sessionId):
                DispatchQueue.global().async {
                    let wtPath = ptyManager.getWorkDir(sessionId: sessionId) ?? ""
                    let wtBranch = ptyManager.getBranchName(sessionId: sessionId) ?? ""
                    let parentPath = resolveParentRepoPath(worktreeSessionId: sessionId)
                    let parentBranch = resolveParentBranchName(worktreeSessionId: sessionId)
                    var info = gitManager.checkSyncStatus(worktreePath: wtPath, parentRepoPath: parentPath,
                                                         parentBranch: parentBranch, worktreeBranch: wtBranch)
                    info = WorktreeSyncInfo(sessionId: sessionId, isSynced: info.isSynced,
                                           behindCount: info.behindCount, aheadCount: info.aheadCount)
                    try? relay.sendEncrypted(.worktreeSyncStatus(info: info))
                }

            // MARK: - Input Log handlers

            case .inputLogSave(let sessionId, let entry):
                let dir = ptyManager.getWorkDir(sessionId: sessionId) ?? workDir
                log("[inputLog] save sessionId=\(sessionId) entryId=\(entry.id) text='\(entry.text.prefix(80))'")
                inputLogStore.appendEntry(entry, sessionId: sessionId, workDir: dir)
                inputLogStore.flushToDisk(sessionId: sessionId, workDir: dir)
                try? relay.sendEncrypted(.inputLogSaveAck(sessionId: sessionId, entryId: entry.id))

            case .inputLogRequest(let sessionId):
                let dir = ptyManager.getWorkDir(sessionId: sessionId) ?? workDir
                log("[inputLog] request for \(sessionId), workDir=\(dir)")
                let logData = inputLogStore.loadLog(sessionId: sessionId, workDir: dir)
                log("[inputLog] loaded \(logData.entries.count) entries for \(sessionId)")
                try? relay.sendEncrypted(.inputLogResponse(sessionId: sessionId, logData: logData))

            case .inputLogUpdate(let sessionId, let logData):
                let dir = ptyManager.getWorkDir(sessionId: sessionId) ?? workDir
                inputLogStore.updateLog(logData, workDir: dir)

            // MARK: - Directory listing handler

            case .dirListRequest(let path):
                DispatchQueue.global().async {
                    let effectivePath = path.isEmpty ? workDir : path
                    let fm = FileManager.default
                    let entries = (try? fm.contentsOfDirectory(atPath: effectivePath)) ?? []
                    let dirs = entries
                        .filter { !$0.hasPrefix(".") && TCCHelper.isDirectory(name: $0, parentDir: effectivePath) }
                        .sorted()
                    try? relay.sendEncrypted(.dirListResponse(path: effectivePath, dirs: dirs))
                }

            default:
                break
            }
        }

        relay.onPeerDisconnected = {
            peerConnectedLock.lock()
            peerConnected = false
            peerConnectedLock.unlock()
            if !ptyManager.isEmpty {
                ptyManager.switchToBufferOnly()
                // Flush all input logs to disk so they survive agent restart
                for info in ptyManager.sessionInfoList() {
                    let dir = ptyManager.getWorkDir(sessionId: info.sessionId) ?? workDir
                    inputLogStore.flushToDisk(sessionId: info.sessionId, workDir: dir)
                }
                log("[pty] peer disconnected — buffering output for \(ptyManager.sessionCount) sessions")
            }
        }

        await relay.start()
        localSocket.shutdown()
    }

    // MARK: - Token refresh helpers

    private static func refreshAPIKey(serverURL: String, refreshToken: String, configDir: String, sandboxKey: String? = nil) async -> TokenRefreshResult? {
        await MacAgentLib.refreshAPIKey(
            serverURL: serverURL, refreshToken: refreshToken,
            configDir: configDir, sandboxKey: sandboxKey)
    }

    private static func sendExpiryNotification() {
        #if os(macOS)
        let script = """
        display notification "API key expired. Run 'termonmac login' to re-authenticate." with title "TermOnMac" subtitle "Authentication Required"
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        try? process.run()
        #endif
    }

    private static func sendAccountDeletedAlert() {
        #if os(macOS)
        let script = """
        display alert "Account Deleted" message "Your TermOnMac account has been deleted. All data will be permanently removed in 30 days.\n\nTo continue using TermOnMac, run 'termonmac login' to create a new account." as critical buttons {"OK"} default button "OK"
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        try? process.run()
        #endif
    }

    // MARK: - PTY Helper connection

    private static func socketPath(for configDir: String) -> String {
        configDir + "/pty_helper.sock"
    }
    private static func pidFilePath(for configDir: String) -> String {
        configDir + "/pty_helper.pid"
    }

    /// Try to connect to an existing helper, or start a new one.
    /// Falls back to in-process PTYManager if the helper binary is not found.
    static func connectToHelper(configDir: String, workDir: String) -> PTYManagerProtocol {
        // 1. Check for existing helper
        if let client = tryConnectExisting(configDir: configDir) {
            if client.checkVersion() {
                client.workDir = workDir
                client.syncSessions()
                log("[helper] connected to existing helper with \(client.sessionCount) sessions")
                return client
            }
            log("[helper] existing helper has incompatible protocol version — replacing")
            client.disconnect()
            killStaleHelper(configDir: configDir)
        }

        // 2. Start new helper
        if let client = startAndConnect(configDir: configDir, workDir: workDir) {
            log("[helper] started new helper process")
            return client
        }

        // 3. Fallback to in-process PTYManager
        log("[helper] falling back to in-process PTYManager")
        let mgr = PTYManager()
        mgr.workDir = workDir
        return mgr
    }

    private static func killStaleHelper(configDir: String) {
        let pidFilePath = pidFilePath(for: configDir)
        guard let pidStr = try? String(contentsOfFile: pidFilePath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
              let pid = Int32(pidStr),
              kill(pid, 0) == 0 else { return }
        log("[helper] killing stale helper (pid=\(pid))")
        kill(pid, SIGTERM)
        // Wait up to 2 seconds for exit
        for _ in 0..<20 {
            usleep(100_000)
            if kill(pid, 0) != 0 { return }
        }
        log("[helper] stale helper did not exit — sending SIGKILL")
        kill(pid, SIGKILL)
    }

    private static func tryConnectExisting(configDir: String) -> HelperClient? {
        // Check PID file
        let pidFilePath = pidFilePath(for: configDir)
        let socketPath = socketPath(for: configDir)
        guard let pidStr = try? String(contentsOfFile: pidFilePath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
              let pid = Int32(pidStr),
              kill(pid, 0) == 0 else {
            return nil
        }

        // Try connecting to socket
        let client = HelperClient()
        do {
            try client.connect(socketPath: socketPath)
            guard client.sendPing() else {
                client.disconnect()
                return nil
            }
            return client
        } catch {
            return nil
        }
    }

    private static func startAndConnect(configDir: String, workDir: String) -> HelperClient? {
        // Spawn self with pty-helper subcommand
        let mainExe = ProcessInfo.processInfo.arguments[0]
        let exePath = URL(fileURLWithPath: mainExe).resolvingSymlinksInPath().path

        guard FileManager.default.isExecutableFile(atPath: exePath) else {
            log("[helper] cannot find own binary at \(exePath)")
            return nil
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: exePath)
        let roomId = RoomCredentialStore(configDir: configDir).load()?.roomId
        var helperArgs = [
            "pty-helper",
            "--socket", socketPath(for: configDir),
            "--pid-file", pidFilePath(for: configDir),
            "--work-dir", workDir
        ]
        if let roomId { helperArgs += ["--room-id", roomId] }
        process.arguments = helperArgs
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            log("[helper] failed to start helper: \(error)")
            return nil
        }

        // Wait for socket to become available (up to 3 seconds)
        for _ in 0..<30 {
            usleep(100_000)  // 100ms
            if let client = tryConnectExisting(configDir: configDir) {
                client.workDir = workDir
                return client
            }
        }

        log("[helper] helper started but socket not available after 3s")
        return nil
    }
}
#endif
