import Foundation
import AppKit
import RemoteDevCore
import BuildKit
import CPosixHelpers
import MacAgentLib

#if os(macOS)
struct CLIRouter {
    static let version = "1.2.0-dev"
    static let buildNumber = "0"
    static let oauthCallbackPort: UInt16 = 19837

    static let configDir: String = {
        if let idx = CommandLine.arguments.firstIndex(of: "--config-dir"),
           idx + 1 < CommandLine.arguments.count {
            return NSString(string: CommandLine.arguments[idx + 1]).expandingTildeInPath
        }
        return NSString("~/.config/termonmac").expandingTildeInPath
    }()

    static func run(_ args: [String]) {
        // Skip global flags (--config-dir <value>) to find the actual command
        var commandIndex = 1
        while commandIndex < args.count {
            if args[commandIndex] == "--config-dir" {
                commandIndex += 2 // skip flag + value
            } else {
                break
            }
        }
        let command = commandIndex < args.count ? args[commandIndex] : "default"
        switch command {
        case "default":
            defaultCommand(args)
        case "rooms":
            roomsCommand()
        case "status":
            statusCommand(args)
        case "reset":
            resetCommand(args)
        case "auth":
            authCommand(args)
        case "logs":
            logsCommand(args)
        case "config":
            configCommand(args)
        case "service":
            serviceCommand(args)
        case "pty-helper":
            ptyHelperCommand(args)
        case "session":
            sessionCommand(args)
        case "attach":
            attachCommand(args)
        case "detach":
            detachCommand(args)
        case "kill":
            killCommand(args)
        case "pair":
            pairCommand()
        case "devices":
            devicesCommand(Array(args.dropFirst(commandIndex + 1)))
        case "-c", "--continue", "continue":
            continueCommand(args)
        case "tui", "--tui":
            TUIMenu.start()
        case "version", "--version", "-v":
            print("TermOnMac \(version) (build \(buildNumber))")
            if isatty(STDOUT_FILENO) != 0 {
                if let update = VersionChecker.checkForUpdate() {
                    print("Update available: \(update.currentVersion) → \(update.latestVersion)")
                    print("Run: brew upgrade termonmac/tap/termonmac")
                }
            }
        case "help", "--help", "-h":
            helpCommand()
        default:
            print("Unknown command: \(command)")
            print()
            helpCommand()
            exit(1)
        }
    }

    // MARK: - default (bare `termonmac` with no arguments)

    private static func defaultCommand(_ args: [String]) {
        // Non-interactive (launchd) → run the agent in foreground.
        // Require BOTH stdin is not a tty AND stdout is not a tty to avoid
        // accidentally entering agent mode when stdin is piped but the user
        // is watching the terminal (e.g. `echo | termonmac`).
        if isatty(STDIN_FILENO) == 0, isatty(STDOUT_FILENO) == 0 {
            runAgent(args)
            return
        }

        let identityExists = IdentityManager(configDir: configDir).identityExists()
        let hasAPIKey = loadAPIKey() != nil

        if !identityExists || !hasAPIKey {
            // First-time or incomplete setup → wizard
            setupWizard(args)
        } else {
            // Already configured → launch TUI
            TUIMenu.start()
        }
    }

    // MARK: - setup wizard

    private static func setupWizard(_ args: [String]) {
        let identityManager = IdentityManager(configDir: configDir)
        let identityExists = identityManager.identityExists()
        let roomStore = RoomCredentialStore(configDir: configDir)

        // Ensure work directory is always set (auto-default to home if missing)
        let hasWorkDir = readConfigJSON()["work_dir"] as? String != nil
        if !hasWorkDir {
            let homeDir = NSHomeDirectory()
            var json = readConfigJSON()
            json["work_dir"] = homeDir
            try? writeConfigJSON(json)
        }

        // Welcome banner
        print()
        if identityExists {
            // Returning user, only sign-in needed
            print("  TermOnMac needs a sign-in to connect.")
            print()
        } else {
            print("  ╭──────────────────────────────────────╮")
            print("  │  Welcome to TermOnMac!               │")
            print("  │  Control your Mac from your iPhone.  │")
            print("  ╰──────────────────────────────────────╯")
            print()

            // Auto: Generate Keys
            _ = identityManager.loadOrGenerateIdentity(silent: true)
            print("  ✓ Encryption keys generated")

            _ = roomStore.loadOrGenerate()
            print("  ✓ Room credentials created")

            // Auto: Room name from hostname
            let hostName = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
            let roomName = roomStore.load()?.roomName ?? hostName
            if roomStore.rename(roomName) == nil {
                print("  ✗ Failed to save room name.")
            }
            print("  ✓ Room name: \(roomName)")
            print()

            // Basic vs Advanced setup mode
            print("  How would you like to set up?")
            print()
            print("    [1] Simple")
            print("        Just press Enter through the rest. Uses default settings.")
            print("        You can change them later with 'termonmac config'.")
            print()
            print("    [2] Custom")
            print("        Configure work directory, Full Disk Access, and more.")
            print()
            let modeChoice: String
            print("  > ", terminator: "")
            let modeInput = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
            modeChoice = (modeInput == "2" || modeInput == "custom") ? "custom" : "simple"

            if modeChoice == "custom" {
                print()

                // 1. Work directory
                print("  Work Directory")
                print("  ──────────────")
                print("  The starting directory for new terminal sessions.")
                print("  Default: \(NSHomeDirectory())")
                print()
                if let path = PathInput.readPath(prompt: "  Path (Enter to keep default): ") {
                    let trimmed = path.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty {
                        let expanded = NSString(string: trimmed).expandingTildeInPath
                        let absolute = expanded.hasPrefix("/")
                            ? URL(fileURLWithPath: expanded).standardized.path
                            : URL(fileURLWithPath: FileManager.default.currentDirectoryPath + "/" + expanded).standardized.path
                        var isDir: ObjCBool = false
                        if FileManager.default.fileExists(atPath: absolute, isDirectory: &isDir), isDir.boolValue {
                            var json = readConfigJSON()
                            json["work_dir"] = absolute
                            try? writeConfigJSON(json)
                            print("  ✓ Work directory: \(absolute)")
                        } else {
                            print("  '\(absolute)' is not a valid directory. Using default.")
                            print("  ✓ Work directory: \(readConfigJSON()["work_dir"] as? String ?? NSHomeDirectory())")
                        }
                    } else {
                        print("  ✓ Work directory: \(readConfigJSON()["work_dir"] as? String ?? NSHomeDirectory())")
                    }
                } else {
                    print("  ✓ Work directory: \(readConfigJSON()["work_dir"] as? String ?? NSHomeDirectory())")
                }
                print()

                // 2. Full Disk Access
                promptFullDiskAccessIfNeeded()
            } else {
                print("  ✓ Work directory: \(readConfigJSON()["work_dir"] as? String ?? NSHomeDirectory())")
                print()
            }
        }

        // Sign In (the only interactive step)
        print("  Sign in to activate your account:")
        print("  (By signing in, you agree to the Terms of Service at termonmac.com/terms)")
        print()

        while loadAPIKey() == nil {
            print("    [1] Apple    [2] GitHub    [3] Google")
            print("  > ", terminator: "")
            guard let loginChoice = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() else {
                // EOF (Ctrl-D) — treat as skip
                print()
                print()
                print("  Setup saved. Sign in to enable connections:")
                print("    termonmac auth login <github|google|apple>")
                print()
                print("  Then run 'termonmac' to finish setup.")
                return
            }

            var loginResult: String? = nil
            switch loginChoice {
            case "1", "apple":
                loginResult = performWebLogin(provider: "apple")
            case "2", "github":
                loginResult = performWebLogin(provider: "github")
            case "3", "google":
                loginResult = performWebLogin(provider: "google")
            default:
                print("  Please enter 1, 2, or 3.")
                continue
            }

            if let name = loginResult {
                print("  ✓ Signed in as \(name)")
                // Mark TOS as accepted after successful sign-in
                DisclaimerCheck.markAccepted(configDir: configDir)
            } else {
                print("  Sign in failed. Please try again.")
            }
        }
        print()

        // Clean up stale rooms before connecting
        if let apiKey = loadAPIKey(), let creds = roomStore.load() {
            cleanupStaleRooms(apiKey: apiKey, currentRoomId: creds.roomId)
        }

        // Setup complete — install and start launchd service
        print("  ✓ Setup complete!")
        print()
        installServiceCommand()
        print()

        // Show QR code for iOS pairing (reuse pairCommand)
        pairCommand()
        print("  Run 'termonmac reset' to start over from scratch.")
        print("  Run 'termonmac help' for all commands.")
        print()
    }

    // MARK: - pair (show QR code for iOS re-pairing)

    static func pairCommand() {
        let identityManager = IdentityManager(configDir: configDir)
        let roomStore = RoomCredentialStore(configDir: configDir)

        guard let crypto = identityManager.loadIdentity(silent: true) else {
            print("No identity found. Run 'termonmac' first to complete setup.")
            exit(1)
        }
        guard let creds = roomStore.load() else {
            print("No room credentials found. Run 'termonmac' first to complete setup.")
            exit(1)
        }

        // Sentinel gate (D-I7): refuse pairing while unacknowledged trust store resets exist
        if DevicesService(configDir: configDir).pairIsBlockedBySentinel() {
            print(DevicesRenderer.pairBlockedBanner())
            exit(1)
        }

        let serverURL = resolveServerURL()

        // Generate fresh pairing token (single-use, 5 min TTL) and persist as JSON.
        // Each invocation overwrites the previous token — consecutive pair is allowed.
        let pairingToken = SessionCrypto.randomAlphanumeric(32)
        let expiration = Int(Date().timeIntervalSince1970) + PairingTokenFile.ttlSeconds
        do {
            try PairingTokenStore.write(configDir: configDir,
                                         token: pairingToken, expiresAt: expiration)
        } catch {
            print("Failed to write pairing token: \(error.localizedDescription)")
            exit(1)
        }

        // Notify a running daemon to reload (SIGHUP, pid + start_ts validated).
        _ = DaemonPidFile.signalDaemon(configDir: configDir)

        let result = QRRenderer.showQR(relayURL: serverURL, roomID: creds.roomId,
                                        pairingToken: pairingToken,
                                        macPubkey: crypto.publicKeyBase64,
                                        expiration: expiration,
                                        roomName: creds.roomName)
        let idShort = String(creds.roomId.prefix(6))
        if let name = creds.roomName {
            print("  Room: \"\(name)\" (\(idShort))")
        } else {
            print("  Room ID: \(idShort)")
        }

        // Wait for iOS to complete pairing (agent writes pairing_ok marker)
        print()
        let markerPath = configDir + "/pairing_ok"
        try? FileManager.default.removeItem(atPath: markerPath)

        if case .gui(let controller) = result {
            print("  Scan the QR code with the RemoteDev iOS app to connect.")
            print("  QR window open. Waiting for pairing confirmation... (Ctrl-C to skip)")
            signal(SIGINT, SIG_IGN)
            let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
            sigintSource.setEventHandler {
                controller.dismiss()
                exit(0)
            }
            sigintSource.resume()

            let startTime = Date()
            Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { timer in
                if FileManager.default.fileExists(atPath: markerPath) {
                    timer.invalidate()
                    print("  ✓ Pairing complete! Connection established.")
                    controller.dismiss()
                    exit(0)
                }
                if !controller.isShowing || Date().timeIntervalSince(startTime) >= 300 {
                    timer.invalidate()
                    controller.dismiss()
                }
            }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 300))
        } else {
            print("  Waiting for pairing... (Ctrl-C to cancel)")
            print()
            let startTime = Date()
            signal(SIGINT, SIG_IGN)
            let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
            sigintSource.setEventHandler { exit(0) }
            sigintSource.resume()

            Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { timer in
                if FileManager.default.fileExists(atPath: markerPath) {
                    timer.invalidate()
                    print("\r  ✓ Pairing complete! Connection established.          ")
                    exit(0)
                }
                let elapsed = Date().timeIntervalSince(startTime)
                let remaining = max(0, 300 - Int(elapsed))
                if remaining <= 0 {
                    timer.invalidate()
                    print("\r  QR code expired.                                     ")
                } else {
                    let min = remaining / 60
                    let sec = remaining % 60
                    print("\r  Expires in \(min):\(String(format: "%02d", sec))   ", terminator: "")
                    fflush(stdout)
                }
            }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 300))
        }
        print()
    }

    // MARK: - devices (list / remove / rename / acknowledge-reset)

    static func devicesCommand(_ args: [String]) {
        let sub = args.first ?? "list"
        let service = DevicesService(configDir: configDir)

        switch sub {
        case "list":
            if args.contains("--json") {
                do {
                    print(try DevicesRenderer.renderListJson(service.list()))
                } catch {
                    print("Failed to render JSON: \(error.localizedDescription)")
                    exit(1)
                }
            } else {
                print(DevicesRenderer.renderList(service.list()))
            }

        case "remove":
            guard args.count >= 2 else {
                print("Usage: termonmac devices remove <label>")
                exit(1)
            }
            let label = args[1]
            do {
                _ = try service.remove(label: label)
                // Notify daemon so it reloads the trust store.
                _ = DaemonPidFile.signalDaemon(configDir: configDir)
                print("Removed \(label).")
            } catch {
                print("\(error.localizedDescription)")
                print("Run 'termonmac devices list' to see known labels.")
                exit(1)
            }

        case "rename":
            guard args.count >= 3 else {
                print("Usage: termonmac devices rename <old-label> <new-label>")
                exit(1)
            }
            do {
                _ = try service.rename(from: args[1], to: args[2])
                print("Renamed \(args[1]) → \(args[2]).")
            } catch {
                print("\(error.localizedDescription)")
                exit(1)
            }

        case "acknowledge-reset":
            let cleared = service.acknowledgeReset()
            if cleared == 0 {
                print("No pending reset events.")
            } else {
                print("Acknowledged \(cleared) reset event\(cleared == 1 ? "" : "s").")
            }

        default:
            print("Unknown devices subcommand: \(sub)")
            print("Usage: termonmac devices [list|remove|rename|acknowledge-reset]")
            exit(1)
        }
    }

    /// Perform OAuth login via browser. Returns display name on success, nil on failure.
    private static func performWebLogin(provider: String) -> String? {
        print("  Opening browser...")
        guard let result = runOAuthFlow(provider: provider) else {
            print("  Login failed.")
            return nil
        }
        return saveOAuthResult(result)
    }

    // MARK: - Single instance lock

    /// Hold a file descriptor for the lifetime of the process so flock() stays acquired.
    private static var lockFD: Int32 = -1

    /// Acquire an exclusive lock on `<configDir>/termonmac.lock`.
    /// Exits with code 1 if another instance is already running.
    private static func acquireInstanceLock() {
        let lockPath = configDir + "/termonmac.lock"
        let fm = FileManager.default
        if !fm.fileExists(atPath: configDir) {
            try? fm.createDirectory(atPath: configDir, withIntermediateDirectories: true)
        }
        let fd = open(lockPath, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else {
            print("Cannot create lock file: \(lockPath)")
            exit(1)
        }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            // Write PID of holder for diagnostics
            var buf = [UInt8](repeating: 0, count: 32)
            lseek(fd, 0, SEEK_SET)
            let n = read(fd, &buf, buf.count)
            let holder = n > 0 ? String(bytes: buf.prefix(n), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "?" : "?"
            close(fd)
            print("termonmac is already running (PID \(holder)).")
            exit(1)
        }
        // Write our PID into the lock file
        ftruncate(fd, 0)
        lseek(fd, 0, SEEK_SET)
        let pid = String(getpid())
        pid.utf8CString.withUnsafeBufferPointer { ptr in
            _ = Darwin.write(fd, ptr.baseAddress!, pid.utf8.count)
        }
        lockFD = fd   // keep fd open → lock held until process exits
    }

    // MARK: - run agent (foreground, called by launchd or defaultCommand)

    private static func runAgent(_ args: [String]) {
        acquireInstanceLock()
        // Advertise this daemon's pid + start timestamp so `termonmac devices
        // remove` / `pair` can send SIGHUP with PID-reuse protection.
        try? DaemonPidFile.writeSelf(configDir: configDir)
        DisclaimerCheck.ensureAccepted(configDir: configDir)

        let serverURL = resolveServerURL()
        let sandboxKey = resolveSandboxKey()
        let workDir = resolveWorkDir(args)

        // Load room credentials early so startup logs use the correct category
        let roomStore = RoomCredentialStore(configDir: configDir)
        if let existingCreds = roomStore.load() {
            configureLogCategory(existingCreds.roomId)
        }

        let identityManager = IdentityManager(configDir: configDir)
        let crypto = identityManager.loadOrGenerateIdentity()

        let creds = roomStore.loadOrGenerate()
        configureLogCategory(creds.roomId)

        // Clean up stale rooms before connecting
        if let apiKey = loadAPIKey() {
            cleanupStaleRooms(apiKey: apiKey, currentRoomId: creds.roomId)
        }

        let service = AgentService()
        var agentTask: Task<Void, Never>?

        func launchAgent() {
            agentTask?.cancel()
            let currentAPIKey = loadAPIKey()
            let currentRefreshToken = loadRefreshToken()
            // Re-read room credentials on every launch so SIGHUP reload
            // picks up changes from regenerate.
            let freshCreds = roomStore.loadOrGenerate()
            configureLogCategory(freshCreds.roomId)
            agentTask = Task {
                await service.run(serverURL: serverURL, workDir: workDir,
                                  apiKey: currentAPIKey, sandboxKey: sandboxKey,
                                  refreshToken: currentRefreshToken,
                                  crypto: crypto,
                                  roomID: freshCreds.roomId, roomSecret: freshCreds.roomSecret,
                                  configDir: configDir,
                                  roomCredentialStore: roomStore)
            }
        }

        installSIGHUPHandler {
            agentTask?.cancel()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                launchAgent()
            }
        }

        launchAgent()

        // FORCE_QR_WINDOW requires AppKit's full event loop for NSWindow display.
        // dispatchMain() only drains GCD blocks; RunLoop.main.run() doesn't
        // reliably process DispatchQueue.main.async in all modes.
        // NSApp.run() is the only way to get a working AppKit event loop.
        if ProcessInfo.processInfo.environment["FORCE_QR_WINDOW"] == "1" {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            app.run()
        } else {
            dispatchMain()
        }
    }

    // MARK: - rooms

    static func roomsCommand() {
        guard let apiKey = loadAPIKey() else {
            print("Not signed in. Run 'termonmac auth login' first.")
            exit(1)
        }

        guard let json = fetchJSON(endpoint: "/api/rooms", apiKey: apiKey),
              let rooms = json["rooms"] as? [[String: Any]],
              let limit = json["limit"] as? Int,
              let tier = json["tier"] as? String else {
            print("Failed to fetch rooms.")
            exit(1)
        }

        print("Rooms: \(rooms.count)/\(limit) (\(tier) tier)")
        if rooms.isEmpty { return }

        let roomStore = RoomCredentialStore(configDir: configDir)
        let localRoomId = roomStore.load()?.roomId

        print()
        for room in rooms {
            guard let roomId = room["room_id"] as? String else { continue }
            let macConnected = room["mac_connected"] as? Bool ?? false
            let iosConnected = room["ios_connected"] as? Bool ?? false
            let lastSeen = room["last_seen"] as? Double ?? 0
            let marker = roomId == localRoomId ? "  (this mac)" : ""
            print("  \(roomId)  mac=\(macConnected ? "Y" : "N")  ios=\(iosConnected ? "Y" : "N")  \(relativeTime(from: lastSeen))\(marker)")
        }
    }

    static func relativeTime(from epochMs: Double) -> String {
        guard epochMs > 0 else { return "unknown" }
        let diff = -Date(timeIntervalSince1970: epochMs / 1000).timeIntervalSinceNow
        if diff < 0 { return "just now" }
        if diff < 60 { return "\(Int(diff))s ago" }
        if diff < 3600 { return "\(Int(diff / 60))m ago" }
        if diff < 86400 { return "\(Int(diff / 3600))h ago" }
        return "\(Int(diff / 86400))d ago"
    }

    // MARK: - help

    private static func helpCommand() {
        print("""
        Usage: termonmac [command]

        Getting started:
          termonmac             First run: setup wizard → install background service
                                After setup: check status or start service if stopped

        Commands:
          auth login <github|google>  Sign in via browser
          auth login --token <key>   Save API key directly
          auth logout                Remove API key (keeps identity & room)
          service enable             Start background service (auto-start on login)
          service disable            Stop background service
          service restart [--restart-helper]
                                     Restart the background service (--restart-helper: also restart PTY helper)
          config work-dir [path]     Get/set working directory for terminal sessions
          config room-name [name]    Get/set display name for this room
          status                     Show account and service status
          rooms                      List active rooms for this account
          session list               List active terminal sessions
          session create [--bg] <work-dir> [--name <name>]
                                     Create session (--bg: background, print ID)
          session send <id> <text>   Send text + newline to a session
          pair                       Show QR code to pair/re-pair an iOS device
          -c, --continue             Attach to session in current dir (or create one)
          attach [session-id]        Attach to a terminal session (prefix: Ctrl-])
          detach [session-id]        Detach a Mac-attached session (release to iOS)
          kill [session-id]          Kill (destroy) a terminal session
          logs [--stream] [-a]       Show agent logs (last 1h, or stream live)
          reset                      Reset config and start fresh
          tui                        Interactive menu (arrow-key navigation)
          version               Show version
          help                  Show this help message
        """)
    }

    // MARK: - status

    static func statusCommand(_ args: [String]) {
        let showHistory = args.contains("--history")

        print("TermOnMac v\(version) (build \(buildNumber))")
        print("────────────────")

        // Service state
        if isServiceLoaded() {
            print("Service:   running")
        } else {
            let plistPath = NSString(string: "~/Library/LaunchAgents/\(plistLabel).plist").expandingTildeInPath
            if FileManager.default.fileExists(atPath: plistPath) {
                print("Service:   stopped (plist installed)")
            } else {
                print("Service:   not installed")
            }
        }

        // Identity
        let pubPath = configDir + "/identity.pub"
        if let pub = try? String(contentsOfFile: pubPath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !pub.isEmpty {
            let short = String(pub.prefix(16))
            print("Identity:  \(short)...")
        } else {
            print("Identity:  (not generated)")
        }

        // API Key
        let apiKeyPath = configDir + "/api_key"
        let apiKey: String?
        if let key = try? String(contentsOfFile: apiKeyPath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            let masked: String
            if key.count > 12 {
                masked = String(key.prefix(8)) + "..." + String(key.suffix(4))
            } else {
                masked = String(key.prefix(4)) + "..."
            }
            print("API Key:   \(masked)")
            apiKey = key
        } else {
            print("API Key:   (not set)")
            apiKey = nil
        }

        // Room
        let roomStore = RoomCredentialStore(configDir: configDir)
        if let creds = roomStore.load() {
            let idShort = String(creds.roomId.prefix(6))
            let name = creds.roomName.map { " \"\($0)\"" } ?? ""
            print("Room:      \(idShort)\(name)")
        } else {
            print("Room:      (not created)")
        }

        // Work dir
        let configJSON = readConfigJSON()
        if let wd = configJSON["work_dir"] as? String {
            print("Work dir:  \(wd)")
        } else {
            print("Work dir:  (not configured, using cwd)")
        }

        // Config files
        print()
        print("Config (\(configDir)/):")
        let identityExists = IdentityManager(configDir: configDir).identityExists()
        let idMark = identityExists ? "\u{2713}" : "\u{2717}"
        let idPadding = String(repeating: " ", count: max(1, 20 - "identity.key".count))
        print("  identity.key\(idPadding)\(idMark)  Curve25519 private key")

        let knownFiles: [(name: String, description: String)] = [
            ("identity.pub",      "Curve25519 public key"),
            ("api_key",           "API authentication key"),
            ("room.json",         "Room credentials"),
            ("room_config.json",  "Session layout"),
            ("paired",            "iOS device has paired successfully"),
            (ASCConfigStore.filename, "ASC API Key configuration"),
            ("config.json",       "Persistent config (relay URL, work dir)"),
            (TrustStore.fileName, "Trusted iOS devices (multi-key)"),
            (PairingTokenStore.fileName, "Active pairing token (single-use)"),
        ]
        let fm = FileManager.default
        for file in knownFiles {
            let exists = fm.fileExists(atPath: configDir + "/" + file.name)
            let mark = exists ? "\u{2713}" : "\u{2717}"
            let padding = String(repeating: " ", count: max(1, 20 - file.name.count))
            print("  \(file.name)\(padding)\(mark)  \(file.description)")
        }

        // Usage (remote)
        guard let apiKey = apiKey else {
            print()
            print("Not signed in. Run 'termonmac auth login' to sign in (required for connections).")
            return
        }

        if let json = fetchJSON(endpoint: "/usage", apiKey: apiKey),
           json["total_tokens"] != nil || json["remaining"] != nil {
            print()
            let periodDisplay = (json["period_label"] as? String) ?? (json["period"] as? String)
            if let p = periodDisplay {
                print("Usage (\(p)):")
            } else {
                print("Usage:")
            }
            if let totalTokens = json["total_tokens"] as? Int,
               let lim = json["limit"] as? Int, lim > 0 {
                let pct = min(100, max(0, Int(Double(totalTokens) / Double(lim) * 100)))
                print("  Used:         \(pct)%")
                print("  Remaining:    \(100 - pct)%")
            } else {
                print("  Quota:        unlimited")
            }
            if let ts = json["last_updated"] as? Double {
                let date = Date(timeIntervalSince1970: ts / 1000)
                let fmt = ISO8601DateFormatter()
                print("  Last updated: \(fmt.string(from: date))")
            }
            if let resetsAt = json["resets_at"] as? String {
                let fmt = ISO8601DateFormatter()
                fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                var resetDate = fmt.date(from: resetsAt)
                if resetDate == nil {
                    fmt.formatOptions = [.withInternetDateTime]
                    resetDate = fmt.date(from: resetsAt)
                }
                if let rd = resetDate {
                    let diff = rd.timeIntervalSinceNow
                    if diff > 0 {
                        let h = Int(diff) / 3600
                        let m = (Int(diff) % 3600) / 60
                        print("  Resets in:    \(h)h \(m)m")
                    } else {
                        print("  Resets:       now")
                    }
                }
            }
            // Extra quota (welcome bonus)
            if let extra = json["extra_quota"] as? [String: Any],
               let active = extra["active"] as? Bool, active {
                let remaining = extra["remaining"] as? Int ?? 0
                let limit = extra["limit"] as? Int ?? 0
                let bonusPct = limit > 0 ? min(100, max(0, Int(Double(remaining) / Double(limit) * 100))) : 0
                print("  Welcome bonus: \(bonusPct)% remaining")
                if let expiresStr = extra["expires_at"] as? String {
                    let fmt = ISO8601DateFormatter()
                    fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    var expiresDate = fmt.date(from: expiresStr)
                    if expiresDate == nil {
                        fmt.formatOptions = [.withInternetDateTime]
                        expiresDate = fmt.date(from: expiresStr)
                    }
                    if let ed = expiresDate {
                        let diff = ed.timeIntervalSinceNow
                        if diff > 0 {
                            let d = Int(diff) / 86400
                            let h = (Int(diff) % 86400) / 3600
                            print("  Expires in:    \(d)d \(h)h")
                        } else {
                            print("  Bonus:         expired")
                        }
                    }
                }
            }
        } else {
            print("\nUsage:     (failed to fetch)")
        }

        // Room count (debug only — not shown to user)
        if let json = fetchJSON(endpoint: "/api/rooms", apiKey: apiKey),
           let rooms = json["rooms"] as? [[String: Any]] {
            let total = rooms.count
            let stale = rooms.filter { ($0["mac_connected"] as? Bool) == false }.count
            log("[rooms] status check: total=\(total), stale=\(stale)")
        }

        // History (--history flag)
        if showHistory {
            print()
            if let json = fetchJSON(endpoint: "/usage/history", apiKey: apiKey),
               let history = json["history"] as? [[String: Any]] {
                if history.isEmpty {
                    print("No usage history found.")
                } else {
                    print(UsageHistoryFormatter.format(history))
                }
            } else {
                print("Failed to fetch usage history.")
            }
        }
    }

    // MARK: - auth

    private static func authCommand(_ args: [String]) {
        var positionalArgs = Array(args.dropFirst(2))
        while let idx = positionalArgs.firstIndex(of: "--config-dir") {
            positionalArgs.remove(at: idx)
            if idx < positionalArgs.count {
                positionalArgs.remove(at: idx)
            }
        }
        guard let sub = positionalArgs.first else {
            print("Usage: termonmac auth <login|logout>")
            exit(1)
        }
        switch sub {
        case "login":
            loginCommand(args)
        case "logout":
            logoutCommand()
        default:
            print("Unknown auth command: \(sub)")
            print("Usage: termonmac auth <login|logout>")
            exit(1)
        }
    }

    // MARK: - logout

    static func logoutCommand() {
        let apiKeyPath = configDir + "/api_key"
        let fm = FileManager.default

        guard fm.fileExists(atPath: apiKeyPath) else {
            print("No API key found at \(apiKeyPath). Already logged out.")
            return
        }

        // Read key before deleting so we can revoke server-side
        let apiKey = (try? String(contentsOfFile: apiKeyPath, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Revoke on server
        if let apiKey = apiKey, !apiKey.isEmpty {
            let httpURL = httpBaseURL()
            if let url = URL(string: httpURL + "/auth/revoke") {
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                request.timeoutInterval = 10

                let sem = DispatchSemaphore(value: 0)
                var revokeOk = false

                URLSession.shared.dataTask(with: request) { data, response, error in
                    defer { sem.signal() }
                    if let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200 {
                        revokeOk = true
                    }
                }.resume()

                sem.wait()

                if revokeOk {
                    print("API key revoked on server.")
                } else {
                    print("Warning: could not revoke server-side. Removing local key anyway.")
                }
            }
        }

        // Delete local key
        do {
            try fm.removeItem(atPath: apiKeyPath)
            print("API key removed from \(apiKeyPath)")
        } catch {
            print("Failed to remove API key: \(error.localizedDescription)")
        }

        // Delete refresh token
        let refreshTokenPath = configDir + "/refresh_token"
        if fm.fileExists(atPath: refreshTokenPath) {
            try? fm.removeItem(atPath: refreshTokenPath)
            print("Refresh token removed.")
        }

        triggerReloadIfRunning()
        print("Identity key and room credentials are preserved.")
    }

    // MARK: - login

    static func loginCommand(_ args: [String]) {
        // Filter out --config-dir <value> flag pairs
        // args: [termonmac, auth, login, ...] → drop 3
        var filteredArgs = Array(args.dropFirst(3))
        while let idx = filteredArgs.firstIndex(of: "--config-dir") {
            filteredArgs.remove(at: idx)
            if idx < filteredArgs.count {
                filteredArgs.remove(at: idx)
            }
        }

        // --token shortcut: directly save API key
        if filteredArgs.first == "--token" {
            guard filteredArgs.count > 1 else {
                print("Usage: termonmac auth login --token <api_key>")
                exit(1)
            }
            let token = filteredArgs[1]
            let apiKeyPath = configDir + "/api_key"
            let fm = FileManager.default
            if !fm.fileExists(atPath: configDir) {
                try? fm.createDirectory(atPath: configDir, withIntermediateDirectories: true)
            }
            do {
                try token.write(toFile: apiKeyPath, atomically: true, encoding: .utf8)
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: apiKeyPath)
                print("API key saved to \(apiKeyPath)")
                triggerReloadIfRunning()
            } catch {
                print("Failed to save API key: \(error.localizedDescription)")
            }
            return
        }

        // Parse provider argument
        guard let provider = filteredArgs.first,
              ["github", "google", "apple"].contains(provider) else {
            print("Usage: termonmac auth login <github|google|apple>")
            print("       termonmac auth login --token <api_key>")
            exit(1)
        }

        // Check if already logged in
        let apiKeyPath = configDir + "/api_key"
        if let existingKey = try? String(contentsOfFile: apiKeyPath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !existingKey.isEmpty {
            if let profile = fetchJSON(endpoint: "/profile", apiKey: existingKey),
               let name = profile["name"] as? String ?? profile["email"] as? String {
                let email = (profile["email"] as? String).map { " (\($0))" } ?? ""
                print("Already logged in as \(name)\(email).")
                print("Re-login will replace the current session. Continue? [y/N] ", terminator: "")
                guard let answer = readLine()?.lowercased(), answer == "y" || answer == "yes" else {
                    print("Cancelled.")
                    return
                }
            } else {
                // API key exists but can't verify account (expired/deleted) — proceed directly
                print("Current session is invalid. Signing in with a new account...")
            }
        }

        print("Opening browser...")
        guard let result = runOAuthFlow(provider: provider) else {
            print("Login failed.")
            return
        }

        saveOAuthResult(result)
        let displayName = result.name ?? result.email ?? "unknown"
        let displayEmail = result.email.map { " (\($0))" } ?? ""
        print("Logged in as \(displayName)\(displayEmail)")
        print("  API key saved to \(configDir)/api_key")
        triggerReloadIfRunning()
        if !isServiceLoaded() {
            print("  Run 'termonmac service enable' to start the background service.")
        }
    }

    // MARK: - reset

    static func resetCommand(_ args: [String]) {
        print("⚠️  This will:")
        print("  • Stop the background service")
        print("  • Delete config (identity, room, API key)")
        print("  • iOS devices will need to re-pair")
        if FileManager.default.fileExists(atPath: configDir + "/" + ASCConfigStore.filename) {
            print("  (ASC upload key is preserved)")
        }
        print("")
        print("Continue? [y/N] ", terminator: "")
        guard let answer = readLine()?.lowercased(), answer == "y" || answer == "yes" else {
            print("Cancelled.")
            return
        }

        // Stop and remove background service before deleting config
        if isServiceLoaded() || FileManager.default.fileExists(atPath:
            NSString(string: "~/Library/LaunchAgents/\(plistLabel).plist").expandingTildeInPath) {
            uninstallService()
            print("✓ Service stopped.")
        }

        do {
            let reset = ConfigReset(configDir: configDir, preserve: [ASCConfigStore.filename])
            let count = try reset.deleteAll()
            IdentityManager(configDir: configDir).deleteIdentity()
            print("✓ Deleted \(count) config file\(count == 1 ? "" : "s").")
            print()
            print("Start fresh setup now? [Y/n] ", terminator: "")
            let setupAnswer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
            if setupAnswer.isEmpty || setupAnswer == "y" || setupAnswer == "yes" {
                print()
                setupWizard(args)
            } else {
                print("Run 'termonmac' when you're ready to set up again.")
            }
        } catch {
            print("Reset failed: \(error.localizedDescription)")
        }
    }

    // MARK: - logs

    static func logsCommand(_ args: [String]) {
        let isStream = args.contains("--stream") || args.contains("-f")
        let showAll = args.contains("--all") || args.contains("-a")

        // Filter by this config-dir's room ID unless --all is passed
        var predicate = "subsystem == '\(logSubsystem)'"
        if !showAll {
            let roomStore = RoomCredentialStore(configDir: configDir)
            if let creds = roomStore.load() {
                predicate += " AND category == '\(creds.roomId)'"
            } else {
                fputs("⚠ No room credentials in \(configDir)/room.json — cannot filter by room.\n", stderr)
                fputs("  Use --config-dir <path> or --all to see all rooms.\n\n", stderr)
                predicate += " AND category == 'general'"
            }
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        if isStream {
            process.arguments = ["stream", "--predicate", predicate,
                                 "--style", "compact"]
        } else {
            process.arguments = ["show", "--predicate", predicate,
                                 "--last", "1h", "--style", "compact"]
        }
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        try? process.run()
        guard process.isRunning else { return }

        // Terminate child `log` process when parent receives signals,
        // preventing orphaned `log stream` processes.
        let signals: [Int32] = [SIGINT, SIGTERM, SIGHUP]
        let sources = signals.map { sig -> DispatchSourceSignal in
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            src.setEventHandler { process.terminate() }
            src.resume()
            return src
        }

        process.waitUntilExit()
        sources.forEach { $0.cancel() }
    }

    // MARK: - config

    static func configCommand(_ args: [String]) {
        // Filter out --config-dir <value> flag pairs
        var positionalArgs = Array(args.dropFirst(2))
        while let idx = positionalArgs.firstIndex(of: "--config-dir") {
            positionalArgs.remove(at: idx)
            if idx < positionalArgs.count {
                positionalArgs.remove(at: idx)
            }
        }
        guard let key = positionalArgs.first else {
            print("Usage: termonmac config <key> [value]")
            print()
            print("Keys:")
            print("  work-dir           [path|--unset]  Get/set working directory for the agent")
            print("  room-name          [name]          Get/set display name for this room")
            print("  attach-status-bar  [on|off]        Get/set status bar in attach mode (default: on)")
            print("  attach-prefix-key  [ctrl-X]        Get/set prefix key for attach mode (default: ctrl-])")
            print("  full-disk-access                   Check & enable Full Disk Access")
            exit(1)
        }
        switch key {
        case "work-dir":
            configWorkDir(Array(positionalArgs.dropFirst()))
        case "room-name":
            configRoomName(Array(positionalArgs.dropFirst()))
        case "attach-status-bar":
            configAttachStatusBar(Array(positionalArgs.dropFirst()))
        case "attach-prefix-key":
            configAttachPrefixKey(Array(positionalArgs.dropFirst()))
        case "full-disk-access":
            configFullDiskAccess()
        default:
            print("Unknown config key: \(key)")
            print("Available keys: work-dir, room-name, attach-status-bar, attach-prefix-key, full-disk-access")
            exit(1)
        }
    }

    private static func configWorkDir(_ args: [String]) {
        // No args → show current value
        guard let arg = args.first else {
            let json = readConfigJSON()
            if let wd = json["work_dir"] as? String {
                print(wd)
            } else {
                print("(not set)")
            }
            return
        }

        // --unset → remove from config
        if arg == "--unset" {
            var json = readConfigJSON()
            json.removeValue(forKey: "work_dir")
            do {
                try writeConfigJSON(json)
                print("work-dir unset.")
            } catch {
                print("Failed to write config: \(error.localizedDescription)")
            }
            return
        }

        // Set value — expand ~ and resolve relative paths
        let expanded = NSString(string: arg).expandingTildeInPath
        let absolute: String
        if expanded.hasPrefix("/") {
            absolute = URL(fileURLWithPath: expanded).standardized.path
        } else {
            let cwd = FileManager.default.currentDirectoryPath
            absolute = URL(fileURLWithPath: cwd + "/" + expanded).standardized.path
        }

        // Validate directory exists
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: absolute, isDirectory: &isDir), isDir.boolValue else {
            print("Error: '\(absolute)' is not an existing directory.")
            exit(1)
        }

        var json = readConfigJSON()
        json["work_dir"] = absolute
        do {
            try writeConfigJSON(json)
            print("work-dir set to: \(absolute)")
        } catch {
            print("Failed to write config: \(error.localizedDescription)")
        }
    }

    private static func configRoomName(_ args: [String]) {
        let roomStore = RoomCredentialStore(configDir: configDir)
        // No args → show current value
        guard !args.isEmpty else {
            if let creds = roomStore.load(), let name = creds.roomName {
                print(name)
            } else {
                print("(not set)")
            }
            return
        }
        let name = args.joined(separator: " ")
        if roomStore.rename(name) != nil {
            print("room-name set to: \(name)")
        } else {
            print("No room credentials found. Run 'termonmac' first to set up.")
            exit(1)
        }
    }

    private static func configAttachStatusBar(_ args: [String]) {
        guard let arg = args.first else {
            let json = readConfigJSON()
            let enabled = (json["attach_status_bar"] as? Bool) ?? true
            print(enabled ? "on" : "off")
            return
        }
        switch arg.lowercased() {
        case "on", "true", "1":
            var json = readConfigJSON()
            json["attach_status_bar"] = true
            do {
                try writeConfigJSON(json)
                print("attach-status-bar set to: on")
            } catch {
                print("Failed to write config: \(error.localizedDescription)")
            }
        case "off", "false", "0":
            var json = readConfigJSON()
            json["attach_status_bar"] = false
            do {
                try writeConfigJSON(json)
                print("attach-status-bar set to: off")
            } catch {
                print("Failed to write config: \(error.localizedDescription)")
            }
        default:
            print("Usage: termonmac config attach-status-bar [on|off]")
            exit(1)
        }
    }

    /// Returns true if the status bar is enabled (default: true).
    static func isAttachStatusBarEnabled() -> Bool {
        (readConfigJSON()["attach_status_bar"] as? Bool) ?? true
    }

    /// Toggle attach status bar setting. Returns the new value.
    @discardableResult
    static func toggleAttachStatusBar() -> Bool {
        let newValue = !isAttachStatusBarEnabled()
        var json = readConfigJSON()
        json["attach_status_bar"] = newValue
        try? writeConfigJSON(json)
        return newValue
    }

    /// Returns the configured work directory, or nil if not set.
    static func currentWorkDir() -> String? {
        readConfigJSON()["work_dir"] as? String
    }

    /// Returns the configured room name, or nil if not set.
    static func currentRoomName() -> String? {
        RoomCredentialStore(configDir: configDir).load()?.roomName
    }

    /// Fetch the user profile from the relay server. Returns nil if not logged in or network error.
    static func fetchProfile() -> [String: Any]? {
        guard let apiKey = loadAPIKey() else { return nil }
        return fetchJSON(endpoint: "/profile", apiKey: apiKey)
    }

    /// Fetch rooms list from the relay server. Returns nil if not logged in or network error.
    static func fetchRooms() -> (rooms: [[String: Any]], limit: Int, tier: String)? {
        guard let apiKey = loadAPIKey() else { return nil }
        guard let json = fetchJSON(endpoint: "/api/rooms", apiKey: apiKey),
              let rooms = json["rooms"] as? [[String: Any]],
              let limit = json["limit"] as? Int,
              let tier = json["tier"] as? String else {
            return nil
        }
        return (rooms, limit, tier)
    }

    /// Returns the local room ID, or nil if no room credentials exist.
    static func localRoomId() -> String? {
        RoomCredentialStore(configDir: configDir).load()?.roomId
    }

    // MARK: - Attach prefix key config

    /// Parse a "ctrl-X" string to its control byte value. Returns nil if invalid.
    private static func parsePrefixKey(_ s: String) -> UInt8? {
        let lower = s.lowercased()
        guard lower.hasPrefix("ctrl-"), lower.count == 6 else { return nil }
        let ch = lower.last!
        switch ch {
        case "a"..."z":
            return ch.asciiValue! - UInt8(ascii: "a") + 1
        case "@":
            return 0x00
        case "[":
            return 0x1B
        case "\\":
            return 0x1C
        case "]":
            return 0x1D
        case "^":
            return 0x1E
        case "_":
            return 0x1F
        default:
            return nil
        }
    }

    /// Convert a prefix byte to caret-notation display label, e.g. 0x1D → "^]".
    private static func prefixDisplayLabel(_ byte: UInt8) -> String {
        if byte <= 0x1F {
            return "^\(Character(UnicodeScalar(byte + 0x40)))"
        }
        return "^?"
    }

    /// Returns the configured prefix byte (default: 0x1D = Ctrl-]).
    static func attachPrefixByte() -> UInt8 {
        guard let keyStr = readConfigJSON()["attach_prefix_key"] as? String,
              let byte = parsePrefixKey(keyStr) else {
            return 0x1D
        }
        return byte
    }

    /// Returns the display label for the configured prefix, e.g. "^]".
    static func attachPrefixLabel() -> String {
        prefixDisplayLabel(attachPrefixByte())
    }

    private static func configAttachPrefixKey(_ args: [String]) {
        // No args → show current value
        guard let arg = args.first else {
            let json = readConfigJSON()
            let key = (json["attach_prefix_key"] as? String) ?? "ctrl-]"
            print(key)
            return
        }

        // Parse & validate
        guard let byte = parsePrefixKey(arg) else {
            print("Invalid prefix key: '\(arg)'")
            print("Format: ctrl-a through ctrl-], e.g. ctrl-a, ctrl-b, ctrl-]")
            exit(1)
        }

        // Reject dangerous keys
        let dangerous: [UInt8: String] = [
            0x03: "ctrl-c (SIGINT)",
            0x04: "ctrl-d (EOF)",
            0x1A: "ctrl-z (SIGTSTP)",
            0x1B: "ctrl-[ (ESC, conflicts with escape sequences)",
            0x1C: "ctrl-\\ (SIGQUIT)",
        ]
        if let reason = dangerous[byte] {
            print("Error: \(reason) cannot be used as prefix key.")
            exit(1)
        }

        var json = readConfigJSON()
        json["attach_prefix_key"] = arg.lowercased()
        do {
            try writeConfigJSON(json)
            print("attach-prefix-key set to: \(arg.lowercased()) (\(prefixDisplayLabel(byte)))")
        } catch {
            print("Failed to write config: \(error.localizedDescription)")
        }
    }

    private static func configFullDiskAccess() {
        if TCCHelper.hasFullDiskAccess() {
            print("✓ Full Disk Access is enabled.")
        } else {
            print("Full Disk Access is not enabled.")
            print()
            print("Without it, terminal sessions cannot access:")
            print("  • iCloud Drive (~/Library/Mobile Documents)")
            print("  • Desktop, Documents, Downloads")
            print("  • Photos, Mail, Messages, and other protected data")
            print()
            promptFullDiskAccessOpen()
        }
    }

    /// Interactive prompt during setup wizard — checks FDA and offers to open System Settings.
    private static func promptFullDiskAccessIfNeeded() {
        if TCCHelper.hasFullDiskAccess() {
            print("  ✓ Full Disk Access is enabled")
            print()
            return
        }

        print("  Full Disk Access (Optional)")
        print("  ───────────────────────────")
        print("  Without Full Disk Access, terminal sessions cannot access")
        print("  iCloud Drive, Desktop, Documents, or other protected folders.")
        print("  Requires Mac screen access to enable in System Settings.")
        print()
        promptFullDiskAccessOpen(indent: "  ")
        print()
    }

    /// Asks user whether to open System Settings, then waits for FDA to be granted.
    private static func promptFullDiskAccessOpen(indent: String = "") {
        print("\(indent)Open System Settings? [Y/n]: ", terminator: "")
        let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        if answer == "n" || answer == "no" {
            print("\(indent)Skipped. You can enable it later with: termonmac config full-disk-access")
            return
        }
        TCCHelper.openFullDiskAccessSettings()
        let binaryPath = TCCHelper.revealBinaryInFinder()
        print()
        print("\(indent)System Settings and Finder opened.")
        print("\(indent)The termonmac binary is highlighted in Finder:")
        print("\(indent)  \(binaryPath)")
        print()
        print("\(indent)To grant Full Disk Access:")
        print("\(indent)  1. In System Settings, click the \"+\" button")
        print("\(indent)  2. Press Cmd+Shift+G, paste the path above, and click Open")
        print("\(indent)  — or drag the highlighted file from Finder into the list")
        print()
        print("\(indent)Press Enter when done...")
        _ = readLine()
        if TCCHelper.hasFullDiskAccess() {
            print("\(indent)✓ Full Disk Access is now enabled!")
        }
    }

    // MARK: - pty-helper (internal subcommand)

    private static func ptyHelperCommand(_ args: [String]) {
        func argValue(_ flag: String) -> String? {
            if let idx = args.firstIndex(of: flag), idx + 1 < args.count {
                return args[idx + 1]
            }
            return nil
        }

        let socketPath = argValue("--socket") ?? (configDir + "/pty_helper.sock")
        let pidFilePath = argValue("--pid-file") ?? (configDir + "/pty_helper.pid")
        let workDir = argValue("--work-dir")

        if let roomId = argValue("--room-id") {
            configureLogCategory(roomId)
        }

        setsid()

        let fm = FileManager.default
        if !fm.fileExists(atPath: configDir) {
            try? fm.createDirectory(atPath: configDir, withIntermediateDirectories: true)
        }

        let server = HelperServer(socketPath: socketPath, workDir: workDir)
        do {
            try server.start()
        } catch {
            log("[ptyHelper] failed to start server: \(error)")
            exit(1)
        }

        let pid = ProcessInfo.processInfo.processIdentifier
        try? "\(pid)".write(toFile: pidFilePath, atomically: true, encoding: .utf8)
        log("[ptyHelper] started — pid=\(pid) socket=\(socketPath)")

        signal(SIGINT, SIG_IGN)
        signal(SIGHUP, SIG_IGN)
        signal(SIGPIPE, SIG_IGN)

        let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        sigterm.setEventHandler {
            log("[ptyHelper] SIGTERM received — shutting down")
            server.shutdown()
            try? fm.removeItem(atPath: pidFilePath)
            exit(0)
        }
        sigterm.resume()

        dispatchMain()
    }

    // MARK: - Local socket helpers

    /// Connect to agent.sock and return the fd. Exits on failure.
    static func connectToAgentSocket() -> Int32 {
        let socketPath = configDir + "/agent.sock"

        guard FileManager.default.fileExists(atPath: socketPath) else {
            print("Service is not running. Start it with: termonmac service enable")
            exit(1)
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            print("Failed to create socket")
            exit(1)
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
                pathBytes.withUnsafeBufferPointer { src in
                    _ = memcpy(dest, src.baseAddress!, src.count)
                }
            }
        }

        let addrLen = socklen_t(MemoryLayout<sa_family_t>.size + pathBytes.count)
        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(fd, sockPtr, addrLen)
            }
        }
        guard connectResult == 0 else {
            print("Cannot connect to service. Is it running?")
            close(fd)
            exit(1)
        }
        return fd
    }

    /// Connect to agent.sock, returning nil instead of exiting on failure.
    static func connectToAgentSocketOrNil() -> Int32? {
        let socketPath = configDir + "/agent.sock"
        guard FileManager.default.fileExists(atPath: socketPath) else { return nil }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
                pathBytes.withUnsafeBufferPointer { src in
                    _ = memcpy(dest, src.baseAddress!, src.count)
                }
            }
        }

        let addrLen = socklen_t(MemoryLayout<sa_family_t>.size + pathBytes.count)
        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(fd, sockPtr, addrLen)
            }
        }
        guard connectResult == 0 else { close(fd); return nil }
        return fd
    }

    /// Attach to a session by ID.  Called from TUI after teardown.
    static func runAttach(sessionId: String) {
        attachCommand(["termonmac", "attach", sessionId])
    }

    private static var localRequestId: UInt64 = 0
    private static func nextLocalId() -> UInt64 {
        localRequestId += 1
        return localRequestId
    }

    /// Send a request and read the response.
    static func localRequest(_ msg: LocalIPC.RequestMessage, fd: Int32) -> LocalIPC.ResponseMessage? {
        let request = LocalIPC.Request(id: nextLocalId(), message: msg)
        do {
            try IPCFraming.writeFrame(request, to: fd)
        } catch { return nil }
        guard let response = try? IPCFraming.readFrame(LocalIPC.Response.self, from: fd) else { return nil }
        return response.message
    }

    /// Send a fire-and-forget request (no response expected).
    private static func localSend(_ msg: LocalIPC.RequestMessage, fd: Int32) {
        let request = LocalIPC.Request(id: nextLocalId(), message: msg)
        try? IPCFraming.writeFrame(request, to: fd)
    }

    // MARK: - Nested session detection

    /// Check if running inside a managed PTY session (env var or ttyname match).
    static func isInsideManagedSession(_ sessions: [LocalSessionInfo]) -> Bool {
        if ProcessInfo.processInfo.environment["TERMONMAC_SESSION"] != nil { return true }
        guard isatty(STDIN_FILENO) != 0, let name = ttyname(STDIN_FILENO) else { return false }
        let myTTY = String(cString: name)
        return sessions.contains { $0.slavePath == myTTY }
    }

    // MARK: - Session helpers

    /// Create a PTY session on the agent. Returns (fd, sessionId) on success. Exits on failure.
    private static func createSessionOnAgent(
        workDir: String, name: String = "zsh",
        cols: Int, rows: Int
    ) -> (fd: Int32, sessionId: String) {
        let fd = connectToAgentSocket()
        guard case .createSessionResult(let newId, let error) = localRequest(
            .createSession(name: name, cols: cols, rows: rows, workDir: workDir), fd: fd
        ) else {
            print("Failed to create session")
            close(fd)
            exit(1)
        }
        guard let newId else {
            print("Create session failed: \(error ?? "unknown error")")
            close(fd)
            exit(1)
        }
        return (fd, newId)
    }

    // MARK: - session (subcommand group)

    private static func sessionCommand(_ args: [String]) {
        var commandIndex = 1
        while commandIndex < args.count {
            if args[commandIndex] == "--config-dir" { commandIndex += 2 }
            else { break }
        }
        // commandIndex -> "session"; subcommand is commandIndex+1
        let subIndex = commandIndex + 1
        guard subIndex < args.count else {
            print("Usage: termonmac session <list|create|send>")
            exit(1)
        }
        switch args[subIndex] {
        case "list":
            sessionListCommand()
        case "create":
            sessionCreateCommand(args)
        case "send":
            sessionSendCommand(args)
        default:
            print("Unknown session command: \(args[subIndex])")
            print("Usage: termonmac session <list|create|send>")
            exit(1)
        }
    }

    // MARK: session list

    private static func sessionListCommand() {
        let fd = connectToAgentSocket()
        defer { close(fd) }

        guard case .sessionList(let sessions) = localRequest(.listSessions, fd: fd) else {
            print("Failed to get sessions")
            exit(1)
        }

        if sessions.isEmpty {
            print("No active sessions.")
            return
        }

        print("Sessions:")
        print()
        for s in sessions {
            let typeStr = s.sessionType.map { " [\($0.rawValue)]" } ?? ""
            let cwdStr = s.cwd ?? ""
            let ctrlStr: String
            switch s.controller {
            case .ios: ctrlStr = "iOS"
            case .mac: ctrlStr = "Mac"
            case .none: ctrlStr = "-"
            }
            print("  \(s.sessionId)  \(s.name)\(typeStr)  \(cwdStr)  (\(ctrlStr))")
        }
    }

    // MARK: session create

    private static func sessionCreateCommand(_ args: [String]) {
        var bg = false
        var workDir: String?
        var name = "zsh"

        // Find start of args after "session" "create"
        var commandIndex = 1
        while commandIndex < args.count {
            if args[commandIndex] == "--config-dir" { commandIndex += 2 }
            else { break }
        }
        var i = commandIndex + 2  // skip "session" "create"
        while i < args.count {
            if args[i] == "--config-dir" { i += 2; continue }
            if args[i] == "--bg" { bg = true; i += 1; continue }
            if args[i] == "--name" {
                i += 1
                guard i < args.count else {
                    print("Error: --name requires a value")
                    exit(1)
                }
                name = args[i]
                i += 1; continue
            }
            // Positional or --workdir: treat as work directory
            if args[i] == "--workdir" {
                i += 1
                guard i < args.count else {
                    print("Error: --workdir requires a value")
                    exit(1)
                }
            }
            if workDir == nil {
                let path = args[i]
                let expanded = NSString(string: path).expandingTildeInPath
                workDir = expanded.hasPrefix("/") ? expanded : FileManager.default.currentDirectoryPath + "/" + expanded
            }
            i += 1
        }

        guard let workDir else {
            print("Error: work directory is required.")
            print("Usage: termonmac session create [--bg] <work-dir> [--name <name>]")
            exit(1)
        }

        if bg {
            // Background mode: create session, print ID, exit
            let (fd, sessionId) = createSessionOnAgent(workDir: workDir, name: name, cols: 80, rows: 24)
            close(fd)
            print(sessionId)
        } else {
            // Interactive mode: create session and attach
            guard isatty(STDIN_FILENO) != 0 else {
                print("Interactive mode requires a terminal. Use --bg for background mode.")
                exit(1)
            }
            // Check nested (env var fast path, then ttyname fallback)
            do {
                let checkFd = connectToAgentSocket()
                if case .sessionList(let sessions) = localRequest(.listSessions, fd: checkFd),
                   isInsideManagedSession(sessions) {
                    close(checkFd)
                    print("This terminal is inside a TermOnMac session.")
                    print("Use --bg to create a background session, or:")
                    print("  unset TERMONMAC_SESSION && termonmac session create \(workDir)")
                    exit(1)
                }
                close(checkFd)
            }
            var ws = winsize()
            let cols = ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0 ? Int(ws.ws_col) : 80
            let rawRows = ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0 ? Int(ws.ws_row) : 24
            let rows = isAttachStatusBarEnabled() && rawRows > 2 ? rawRows - 1 : rawRows
            let (fd, sessionId) = createSessionOnAgent(workDir: workDir, name: name, cols: cols, rows: rows)

            guard case .attachResult(let success, let error, let helperSocketPath) = localRequest(
                .attach(sessionId: sessionId), fd: fd
            ) else {
                print("Failed to attach")
                close(fd)
                exit(1)
            }
            guard success else {
                print("Attach failed: \(error ?? "unknown error")")
                close(fd)
                exit(1)
            }
            if let helperSocketPath {
                attachFdPass(sessionId: sessionId, sessionName: name, agentFD: fd, helperSocketPath: helperSocketPath)
            } else {
                attachProxy(sessionId: sessionId, sessionName: name, fd: fd)
            }
        }
    }

    // MARK: session send

    private static func sessionSendCommand(_ args: [String]) {
        // Find args after "session" "send"
        var commandIndex = 1
        while commandIndex < args.count {
            if args[commandIndex] == "--config-dir" { commandIndex += 2 }
            else { break }
        }
        var positionalArgs: [String] = []
        var i = commandIndex + 2  // skip "session" "send"
        while i < args.count {
            if args[i] == "--config-dir" { i += 2; continue }
            positionalArgs.append(args[i])
            i += 1
        }

        guard positionalArgs.count >= 2 else {
            print("Usage: termonmac session send <session-id> <text>")
            exit(1)
        }

        let sessionId = positionalArgs[0]
        let text = positionalArgs.dropFirst().joined(separator: " ")

        let fd = connectToAgentSocket()
        localSend(.input(sessionId: sessionId, data: Data((text + "\n").utf8)), fd: fd)
        close(fd)
    }

    // MARK: - detach

    private static func detachCommand(_ args: [String]) {
        // Parse arguments (skip binary name + "detach")
        var sessionIdArg: String?
        var i = 2
        while i < args.count {
            if args[i] == "--config-dir" { i += 2; continue }
            sessionIdArg = args[i]
            i += 1
        }

        let fd = connectToAgentSocket()
        defer { close(fd) }

        guard case .sessionList(let sessions) = localRequest(.listSessions, fd: fd) else {
            print("Failed to get sessions")
            exit(1)
        }

        // Find mac-attached sessions
        let macSessions = sessions.filter { $0.controller == .mac }
        guard !macSessions.isEmpty else {
            print("No Mac-attached sessions to detach.")
            return
        }

        let targetSessionId: String
        if let requested = sessionIdArg {
            guard macSessions.contains(where: { $0.sessionId == requested }) else {
                print("Session '\(requested)' is not attached from Mac. Mac-attached sessions:")
                for s in macSessions { print("  \(s.sessionId)  \(s.name)") }
                exit(1)
            }
            targetSessionId = requested
        } else if macSessions.count == 1 {
            targetSessionId = macSessions[0].sessionId
        } else {
            print("Multiple Mac-attached sessions. Specify one:")
            for s in macSessions { print("  \(s.sessionId)  \(s.name)") }
            print()
            print("Usage: termonmac detach <session-id>")
            exit(0)
        }

        let targetName = macSessions.first(where: { $0.sessionId == targetSessionId })?.name ?? targetSessionId
        _ = localRequest(.forceDetach(sessionId: targetSessionId), fd: fd)
        print("Detached session '\(targetName)'.")
    }

    // MARK: - kill

    private static func killCommand(_ args: [String]) {
        // Parse arguments (skip binary name + "kill")
        var sessionIdArg: String?
        var i = 2
        while i < args.count {
            if args[i] == "--config-dir" { i += 2; continue }
            sessionIdArg = args[i]
            i += 1
        }

        let fd = connectToAgentSocket()
        defer { close(fd) }

        guard case .sessionList(let sessions) = localRequest(.listSessions, fd: fd) else {
            print("Failed to get sessions")
            exit(1)
        }

        guard !sessions.isEmpty else {
            print("No active sessions.")
            return
        }

        let targetSessionId: String
        if let requested = sessionIdArg {
            guard sessions.contains(where: { $0.sessionId == requested }) else {
                print("Session '\(requested)' not found. Available sessions:")
                for s in sessions { print("  \(s.sessionId)  \(s.name)") }
                exit(1)
            }
            targetSessionId = requested
        } else if sessions.count == 1 {
            targetSessionId = sessions[0].sessionId
        } else {
            print("Multiple sessions. Specify one:")
            for s in sessions { print("  \(s.sessionId)  \(s.name)") }
            print()
            print("Usage: termonmac kill <session-id>")
            exit(0)
        }

        let targetName = sessions.first(where: { $0.sessionId == targetSessionId })?.name ?? targetSessionId
        let shortId = String(targetSessionId.prefix(8))
        print("About to kill session: \(targetName) (\(shortId))")
        print("Type '\(targetName)' to confirm: ", terminator: "")
        guard let input = readLine()?.trimmingCharacters(in: .whitespaces), input == targetName else {
            print("Cancelled.")
            return
        }

        _ = localRequest(.killSession(sessionId: targetSessionId), fd: fd)
        print("Killed session '\(targetName)'.")
    }

    // MARK: - attach

    private static func attachCommand(_ args: [String]) {
        guard isatty(STDIN_FILENO) != 0 else {
            print("attach requires an interactive terminal")
            exit(1)
        }

        // Parse arguments (skip binary name + "attach")
        var sessionIdArg: String?
        do {
            var i = 2
            while i < args.count {
                if args[i] == "--config-dir" { i += 2; continue }
                sessionIdArg = args[i]
                i += 1
            }
        }

        let fd = connectToAgentSocket()

        // List sessions to resolve target
        guard case .sessionList(let sessions) = localRequest(.listSessions, fd: fd) else {
            print("Failed to get sessions")
            close(fd)
            exit(1)
        }

        guard !sessions.isEmpty else {
            print("No active sessions.")
            close(fd)
            exit(0)
        }

        // Detect nested attach (env var or ttyname match)
        if isInsideManagedSession(sessions) {
            print("This terminal is inside a TermOnMac session.")
            print("Use the iOS app session list to switch sessions, or:")
            print("  unset TERMONMAC_SESSION && termonmac attach [session-id]")
            close(fd)
            exit(1)
        }

        let targetSessionId: String
        if let requested = sessionIdArg {
            guard sessions.contains(where: { $0.sessionId == requested }) else {
                print("Session '\(requested)' not found. Available sessions:")
                for s in sessions { print("  \(s.sessionId)  \(s.name)") }
                close(fd)
                exit(1)
            }
            targetSessionId = requested
        } else if sessions.count == 1 {
            targetSessionId = sessions[0].sessionId
        } else {
            print("Multiple sessions available. Specify one:")
            for s in sessions { print("  \(s.sessionId)  \(s.name)") }
            print()
            print("Usage: termonmac attach <session-id>")
            close(fd)
            exit(0)
        }

        // Check if session is already attached from another Mac terminal
        if let targetSession = sessions.first(where: { $0.sessionId == targetSessionId }),
           targetSession.controller == .mac {
            print("Session '\(targetSession.name)' is already attached from another terminal.")
            print("Take over? [y/N] ", terminator: "")
            guard let answer = readLine()?.lowercased(), answer == "y" || answer == "yes" else {
                print("Cancelled.")
                close(fd)
                exit(0)
            }
        }

        // Attach to session
        guard case .attachResult(let success, let error, let helperSocketPath) = localRequest(.attach(sessionId: targetSessionId), fd: fd) else {
            print("Failed to attach")
            close(fd)
            exit(1)
        }
        guard success else {
            print("Attach failed: \(error ?? "unknown error")")
            close(fd)
            exit(1)
        }

        let sessionName = sessions.first(where: { $0.sessionId == targetSessionId })?.name
            ?? String(targetSessionId.prefix(8))

        if let helperSocketPath {
            attachFdPass(sessionId: targetSessionId, sessionName: sessionName, agentFD: fd, helperSocketPath: helperSocketPath)
        } else {
            attachProxy(sessionId: targetSessionId, sessionName: sessionName, fd: fd)
        }
    }

    // MARK: - continue (smart attach/create by cwd)

    private static func continueCommand(_ args: [String]) {
        guard isatty(STDIN_FILENO) != 0 else {
            print("continue requires an interactive terminal")
            exit(1)
        }

        let currentDir = FileManager.default.currentDirectoryPath

        let fd = connectToAgentSocket()

        // List sessions to find matches
        guard case .sessionList(let sessions) = localRequest(.listSessions, fd: fd) else {
            print("Failed to get sessions")
            close(fd)
            exit(1)
        }

        // Detect nested attach
        if isInsideManagedSession(sessions) {
            print("This terminal is inside a TermOnMac session.")
            print("  unset TERMONMAC_SESSION && termonmac -c")
            close(fd)
            exit(1)
        }

        // Find sessions whose cwd matches the current directory
        let matching = sessions.filter { $0.cwd == currentDir }

        if matching.isEmpty {
            // No matching session → create a new one
            close(fd)
            let defaultName = URL(fileURLWithPath: currentDir).lastPathComponent
            var ws = winsize()
            let cols = ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0 ? Int(ws.ws_col) : 80
            let rawRows = ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0 ? Int(ws.ws_row) : 24
            let rows = isAttachStatusBarEnabled() && rawRows > 2 ? rawRows - 1 : rawRows
            let (newFd, sessionId) = createSessionOnAgent(workDir: currentDir, name: defaultName, cols: cols, rows: rows)
            takeOverAndAttach(sessionId: sessionId, sessionName: defaultName, controller: .none, fd: newFd)
        } else if matching.count == 1 {
            // Exactly one match → attach directly
            let target = matching[0]
            takeOverAndAttach(sessionId: target.sessionId, sessionName: target.name, controller: target.controller, fd: fd)
        } else {
            // Multiple matches → let user choose
            print("Multiple sessions in \(shortPath(currentDir)):")
            print()
            for (i, s) in matching.enumerated() {
                let ctrlStr: String
                switch s.controller {
                case .ios: ctrlStr = "iOS"
                case .mac: ctrlStr = "Mac"
                case .none: ctrlStr = "-"
                }
                let typeStr = s.sessionType.map { " [\($0.rawValue)]" } ?? ""
                print("  [\(i + 1)] \(s.sessionId)  \(s.name)\(typeStr)  (\(ctrlStr))")
            }
            print()
            print("Select session [1-\(matching.count)]: ", terminator: "")

            guard let input = readLine()?.trimmingCharacters(in: .whitespaces),
                  let choice = Int(input), choice >= 1, choice <= matching.count else {
                print("Cancelled.")
                close(fd)
                exit(0)
            }

            let target = matching[choice - 1]
            takeOverAndAttach(sessionId: target.sessionId, sessionName: target.name, controller: target.controller, fd: fd)
        }
    }

    /// Confirm take-over (if Mac-attached), then attach and enter fd-pass/proxy loop.
    /// This function never returns — it either enters the attach loop or calls exit().
    private static func takeOverAndAttach(
        sessionId: String, sessionName: String,
        controller: SessionController, fd: Int32
    ) {
        if controller == .mac {
            print("Session '\(sessionName)' is already attached from another terminal.")
            print("Take over? [y/N] ", terminator: "")
            guard let answer = readLine()?.lowercased(), answer == "y" || answer == "yes" else {
                print("Cancelled.")
                close(fd)
                exit(0)
            }
        }

        guard case .attachResult(let success, let error, let helperSocketPath) = localRequest(
            .attach(sessionId: sessionId), fd: fd
        ) else {
            print("Failed to attach")
            close(fd)
            exit(1)
        }
        guard success else {
            print("Attach failed: \(error ?? "unknown error")")
            close(fd)
            exit(1)
        }
        if let helperSocketPath {
            attachFdPass(sessionId: sessionId, sessionName: sessionName, agentFD: fd, helperSocketPath: helperSocketPath)
        } else {
            attachProxy(sessionId: sessionId, sessionName: sessionName, fd: fd)
        }
    }

    /// Fetch the CWD of a session by querying the agent.
    private static func fetchSessionCwd(sessionId: String) -> String? {
        let fd = connectToAgentSocketOrNil()
        guard let fd else { return nil }
        defer { close(fd) }
        guard case .sessionList(let sessions) = localRequest(.listSessions, fd: fd) else {
            return nil
        }
        return sessions.first(where: { $0.sessionId == sessionId })?.cwd
    }

    private static func shortPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    private static func rawPrint(_ s: String, terminator: String = "\r\n") {
        rawWrite(s + terminator)
    }

    private static func rawWrite(_ s: String) {
        let bytes = Array(s.utf8)
        bytes.withUnsafeBufferPointer { buf in
            var written = 0
            while written < buf.count {
                let w = Darwin.write(STDOUT_FILENO, buf.baseAddress!.advanced(by: written), buf.count - written)
                if w > 0 { written += w }
                else if w < 0 && (errno == EAGAIN || errno == EINTR) { continue }
                else { break }
            }
        }
    }

    /// Strip terminal query sequences from replay data before writing to stdout.
    /// Programs like tmux/vim embed DA queries (\e[c, \e[>c), DSR queries
    /// (\e[6n), and XTVERSION queries (\e[>q) in their output.  When replayed,
    /// the Mac terminal responds and those responses flow through STDIN → PTY →
    /// shell as spurious input.
    ///
    /// Stripped CSI final bytes:
    ///   'c' (0x63) — Device Attributes (DA1/DA2/DA3)
    ///   'n' (0x6E) — Device Status Report (DSR)
    ///   'q' (0x71) — XTVERSION query (only when NO intermediate bytes;
    ///                 CSI Ps SP q = DECSCUSR cursor style is preserved)
    private static func stripTerminalQueries(_ data: Data) -> Data {
        let bytes = [UInt8](data)
        let count = bytes.count
        var result = Data(capacity: count)
        var i = 0

        while i < count {
            if bytes[i] == 0x1B && i + 1 < count && bytes[i + 1] == 0x5B {
                // CSI sequence: ESC [ (params) (intermediates) (final byte)
                let csiStart = i
                i += 2
                while i < count && bytes[i] >= 0x30 && bytes[i] <= 0x3F { i += 1 } // params
                let intermediateStart = i
                while i < count && bytes[i] >= 0x20 && bytes[i] <= 0x2F { i += 1 } // intermediates
                let hasIntermediate = i > intermediateStart
                if i < count && bytes[i] >= 0x40 && bytes[i] <= 0x7E {
                    let fin = bytes[i]
                    i += 1
                    if fin == 0x63 /* c */ || fin == 0x6E /* n */ {
                        continue  // strip DA / DSR query
                    }
                    if fin == 0x71 /* q */ && !hasIntermediate {
                        continue  // strip XTVERSION query (but keep DECSCUSR: CSI Ps SP q)
                    }
                }
                result.append(contentsOf: bytes[csiStart..<i])
            } else {
                result.append(bytes[i])
                i += 1
            }
        }
        return result
    }

    /// Immediately correct Mac terminal scroll region after a DECSTBM reset
    /// detected by CursorTracker. Writes: (1) correct scroll region to protect
    /// the status bar row, (2) CUP to restore cursor position (DECSTBM homes cursor).
    private static func correctScrollRegion(tracker: CursorTracker, contentRows: Int) {
        let fix = "\u{1b}[1;\(contentRows)r\u{1b}[\(tracker.row + 1);\(tracker.col + 1)H"
        let bytes = Array(fix.utf8)
        bytes.withUnsafeBufferPointer { buf in
            var written = 0
            while written < buf.count {
                let w = Darwin.write(STDOUT_FILENO, buf.baseAddress!.advanced(by: written), buf.count - written)
                if w > 0 { written += w }
                else if w < 0 && (errno == EAGAIN || errno == EINTR) { continue }
                else { break }
            }
        }
    }

    // MARK: - Zero-latency attach via PTY fd passing (Mac → PTY kernel, 0 hops)

    private static func attachFdPass(sessionId: String, sessionName: String, agentFD: Int32, helperSocketPath: String) {
        let state = AttachState(showStatusBar: isAttachStatusBarEnabled(), sessionName: sessionName)
        let helperClient = HelperClient()
        do {
            try helperClient.connectNoReconnect(socketPath: helperSocketPath)
        } catch {
            print("Failed to direct-connect to pty-helper: \(error)")
            localSend(.detach, fd: agentFD)
            close(agentFD)
            exit(1)
        }

        // Enable live output and get replay
        helperClient.switchToLive()
        let replay = helperClient.replayIncremental(sessionId: sessionId, sinceOffset: nil)

        // Request PTY master fd via SCM_RIGHTS (received inside readLoop to avoid races)
        let masterFD = helperClient.requestPtyFd(sessionId: sessionId)
        guard masterFD >= 0 else {
            // Fallback to existing direct-connect IPC mode
            let reason = helperClient.lastFdPassError ?? "unknown"
            FileHandle.standardError.write("[attach] fd-pass failed: \(reason)\n".data(using: .utf8)!)
            helperClient.disconnect()
            attachDirect(sessionId: sessionId, sessionName: state.sessionName, agentFD: agentFD, helperSocketPath: helperSocketPath)
            return
        }

        FileHandle.standardError.write("[attach] fd-pass mode (masterFD=\(masterFD))\n".data(using: .utf8)!)

        // Enter raw terminal mode
        var originalTermios = termios()
        tcgetattr(STDIN_FILENO, &originalTermios)
        var rawTermios = originalTermios
        cfmakeraw(&rawTermios)
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &rawTermios)

        // Clear screen so replay renders from (1,1) without overlapping
        // previous CLI output (e.g. the "termonmac session create" command line).
        // Without this, the status bar setup moves cursor to (1,1) via DECSTBM,
        // but the replay content was written further down — causing prompt overlap.
        Darwin.write(STDOUT_FILENO, "\u{1b}[H\u{1b}[2J", 7)

        // Write replay to stdout (filter terminal queries to prevent Mac terminal
        // from responding — zsh 5.9 ZLE can't handle late DA1/DA2/XTVERSION responses)
        if !replay.data.isEmpty {
            let filtered = TerminalQueryInterceptor.intercept(replay.data)
            FileHandle.standardOutput.write(filtered.filteredOutput)
            // Write intercepted query responses directly to PTY (zero-latency local reply)
            if !filtered.responses.isEmpty {
                for resp in filtered.responses {
                    resp.withUnsafeBytes { buf in
                        guard let ptr = buf.baseAddress else { return }
                        _ = Darwin.write(masterFD, ptr, buf.count)
                    }
                }
            }
        }

        // Set up terminal title (always) and status bar (if enabled)
        AttachStatusBar.setTitle(state.sessionName)
        let tracker = CursorTracker(cols: 80, rows: 24) // dims updated by sendCurrentSize
        var currentContentRows: Int = 0 // updated by sendCurrentSize, used for scroll region correction
        let prefixByte = attachPrefixByte()
        let prefixLabel = attachPrefixLabel()
        if state.showStatusBar { AttachStatusBar.setup(sessionName: state.sessionName, prefixLabel: prefixLabel) }

        // Window resize: set directly on PTY fd + notify pty_helper
        func sendCurrentSize() {
            var ws = winsize()
            if ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0 {
                let effectiveRows: Int
                if state.showStatusBar, let barRows = AttachStatusBar.redraw(sessionName: state.sessionName, prefixLabel: prefixLabel) {
                    effectiveRows = barRows
                } else {
                    effectiveRows = Int(ws.ws_row)
                }
                if state.showStatusBar {
                    tracker.resize(cols: Int(ws.ws_col), rows: effectiveRows)
                    currentContentRows = effectiveRows
                }
                var wsCopy = winsize(ws_row: UInt16(effectiveRows), ws_col: ws.ws_col,
                                     ws_xpixel: ws.ws_xpixel, ws_ypixel: ws.ws_ypixel)
                _ = ioctl(masterFD, TIOCSWINSZ, &wsCopy)
                helperClient.resize(sessionId: sessionId, cols: Int(ws.ws_col), rows: effectiveRows)
            }
        }
        sendCurrentSize()

        // Feed replay data through tracker so cursor position is in sync.
        // The replay was written to stdout before the tracker was created,
        // so without this step the tracker starts at (0,0) while the Mac
        // terminal's content cursor is wherever the replay left it.
        if state.showStatusBar && !replay.data.isEmpty {
            tracker.process(replay.data)
            _ = tracker.consumeScrollRegionReset() // ignore replay-era resets
            // Status bar setup/redraw left the Mac terminal cursor at (1,1) via
            // DECSTBM home + drawBar default return position.  Restore cursor to
            // the replay-era position so the first PTY output (e.g. user presses
            // Enter) renders at the correct row instead of near the top.
            let cur = "\u{1b}[\(tracker.row + 1);\(tracker.col + 1)H"
            let curBytes = Array(cur.utf8)
            curBytes.withUnsafeBufferPointer { buf in
                var written = 0
                while written < buf.count {
                    let w = Darwin.write(STDOUT_FILENO, buf.baseAddress!.advanced(by: written), buf.count - written)
                    if w > 0 { written += w }
                    else if w < 0 && (errno == EAGAIN || errno == EINTR) { continue }
                    else { break }
                }
            }
        }

        let cleanupOnce = DispatchSemaphore(value: 1)
        func cleanup() {
            guard cleanupOnce.wait(timeout: .now()) == .success else { return }
            if state.showStatusBar { AttachStatusBar.teardown() }
            tcsetattr(STDIN_FILENO, TCSAFLUSH, &originalTermios)
            // Restore cursor visibility (shell may have hidden it via DECTCEM)
            Darwin.write(STDOUT_FILENO, "\u{1b}[?25h", 6)
            // Release fd back to pty_helper before disconnecting
            helperClient.releasePtyFd(sessionId: sessionId)
            close(masterFD)
            helperClient.disconnect()
            localSend(.detach, fd: agentFD)
            close(agentFD)
        }

        // Async tee queue: fire-and-forget output data back to pty_helper for scrollback
        let teeQueue = DispatchQueue(label: "fd-pass.tee", qos: .utility)

        // SIGWINCH → resize
        signal(SIGWINCH, SIG_IGN)
        let sigwinchSource = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .main)
        sigwinchSource.setEventHandler {
            sendCurrentSize()
        }
        sigwinchSource.resume()

        // SIGINT, SIGTERM → detach
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigintSource.setEventHandler {
            cleanup()
            print("\r\nDetached.")
            exit(0)
        }
        sigintSource.resume()
        let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        sigtermSource.setEventHandler {
            cleanup()
            exit(0)
        }
        sigtermSource.resume()

        // Control loop: read agent.sock for takenOver/sessionExited
        DispatchQueue.global(qos: .userInteractive).async {
            while true {
                guard let response = try? IPCFraming.readFrame(LocalIPC.Response.self, from: agentFD) else {
                    break
                }
                switch response.message {
                case .takenOver(_):
                    DispatchQueue.main.async {
                        cleanup()
                        print("\r\nSession taken over by iOS.")
                        exit(0)
                    }
                case .sessionExited(_):
                    DispatchQueue.main.async {
                        cleanup()
                        print("\r\nSession exited.")
                        exit(0)
                    }
                case .sessionRenamed(_, let newName):
                    state.sessionName = newName
                    AttachStatusBar.setTitle(newName)
                default:
                    break
                }
            }
            DispatchQueue.main.async {
                cleanup()
                print("\r\nDisconnected.")
                exit(1)
            }
        }

        // PTY output: read(masterFD) → write(STDOUT) + cursor tracking + coalesced bar redraw
        // masterFD is O_NONBLOCK (set by pty_helper). DO NOT change it — the flag is
        // shared with pty_helper's fd via the same kernel file description. Instead,
        // use poll() to block until data is available, avoiding a spin loop.
        DispatchQueue.global(qos: .userInteractive).async {
            var outputBuf = [UInt8](repeating: 0, count: 16384)
            var teeOffset: UInt64 = replay.currentOffset
            var needsBarRedraw = false
            var needsPtyBounce = false
            var lastBounceTime: Date = .distantPast

            while true {
                // poll timeout: 16ms when bar needs redraw or PTY bounce pending, else infinite
                let pollTimeout: Int32 = state.showStatusBar && (needsBarRedraw || needsPtyBounce) ? 16 : -1
                var pfd = pollfd(fd: masterFD, events: Int16(POLLIN), revents: 0)
                let pollResult = poll(&pfd, 1, pollTimeout)

                if pollResult == 0 {
                    // No output for 16ms — shell is idle, safe to redraw bar
                    if state.showStatusBar && needsBarRedraw {
                        AttachStatusBar.refreshBar(sessionName: state.sessionName,
                                                   cursorRow: tracker.row, cursorCol: tracker.col,
                                                   prefixLabel: prefixLabel)
                        needsBarRedraw = false
                    }
                    // After a scroll region reset, bounce PTY size to force a full
                    // redraw. This fixes the 1-row content desync caused by the gap
                    // between writing PTY output to stdout (Mac terminal processes
                    // ESC[r] immediately) and correctScrollRegion firing afterwards.
                    // Debounced to at most once per second to avoid loops.
                    if needsPtyBounce && Date().timeIntervalSince(lastBounceTime) > 1.0 {
                        needsPtyBounce = false
                        lastBounceTime = Date()
                        var ws = winsize()
                        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0 {
                            var small = winsize(ws_row: UInt16(max(1, Int(ws.ws_row) - 2)),
                                                ws_col: ws.ws_col,
                                                ws_xpixel: ws.ws_xpixel, ws_ypixel: ws.ws_ypixel)
                            _ = ioctl(masterFD, TIOCSWINSZ, &small)
                        }
                        sendCurrentSize()
                    }
                    continue
                }
                if pollResult < 0 && errno != EINTR { break }
                if pfd.revents & Int16(POLLHUP | POLLERR) != 0, pfd.revents & Int16(POLLIN) == 0 { break }

                let n = read(masterFD, &outputBuf, outputBuf.count)
                if n > 0 {
                    // Intercept terminal queries (DA1, DA2, DSR, DECRPM, OSC color)
                    // to prevent them from reaching the Mac terminal. Without this,
                    // the Mac terminal responds and zsh 5.9 ZLE (which lacks a CSI
                    // eater) leaks response bytes into the command line as garbage.
                    let rawData = Data(outputBuf[0..<n])
                    let intercepted = TerminalQueryInterceptor.intercept(rawData)

                    // Write query responses directly to PTY (zero-latency local reply)
                    for resp in intercepted.responses {
                        resp.withUnsafeBytes { buf in
                            guard let ptr = buf.baseAddress else { return }
                            _ = Darwin.write(masterFD, ptr, buf.count)
                        }
                    }

                    let outputData = intercepted.filteredOutput
                    if !outputData.isEmpty {
                        outputData.withUnsafeBytes { buf in
                            var written = 0
                            while written < buf.count {
                                let w = Darwin.write(STDOUT_FILENO, buf.baseAddress!.advanced(by: written), buf.count - written)
                                if w > 0 { written += w }
                                else if w < 0 && (errno == EAGAIN || errno == EINTR) { continue }
                                else { break }
                            }
                        }
                        if state.showStatusBar {
                            outputData.withUnsafeBytes { buf in
                                tracker.process(buf.baseAddress!.assumingMemoryBound(to: UInt8.self), count: buf.count)
                                if tracker.consumeScrollRegionReset() && currentContentRows > 0 {
                                    correctScrollRegion(tracker: tracker, contentRows: currentContentRows)
                                    needsPtyBounce = true
                                }
                            }
                        }
                    }
                    if state.showStatusBar { needsBarRedraw = true }
                    // Async tee: send FILTERED data so replay buffer stays clean
                    if !outputData.isEmpty {
                        let offset = teeOffset
                        teeOffset += UInt64(outputData.count)
                        teeQueue.async {
                            helperClient.sendTeeOutput(sessionId: sessionId, data: outputData, offset: offset)
                        }
                    }
                } else if n == 0 || (n < 0 && errno != EAGAIN && errno != EINTR) {
                    // PTY closed (shell exited)
                    DispatchQueue.main.async {
                        cleanup()
                        print("\r\nSession exited.")
                        exit(0)
                    }
                    return
                }
            }
        }

        // Stdin: poll(STDIN) → read(STDIN) → write(masterFD) with prefix key handling
        DispatchQueue.global(qos: .userInteractive).async {
            var buf = [UInt8](repeating: 0, count: 4096)
            var prefixHandler = AttachPrefixHandler(prefixByte: prefixByte, writeToPTY: { ptr, count in
                var written = 0
                while written < count {
                    let w = Darwin.write(masterFD, ptr.advanced(by: written), count - written)
                    if w > 0 { written += w }
                    else if w < 0 && (errno == EAGAIN || errno == EINTR) { continue }
                    else { break }
                }
            })

            while true {
                var fds: [pollfd] = [
                    pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
                ]
                let pr = poll(&fds, 1, -1)
                if pr < 0 && errno != EINTR { break }
                guard fds[0].revents & Int16(POLLIN) != 0 else { continue }
                let n = read(STDIN_FILENO, &buf, buf.count)
                if n <= 0 { break }

                let action = prefixHandler.feed(&buf, count: n)
                switch action {
                case .none:
                    break
                case .detach:
                    DispatchQueue.main.async {
                        cleanup()
                        print("\r\nDetached.")
                        exit(0)
                    }
                    return
                case .kill:
                    localSend(.killSession(sessionId: sessionId), fd: agentFD)
                    DispatchQueue.main.async {
                        cleanup()
                        print("\r\nKilled.")
                        exit(0)
                    }
                    return
                }
            }

            DispatchQueue.main.async {
                cleanup()
                print("\r\nDetached (EOF).")
                exit(0)
            }
        }

        dispatchMain()
    }

    // MARK: - Direct-connect attach (Mac → pty_helper.sock, 2 hops, fallback)

    private static func attachDirect(sessionId: String, sessionName: String, agentFD: Int32, helperSocketPath: String) {
        let state = AttachState(showStatusBar: isAttachStatusBarEnabled(), sessionName: sessionName)
        let helperClient = HelperClient()
        do {
            try helperClient.connectNoReconnect(socketPath: helperSocketPath)
        } catch {
            print("Failed to direct-connect to pty-helper: \(error)")
            localSend(.detach, fd: agentFD)
            close(agentFD)
            exit(1)
        }

        // Enable live output and get replay
        helperClient.switchToLive()
        let replay = helperClient.replayIncremental(sessionId: sessionId, sinceOffset: nil)

        // Enter raw terminal mode
        var originalTermios = termios()
        tcgetattr(STDIN_FILENO, &originalTermios)
        var rawTermios = originalTermios
        cfmakeraw(&rawTermios)
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &rawTermios)

        // Clear screen so replay renders from (1,1) — see attachFdPass for rationale
        Darwin.write(STDOUT_FILENO, "\u{1b}[H\u{1b}[2J", 7)

        // Write replay to stdout (filter terminal queries — see attachFdPass for rationale)
        if !replay.data.isEmpty {
            let filtered = TerminalQueryInterceptor.intercept(replay.data)
            FileHandle.standardOutput.write(filtered.filteredOutput)
            // In attachDirect the HelperServer owns the masterFD, so write responses via IPC
            for resp in filtered.responses {
                helperClient.write(resp, to: sessionId)
            }
        }

        // Set up terminal title (always) and status bar (if enabled)
        AttachStatusBar.setTitle(state.sessionName)
        let tracker = CursorTracker(cols: 80, rows: 24)
        var currentContentRows: Int = 0
        let prefixByte = attachPrefixByte()
        let prefixLabel = attachPrefixLabel()
        if state.showStatusBar { AttachStatusBar.setup(sessionName: state.sessionName, prefixLabel: prefixLabel) }

        // Send current window size directly to pty-helper
        func sendCurrentSize() {
            var ws = winsize()
            if ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0 {
                let effectiveRows: Int
                if state.showStatusBar, let barRows = AttachStatusBar.redraw(sessionName: state.sessionName, prefixLabel: prefixLabel) {
                    effectiveRows = barRows
                } else {
                    effectiveRows = Int(ws.ws_row)
                }
                if state.showStatusBar {
                    tracker.resize(cols: Int(ws.ws_col), rows: effectiveRows)
                    currentContentRows = effectiveRows
                }
                helperClient.resize(sessionId: sessionId, cols: Int(ws.ws_col), rows: effectiveRows)
            }
        }
        sendCurrentSize()

        // Feed replay through tracker (see attachFdPass for rationale)
        if state.showStatusBar && !replay.data.isEmpty {
            tracker.process(replay.data)
            _ = tracker.consumeScrollRegionReset()
            // Restore cursor to replay-era position (see attachFdPass for rationale)
            let cur = "\u{1b}[\(tracker.row + 1);\(tracker.col + 1)H"
            let curBytes = Array(cur.utf8)
            curBytes.withUnsafeBufferPointer { buf in
                var written = 0
                while written < buf.count {
                    let w = Darwin.write(STDOUT_FILENO, buf.baseAddress!.advanced(by: written), buf.count - written)
                    if w > 0 { written += w }
                    else if w < 0 && (errno == EAGAIN || errno == EINTR) { continue }
                    else { break }
                }
            }
        }

        var cleanedUp = false
        var pendingBarRedraw: DispatchWorkItem?
        func cleanup() {
            guard !cleanedUp else { return }
            cleanedUp = true
            pendingBarRedraw?.cancel()
            if state.showStatusBar { AttachStatusBar.teardown() }
            tcsetattr(STDIN_FILENO, TCSAFLUSH, &originalTermios)
            Darwin.write(STDOUT_FILENO, "\u{1b}[?25h", 6)  // restore cursor visibility
            // Disconnect from pty_helper.sock FIRST so AgentService can reconnect
            helperClient.disconnect()
            // Then notify AgentService
            localSend(.detach, fd: agentFD)
            close(agentFD)
        }

        // Direct output: HelperClient.onOutput → stdout + cursor tracking + coalesced bar
        helperClient.onOutput = { sid, data in
            guard sid == sessionId else { return }
            FileHandle.standardOutput.write(data)
            if state.showStatusBar {
                tracker.process(data)
                if tracker.consumeScrollRegionReset() && currentContentRows > 0 {
                    correctScrollRegion(tracker: tracker, contentRows: currentContentRows)
                }
                pendingBarRedraw?.cancel()
                let work = DispatchWorkItem {
                    AttachStatusBar.refreshBar(sessionName: state.sessionName,
                                               cursorRow: tracker.row, cursorCol: tracker.col,
                                               prefixLabel: prefixLabel)
                }
                pendingBarRedraw = work
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(16), execute: work)
            }
        }

        helperClient.onSessionExited = { sid in
            guard sid == sessionId else { return }
            DispatchQueue.main.async {
                cleanup()
                print("\r\nSession exited.")
                exit(0)
            }
        }

        // SIGWINCH → resize
        signal(SIGWINCH, SIG_IGN)
        let sigwinchSource = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .main)
        sigwinchSource.setEventHandler {
            sendCurrentSize()
        }
        sigwinchSource.resume()

        // SIGINT, SIGTERM → detach
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigintSource.setEventHandler {
            cleanup()
            print("\r\nDetached.")
            exit(0)
        }
        sigintSource.resume()
        let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        sigtermSource.setEventHandler {
            cleanup()
            exit(0)
        }
        sigtermSource.resume()

        // Control loop: read agent.sock for takenOver/sessionExited from AgentService
        DispatchQueue.global(qos: .userInteractive).async {
            while true {
                guard let response = try? IPCFraming.readFrame(LocalIPC.Response.self, from: agentFD) else {
                    break
                }
                switch response.message {
                case .takenOver(_):
                    DispatchQueue.main.async {
                        cleanup()
                        print("\r\nSession taken over by iOS.")
                        exit(0)
                    }
                case .sessionExited(_):
                    DispatchQueue.main.async {
                        cleanup()
                        print("\r\nSession exited.")
                        exit(0)
                    }
                case .sessionRenamed(_, let newName):
                    state.sessionName = newName
                    AttachStatusBar.setTitle(newName)
                default:
                    break
                }
            }
            // AgentService disconnected
            DispatchQueue.main.async {
                cleanup()
                print("\r\nDisconnected.")
                exit(1)
            }
        }

        // Forward stdin directly to pty-helper with prefix key handling
        DispatchQueue.global(qos: .userInteractive).async {
            var buf = [UInt8](repeating: 0, count: 4096)
            var prefixHandler = AttachPrefixHandler(prefixByte: prefixByte, writeToPTY: { ptr, count in
                helperClient.write(Data(UnsafeBufferPointer(start: ptr, count: count)), to: sessionId)
            })

            while true {
                var fds: [pollfd] = [
                    pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
                ]
                let pr = poll(&fds, 1, -1)
                if pr < 0 && errno != EINTR { break }
                guard fds[0].revents & Int16(POLLIN) != 0 else { continue }
                let n = read(STDIN_FILENO, &buf, buf.count)
                if n <= 0 { break }

                let action = prefixHandler.feed(&buf, count: n)
                switch action {
                case .none:
                    break
                case .detach:
                    DispatchQueue.main.async { cleanup(); print("\r\nDetached."); exit(0) }
                    return
                case .kill:
                    localSend(.killSession(sessionId: sessionId), fd: agentFD)
                    DispatchQueue.main.async { cleanup(); print("\r\nKilled."); exit(0) }
                    return
                }
            }

            DispatchQueue.main.async {
                cleanup()
                print("\r\nDetached (EOF).")
                exit(0)
            }
        }

        dispatchMain()
    }

    // MARK: - Proxy-mode attach (Mac → agent.sock → AgentService → pty-helper, 4 hops)

    private static func attachProxy(sessionId: String, sessionName: String, fd: Int32) {
        let state = AttachState(showStatusBar: isAttachStatusBarEnabled(), sessionName: sessionName)
        // Enter raw terminal mode
        var originalTermios = termios()
        tcgetattr(STDIN_FILENO, &originalTermios)
        var rawTermios = originalTermios
        cfmakeraw(&rawTermios)
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &rawTermios)

        // Clear screen so session output renders from (1,1) — see attachFdPass for rationale
        Darwin.write(STDOUT_FILENO, "\u{1b}[H\u{1b}[2J", 7)

        // Set up terminal title (always) and status bar (if enabled)
        AttachStatusBar.setTitle(state.sessionName)
        let tracker = CursorTracker(cols: 80, rows: 24)
        var currentContentRows: Int = 0
        let prefixByte = attachPrefixByte()
        let prefixLabel = attachPrefixLabel()
        if state.showStatusBar { AttachStatusBar.setup(sessionName: state.sessionName, prefixLabel: prefixLabel) }

        // Send current window size
        func sendCurrentSize() {
            var ws = winsize()
            if ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0 {
                let effectiveRows: Int
                if state.showStatusBar, let barRows = AttachStatusBar.redraw(sessionName: state.sessionName, prefixLabel: prefixLabel) {
                    effectiveRows = barRows
                } else {
                    effectiveRows = Int(ws.ws_row)
                }
                if state.showStatusBar {
                    tracker.resize(cols: Int(ws.ws_col), rows: effectiveRows)
                    currentContentRows = effectiveRows
                }
                localSend(.resize(sessionId: sessionId, cols: Int(ws.ws_col), rows: effectiveRows), fd: fd)
            }
        }
        sendCurrentSize()

        var cleanedUp = false
        var pendingBarRedraw: DispatchWorkItem?
        func cleanup() {
            guard !cleanedUp else { return }
            cleanedUp = true
            pendingBarRedraw?.cancel()
            if state.showStatusBar { AttachStatusBar.teardown() }
            tcsetattr(STDIN_FILENO, TCSAFLUSH, &originalTermios)
            Darwin.write(STDOUT_FILENO, "\u{1b}[?25h", 6)  // restore cursor visibility
            localSend(.detach, fd: fd)
            close(fd)
        }

        // SIGWINCH → resize
        signal(SIGWINCH, SIG_IGN)
        let sigwinchSource = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .main)
        sigwinchSource.setEventHandler {
            sendCurrentSize()
        }
        sigwinchSource.resume()

        // SIGINT, SIGTERM → detach
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigintSource.setEventHandler {
            cleanup()
            print("\r\nDetached.")
            exit(0)
        }
        sigintSource.resume()
        let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        sigtermSource.setEventHandler {
            cleanup()
            exit(0)
        }
        sigtermSource.resume()

        // Read server push events (output, sessionExited, takenOver)
        DispatchQueue.global(qos: .userInteractive).async {
            while true {
                guard let response = try? IPCFraming.readFrame(LocalIPC.Response.self, from: fd) else {
                    break // server closed connection
                }
                switch response.message {
                case .output(_, let data):
                    FileHandle.standardOutput.write(data)
                    if state.showStatusBar {
                        tracker.process(data)
                        if tracker.consumeScrollRegionReset() && currentContentRows > 0 {
                            correctScrollRegion(tracker: tracker, contentRows: currentContentRows)
                        }
                        pendingBarRedraw?.cancel()
                        let work = DispatchWorkItem {
                            AttachStatusBar.refreshBar(sessionName: state.sessionName,
                                                       cursorRow: tracker.row, cursorCol: tracker.col,
                                                       prefixLabel: prefixLabel)
                        }
                        pendingBarRedraw = work
                        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(16), execute: work)
                    }
                case .sessionExited(_):
                    DispatchQueue.main.async {
                        cleanup()
                        print("\r\nSession exited.")
                        exit(0)
                    }
                case .takenOver(_):
                    DispatchQueue.main.async {
                        cleanup()
                        print("\r\nSession taken over by iOS.")
                        exit(0)
                    }
                case .sessionRenamed(_, let newName):
                    state.sessionName = newName
                    AttachStatusBar.setTitle(newName)
                default:
                    break
                }
            }
            // Server disconnected
            DispatchQueue.main.async {
                cleanup()
                print("\r\nDisconnected.")
                exit(1)
            }
        }

        // Forward stdin to PTY with prefix key handling
        DispatchQueue.global(qos: .userInteractive).async {
            var buf = [UInt8](repeating: 0, count: 4096)
            var prefixHandler = AttachPrefixHandler(prefixByte: prefixByte, writeToPTY: { ptr, count in
                localSend(.input(sessionId: sessionId, data: Data(UnsafeBufferPointer(start: ptr, count: count))), fd: fd)
            })

            while true {
                var fds: [pollfd] = [
                    pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
                ]
                let pr = poll(&fds, 1, -1)
                if pr < 0 && errno != EINTR { break }
                guard fds[0].revents & Int16(POLLIN) != 0 else { continue }
                let n = read(STDIN_FILENO, &buf, buf.count)
                if n <= 0 { break }

                let action = prefixHandler.feed(&buf, count: n)
                switch action {
                case .none:
                    break
                case .detach:
                    DispatchQueue.main.async { cleanup(); print("\r\nDetached."); exit(0) }
                    return
                case .kill:
                    localSend(.killSession(sessionId: sessionId), fd: fd)
                    DispatchQueue.main.async { cleanup(); print("\r\nKilled."); exit(0) }
                    return
                }
            }

            DispatchQueue.main.async {
                cleanup()
                print("\r\nDetached (EOF).")
                exit(0)
            }
        }

        dispatchMain()
    }

    // MARK: - Service helpers

    private static let plistLabel = "com.termonmac.agent"
    /// Retained to prevent ARC from deallocating the dispatch source.
    private static var sighupSource: DispatchSourceSignal?

    /// Install a SIGHUP handler that calls the given closure (used to reload credentials).
    private static func installSIGHUPHandler(reload: @escaping () -> Void) {
        signal(SIGHUP, SIG_IGN)
        sighupSource = DispatchSource.makeSignalSource(signal: SIGHUP, queue: .main)
        sighupSource?.setEventHandler {
            log("[signal] SIGHUP received — reloading credentials")
            reload()
        }
        sighupSource?.resume()
    }

    private static func getUID() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/id")
        process.arguments = ["-u"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try? process.run()
        process.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "501"
    }

    static func isServiceLoaded() -> Bool {
        let uid = getUID()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["print", "gui/\(uid)/\(plistLabel)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    /// Whether the service plist exists and is not marked disabled in launchctl.
    /// "Enabled" means it will auto-start on login, regardless of whether it's currently running.
    static func isServiceEnabled() -> Bool {
        let plistPath = NSString(string: "~/Library/LaunchAgents/\(plistLabel).plist").expandingTildeInPath
        guard FileManager.default.fileExists(atPath: plistPath) else { return false }
        // Check if launchctl has it marked as disabled
        let uid = getUID()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["print-disabled", "gui/\(uid)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        // launchctl print-disabled output format: "com.termonmac.agent" => disabled
        return !output.contains("\"\(plistLabel)\" => disabled")
    }

    // MARK: - restart

    static func restartCommand(restartHelper: Bool = false) {
        guard isServiceLoaded() else {
            print("Service is not running. Use 'termonmac service enable' to start it.")
            return
        }
        if restartHelper {
            shutdownHelper()
        }
        let uid = getUID()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["kickstart", "-k", "gui/\(uid)/\(plistLabel)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        if process.terminationStatus == 0 {
            print("Service restarted.")
        } else {
            print("Failed to restart service (exit \(process.terminationStatus)).")
        }
    }

    // MARK: - start (bootstrap without changing enable/disable state)

    static func startCommand() {
        guard !isServiceLoaded() else {
            print("Service is already running.")
            return
        }
        let plistPath = NSString(string: "~/Library/LaunchAgents/\(plistLabel).plist").expandingTildeInPath
        guard FileManager.default.fileExists(atPath: plistPath) else {
            print("Service not installed. Use 'termonmac service enable' to install and start it.")
            return
        }
        guard isServiceEnabled() else {
            print("Service is disabled. Use 'termonmac service enable' to re-enable and start it.")
            return
        }
        let uid = getUID()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["bootstrap", "gui/\(uid)", plistPath]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        if process.terminationStatus == 0, isServiceLoaded() {
            print("Service started.")
        } else {
            print("Failed to start service (exit \(process.terminationStatus)). Check 'termonmac logs' for errors.")
        }
    }

    // MARK: - stop (bootout without disabling)

    static func stopCommand() {
        guard isServiceLoaded() else {
            print("Service is not running.")
            return
        }
        let plistPath = NSString(string: "~/Library/LaunchAgents/\(plistLabel).plist").expandingTildeInPath
        let uid = getUID()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["bootout", "gui/\(uid)", plistPath]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        if process.terminationStatus == 0 {
            print("Service stopped.")
        } else {
            print("Failed to stop service (exit \(process.terminationStatus)).")
        }
    }

    // MARK: - reload (internal)

    private static func sendSIGHUP() -> Bool {
        let uid = getUID()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["kill", "SIGHUP", "gui/\(uid)/\(plistLabel)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    private static func triggerReloadIfRunning() {
        guard isServiceLoaded() else { return }
        print("Reloading running agent with new credentials...")
        if sendSIGHUP() {
            print("Agent reloaded.")
        }
    }

    // MARK: - service

    private static func serviceCommand(_ args: [String]) {
        var positionalArgs = Array(args.dropFirst(2))
        while let idx = positionalArgs.firstIndex(of: "--config-dir") {
            positionalArgs.remove(at: idx)
            if idx < positionalArgs.count {
                positionalArgs.remove(at: idx)
            }
        }
        guard let sub = positionalArgs.first else {
            print("Usage: termonmac service <enable|disable|restart|start|stop>")
            exit(1)
        }
        switch sub {
        case "enable":
            installServiceCommand()
        case "disable":
            disableServiceCommand()
        case "restart":
            let restartHelper = positionalArgs.contains("--restart-helper")
            restartCommand(restartHelper: restartHelper)
        case "start":
            startCommand()
        case "stop":
            stopCommand()
        default:
            print("Unknown service command: \(sub)")
            print("Usage: termonmac service <enable|disable|restart|start|stop>")
            exit(1)
        }
    }

    // MARK: - enable

    static func installServiceCommand() {
        let launchAgentsDir = NSString("~/Library/LaunchAgents").expandingTildeInPath
        let plistPath = launchAgentsDir + "/\(plistLabel).plist"
        let fm = FileManager.default

        // Ensure ~/Library/LaunchAgents exists
        if !fm.fileExists(atPath: launchAgentsDir) {
            do {
                try fm.createDirectory(atPath: launchAgentsDir, withIntermediateDirectories: true)
            } catch {
                print("Failed to create \(launchAgentsDir): \(error.localizedDescription)")
                return
            }
        }

        let executablePath = ProcessInfo.processInfo.arguments[0]
        let logDir = configDir

        // Ensure config dir exists for logs
        if !fm.fileExists(atPath: logDir) {
            do {
                try fm.createDirectory(atPath: logDir, withIntermediateDirectories: true)
            } catch {
                print("Failed to create \(logDir): \(error.localizedDescription)")
                return
            }
        }

        let plistContent = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
          "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key>
          <string>\(plistLabel)</string>
          <key>ProgramArguments</key>
          <array>
            <string>\(executablePath)</string>
          </array>
          <key>RunAtLoad</key><true/>
          <key>KeepAlive</key><true/>
          <key>WorkingDirectory</key>
          <string>/private/var/empty</string>
          <key>StandardOutPath</key>
          <string>\(logDir)/agent.log</string>
          <key>StandardErrorPath</key>
          <string>\(logDir)/agent.err</string>
        </dict>
        </plist>
        """

        do {
            try plistContent.write(toFile: plistPath, atomically: true, encoding: .utf8)
            // Set permissions to 0644
            try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: plistPath)
        } catch {
            print("Failed to write plist: \(error.localizedDescription)")
            return
        }

        let uid = getUID()

        // Ensure service is enabled (reverses any prior `disable`)
        let enableProcess = Process()
        enableProcess.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        enableProcess.arguments = ["enable", "gui/\(uid)/\(plistLabel)"]
        enableProcess.standardOutput = FileHandle.nullDevice
        enableProcess.standardError = FileHandle.nullDevice
        try? enableProcess.run()
        enableProcess.waitUntilExit()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["bootstrap", "gui/\(uid)", plistPath]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            print("Failed to bootstrap service: \(error.localizedDescription)")
            return
        }

        if process.terminationStatus == 0 {
            if isServiceLoaded() {
                print("Service installed and running.")
            } else {
                print("Service installed but may not be running. Check 'termonmac logs' for errors.")
            }
            print("  Plist: \(plistPath)")
            print("  Logs:  termonmac logs")
        } else {
            print("launchctl bootstrap exited with status \(process.terminationStatus)")
        }

    }

    // MARK: - disable (stop but keep plist)

    static func disableServiceCommand() {
        let plistPath = NSString(string: "~/Library/LaunchAgents/\(plistLabel).plist").expandingTildeInPath
        guard FileManager.default.fileExists(atPath: plistPath) else {
            print("Service not installed. Nothing to disable.")
            return
        }

        let uid = getUID()

        // Stop if currently running
        if isServiceLoaded() {
            let bootoutProcess = Process()
            bootoutProcess.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            bootoutProcess.arguments = ["bootout", "gui/\(uid)", plistPath]
            bootoutProcess.standardOutput = FileHandle.nullDevice
            bootoutProcess.standardError = FileHandle.nullDevice
            try? bootoutProcess.run()
            bootoutProcess.waitUntilExit()
            print("Service stopped. It will not auto-start on login.")
        } else {
            print("Service was not running. Auto-start on login disabled.")
        }

        // Mark as disabled so it won't auto-start on login
        let disableProcess = Process()
        disableProcess.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        disableProcess.arguments = ["disable", "gui/\(uid)/\(plistLabel)"]
        disableProcess.standardOutput = FileHandle.nullDevice
        disableProcess.standardError = FileHandle.nullDevice
        try? disableProcess.run()
        disableProcess.waitUntilExit()
        print("  Run 'termonmac service enable' to re-enable.")
    }

    /// Stop the background service, shutdown the PTY helper, and remove the launch agent plist.
    /// Called internally by `resetCommand` — no user confirmation prompt.
    private static func uninstallService() {
        let plistPath = NSString(string: "~/Library/LaunchAgents/\(plistLabel).plist").expandingTildeInPath
        let fm = FileManager.default

        guard fm.fileExists(atPath: plistPath) else { return }

        shutdownHelper()

        let uid = getUID()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["bootout", "gui/\(uid)", plistPath]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            print("Failed to bootout service: \(error.localizedDescription)")
        }

        try? fm.removeItem(atPath: plistPath)
    }

    static func isHelperRunning() -> Bool {
        let pidFile = configDir + "/pty_helper.pid"
        guard let pidStr = try? String(contentsOfFile: pidFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
              let pid = Int32(pidStr),
              kill(pid, 0) == 0 else {
            return false
        }
        return true
    }

    private static func shutdownHelper() {
        let pidFile = configDir + "/pty_helper.pid"
        let socketFile = configDir + "/pty_helper.sock"

        guard let pidStr = try? String(contentsOfFile: pidFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
              let pid = Int32(pidStr),
              kill(pid, 0) == 0 else {
            return  // helper not running
        }

        let client = HelperClient()
        do {
            try client.connect(socketPath: socketFile)
            client.sendShutdown()
            // Give helper time to process shutdown (it uses a 100ms async delay)
            usleep(200_000)
            client.disconnect()
            print("PTY helper shutdown.")
        } catch {
            // Socket connect failed — helper may be in a bad state, send SIGTERM
            kill(pid, SIGTERM)
            print("PTY helper terminated.")
        }
    }

    static func restartHelperCommand() {
        guard isHelperRunning() else {
            print("PTY helper is not running.")
            return
        }
        shutdownHelper()
        print("Running service will respawn the helper automatically.")
    }

    // MARK: - Config JSON helpers

    private static func readConfigJSON() -> [String: Any] {
        let configPath = configDir + "/config.json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: configPath)) else {
            return [:]
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            log("[config] WARNING: config.json is corrupt, ignoring.")
            return [:]
        }
        return json
    }

    private static func writeConfigJSON(_ json: [String: Any]) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: configDir) {
            try fm.createDirectory(atPath: configDir, withIntermediateDirectories: true)
        }
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: configDir + "/config.json"))
    }

    // MARK: - Server URL resolution

    /// env var > ~/.config/termonmac/config.json > hardcoded default
    private static func resolveServerURL() -> String {
        if let envURL = ProcessInfo.processInfo.environment["RELAY_SERVER_URL"], !envURL.isEmpty {
            return envURL
        }
        if let url = readConfigJSON()["relay_server_url"] as? String {
            return url
        }
        return "wss://relay.termonmac.com"
    }

    // MARK: - Sandbox key resolution

    /// env var > ~/.config/termonmac/config.json > nil (production)
    private static func resolveSandboxKey() -> String? {
        if let key = ProcessInfo.processInfo.environment["SANDBOX_KEY"], !key.isEmpty {
            return key
        }
        if let key = readConfigJSON()["sandbox_key"] as? String, !key.isEmpty {
            return key
        }
        return nil
    }

    // MARK: - Work dir resolution

    /// CLI arg > env var WORK_DIR > config.json work_dir (no default — must be configured)
    private static func resolveWorkDir(_ args: [String]) -> String {
        // Skip binary and global flags (--config-dir <value>) to find the command,
        // then skip the command itself to get positional args.
        var idx = 1
        while idx < args.count {
            if args[idx] == "--config-dir" {
                idx += 2 // skip flag + value
            } else {
                break
            }
        }
        // idx points to the command word (if explicit) or past the end
        // Skip the command word if present (e.g. "default", "pair")
        if idx < args.count && !args[idx].hasPrefix("-") {
            idx += 1
        }
        // Filter remaining --config-dir pairs (in case they appear after the command)
        var positionalArgs = Array(args.dropFirst(idx))
        while let i = positionalArgs.firstIndex(of: "--config-dir") {
            positionalArgs.remove(at: i) // remove flag
            if i < positionalArgs.count {
                positionalArgs.remove(at: i) // remove value
            }
        }
        if let path = positionalArgs.first {
            let expanded = NSString(string: path).expandingTildeInPath
            if expanded.hasPrefix("/") {
                return expanded
            }
            return FileManager.default.currentDirectoryPath + "/" + expanded
        }
        if let envDir = ProcessInfo.processInfo.environment["WORK_DIR"], !envDir.isEmpty {
            return envDir
        }
        if let configDir = readConfigJSON()["work_dir"] as? String {
            return configDir
        }
        print("Error: no work directory configured.")
        print("Run 'termonmac config work-dir <path>' to set one.")
        exit(1)
    }

    // MARK: - OAuth helpers

    struct OAuthResult {
        let apiKey: String
        let refreshToken: String?
        let name: String?
        let email: String?
    }

    /// Start a local HTTP server on oauthCallbackPort, open the browser for OAuth,
    /// wait for the callback, and exchange the auth code for tokens.
    /// Returns nil on failure (timeout, cancelled, server error).
    private static func runOAuthFlow(provider: String) -> OAuthResult? {
        let httpURL = httpBaseURL()

        var stateBytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, stateBytes.count, &stateBytes)
        let state = stateBytes.map { String(format: "%02x", $0) }.joined()

        let port = oauthCallbackPort
        let semaphore = DispatchSemaphore(value: 0)
        var receivedCode: String?

        let serverQueue = DispatchQueue(label: "login-server")
        let serverSocketBox = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
        serverSocketBox.pointee = -1

        serverQueue.async {
            let sock = socket(AF_INET, SOCK_STREAM, 0)
            serverSocketBox.pointee = sock
            guard sock >= 0 else {
                semaphore.signal()
                return
            }

            var reuse: Int32 = 1
            setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")

            let bindResult = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bindResult == 0 else {
                close(sock)
                semaphore.signal()
                return
            }

            var timeout = timeval(tv_sec: 130, tv_usec: 0)
            setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

            listen(sock, 1)

            var clientAddr = sockaddr_in()
            var clientLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let clientSocket = withUnsafeMutablePointer(to: &clientAddr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    accept(sock, $0, &clientLen)
                }
            }
            guard clientSocket >= 0 else {
                close(sock)
                semaphore.signal()
                return
            }

            var buffer = [UInt8](repeating: 0, count: 4096)
            let bytesRead = recv(clientSocket, &buffer, buffer.count, 0)
            if bytesRead > 0 {
                let requestStr = String(bytes: buffer[0..<bytesRead], encoding: .utf8) ?? ""
                if let firstLine = requestStr.split(separator: "\r\n").first {
                    let parts = firstLine.split(separator: " ")
                    if parts.count >= 2 {
                        let path = String(parts[1])
                        if path.hasPrefix("/callback"),
                           let urlComponents = URLComponents(string: "http://localhost\(path)") {
                            let queryItems = urlComponents.queryItems ?? []
                            let code = queryItems.first(where: { $0.name == "code" })?.value
                            let callbackState = queryItems.first(where: { $0.name == "state" })?.value

                            if callbackState == state, let code = code {
                                receivedCode = code
                                let html = "<html><body style='font-family:sans-serif;text-align:center;padding:40px;background:#0d1117;color:#c9d1d9'><h2>Login successful!</h2><p>You can close this tab.</p></body></html>"
                                let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nConnection: close\r\n\r\n\(html)"
                                _ = response.withCString { send(clientSocket, $0, strlen($0), 0) }
                            } else {
                                let response = "HTTP/1.1 400 Bad Request\r\nContent-Type: text/plain\r\nConnection: close\r\n\r\nState mismatch or missing code"
                                _ = response.withCString { send(clientSocket, $0, strlen($0), 0) }
                            }
                        }
                    }
                }
            }

            close(clientSocket)
            close(sock)
            semaphore.signal()
        }

        let loginURL = "\(httpURL)/auth/web-login?port=\(port)&state=\(state)&reauth=1&provider=\(provider)"

        let openProcess = Process()
        openProcess.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        openProcess.arguments = [loginURL]
        try? openProcess.run()
        openProcess.waitUntilExit()

        if openProcess.terminationStatus != 0 {
            print("  Could not open browser. Visit this URL to sign in:")
            print("  \(loginURL)")
        }

        let semResult = semaphore.wait(timeout: .now() + 120)

        if semResult == .timedOut {
            close(serverSocketBox.pointee)
            serverSocketBox.deallocate()
            return nil
        }

        serverSocketBox.deallocate()

        guard let code = receivedCode else {
            return nil
        }

        // Exchange code for API key
        guard let exchangeURL = URL(string: "\(httpURL)/auth/exchange") else {
            return nil
        }

        var request = URLRequest(url: exchangeURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let sandboxKey = resolveSandboxKey() {
            request.setValue(sandboxKey, forHTTPHeaderField: "X-Sandbox-Key")
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["code": code])

        let exchangeSem = DispatchSemaphore(value: 0)
        var result: OAuthResult?

        URLSession.shared.dataTask(with: request) { data, _, _ in
            defer { exchangeSem.signal() }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let apiKey = json["api_key"] as? String else { return }
            result = OAuthResult(
                apiKey: apiKey,
                refreshToken: json["refresh_token"] as? String,
                name: json["name"] as? String,
                email: json["email"] as? String
            )
        }.resume()

        exchangeSem.wait()
        return result
    }

    /// Save OAuth result to config dir. Returns display name.
    @discardableResult
    private static func saveOAuthResult(_ result: OAuthResult) -> String? {
        if let rt = result.refreshToken, !rt.isEmpty {
            saveTokens(apiKey: result.apiKey, refreshToken: rt, configDir: configDir)
        } else {
            let fm = FileManager.default
            if !fm.fileExists(atPath: configDir) {
                try? fm.createDirectory(atPath: configDir, withIntermediateDirectories: true)
            }
            let apiKeyPath = configDir + "/api_key"
            try? result.apiKey.write(toFile: apiKeyPath, atomically: true, encoding: .utf8)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: apiKeyPath)
        }
        return result.name ?? result.email
    }

    // MARK: - HTTP helpers

    /// Convert WSS relay URL to HTTPS base URL
    private static func httpBaseURL() -> String {
        let wssURL = resolveServerURL()
        return wssURL
            .replacingOccurrences(of: "wss://", with: "https://")
            .replacingOccurrences(of: "ws://", with: "http://")
    }

    /// Automatically clean up stale rooms (no Mac connected) that aren't the current room.
    private static func cleanupStaleRooms(apiKey: String, currentRoomId: String) {
        guard let json = fetchJSON(endpoint: "/api/rooms", apiKey: apiKey),
              let rooms = json["rooms"] as? [[String: Any]] else {
            return
        }

        let staleRooms = rooms.filter { room in
            guard let roomId = room["room_id"] as? String,
                  let macConnected = room["mac_connected"] as? Bool else { return false }
            return roomId != currentRoomId && !macConnected
        }

        log("[rooms] total=\(rooms.count), stale=\(staleRooms.count), current=\(currentRoomId.prefix(6))")

        if staleRooms.isEmpty { return }

        for room in staleRooms {
            guard let roomId = room["room_id"] as? String else { continue }
            let httpURL = httpBaseURL()
            guard let url = URL(string: httpURL + "/api/rooms/\(roomId)") else { continue }

            var request = URLRequest(url: url)
            request.httpMethod = "DELETE"
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 10

            let sem = DispatchSemaphore(value: 0)
            var ok = false

            URLSession.shared.dataTask(with: request) { _, response, _ in
                defer { sem.signal() }
                if let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200 {
                    ok = true
                }
            }.resume()

            sem.wait()

            if ok {
                log("[rooms] purged stale room \(roomId.prefix(6))")
            } else {
                log("[rooms] failed to purge room \(roomId.prefix(6))")
            }
        }
    }

    /// Fetch JSON from relay endpoint with API key auth
    private static func fetchJSON(endpoint: String, apiKey: String) -> [String: Any]? {
        let httpURL = httpBaseURL()
        guard let url = URL(string: httpURL + endpoint) else { return nil }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        if let sandboxKey = resolveSandboxKey() {
            request.setValue(sandboxKey, forHTTPHeaderField: "X-Sandbox-Key")
        }

        let sem = DispatchSemaphore(value: 0)
        var responseData: Data?

        URLSession.shared.dataTask(with: request) { data, _, _ in
            responseData = data
            sem.signal()
        }.resume()

        sem.wait()

        guard let data = responseData,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    // MARK: - API key loading

    /// file > env var > nil
    private static func loadAPIKey() -> String? {
        let filePath = configDir + "/api_key"
        if let key = try? String(contentsOfFile: filePath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !key.isEmpty {
            log("[auth] API key loaded from \(filePath)")
            return key
        }
        if let key = ProcessInfo.processInfo.environment["RELAY_API_KEY"], !key.isEmpty {
            log("[auth] API key loaded from RELAY_API_KEY env var")
            return key
        }
        log("[auth] No API key found — connecting anonymously")
        return nil
    }

    // MARK: - Refresh token loading

    /// file > env var > nil
    static func loadRefreshToken() -> String? {
        let filePath = configDir + "/refresh_token"
        if let token = try? String(contentsOfFile: filePath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !token.isEmpty {
            return token
        }
        if let token = ProcessInfo.processInfo.environment["RELAY_REFRESH_TOKEN"], !token.isEmpty {
            return token
        }
        return nil
    }

    /// Save both API key and refresh token to config dir with 0600 permissions.
    /// Returns true only if BOTH files were written successfully.
    @discardableResult
    static func saveTokens(apiKey: String, refreshToken: String, configDir: String) -> Bool {
        let fm = FileManager.default
        if !fm.fileExists(atPath: configDir) {
            try? fm.createDirectory(atPath: configDir, withIntermediateDirectories: true)
        }
        let apiKeyPath = configDir + "/api_key"
        let refreshTokenPath = configDir + "/refresh_token"
        var ok = true
        do {
            try apiKey.write(toFile: apiKeyPath, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: apiKeyPath)
        } catch {
            log("[auth] WARNING: failed to save api_key to \(apiKeyPath): \(error.localizedDescription)")
            ok = false
        }
        do {
            try refreshToken.write(toFile: refreshTokenPath, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: refreshTokenPath)
        } catch {
            log("[auth] WARNING: failed to save refresh_token to \(refreshTokenPath): \(error.localizedDescription)")
            ok = false
        }
        return ok
    }
}
#endif
