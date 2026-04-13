import Foundation

#if os(macOS)

// MARK: - TUI Main Screen & Sub-menus

extension TUIMenu {

    // MARK: - Entry point

    static func start() {
        guard isatty(STDIN_FILENO) != 0 else {
            print("TUI requires an interactive terminal.")
            exit(1)
        }

        // Trigger background version check cache refresh
        VersionChecker.refreshCacheInBackground()

        enableRawMode()
        hideCursor()

        let result = mainMenu()

        showCursor()
        clearScreen()
        disableRawMode()

        // Handle deferred actions (must happen after TUI teardown)
        switch result {
        case .attachSession(let sessionId):
            CLIRouter.runAttach(sessionId: sessionId)
        case .upgrade:
            VersionChecker.performUpgrade()
        default:
            break
        }
    }

    // MARK: - Main menu

    private static func mainMenu() -> MenuResult {
        let version = CLIRouter.version
        let updateInfo = VersionChecker.cachedUpdateInfo()

        while true {
            var items: [MenuItem] = [
                MenuItem(label: "Sessions",  action: sessionsMenu),
                MenuItem(label: "Rooms",     action: roomsMenu),
                MenuItem(label: "Service",   action: servicesMenu),
                MenuItem(label: "Account",   action: accountMenu),
                MenuItem(label: "Config",    action: configMenu),
                MenuItem(label: "Reset",     action: resetMenu),
            ]

            if let update = updateInfo {
                items.append(MenuItem(label: yellow("Upgrade to \(update.latestVersion)")) { .upgrade })
            }

            let header = updateInfo.map { yellow("Update available: \(version) → \($0.latestVersion)") }

            let result = runMenu(
                title: "TermOnMac v\(version)",
                items: items,
                header: header
            )
            switch result {
            case .back: continue  // main menu has no parent
            case .quit: return .quit
            case .attachSession, .upgrade: return result
            case .stay, .refreshMenu: continue
            }
        }
    }

    // MARK: - Sessions

    private static func sessionsMenu() -> MenuResult {
        while true {
            // Fetch live session list
            let sessions = fetchSessions()
            let isNested = CLIRouter.isInsideManagedSession(sessions)
            var items: [MenuItem] = []

            if sessions.isEmpty {
                items.append(MenuItem(label: dim("(no active sessions)")) { .stay })
            } else {
                for s in sessions {
                    let sid = s.sessionId
                    let ctrlStr: String
                    switch s.controller {
                    case .ios: ctrlStr = yellow("iOS")
                    case .mac: ctrlStr = green("Mac")
                    case .none: ctrlStr = dim("-")
                    }
                    let typeStr = s.sessionType.map { " [\($0.rawValue)]" } ?? ""
                    let label = "\(s.name)\(typeStr)  (\(ctrlStr))"
                    items.append(MenuItem(label: label) {
                        if isNested {
                            disableRawMode(); showCursor()
                            print("\n  Attach is not available from a nested TermOnMac session.")
                            print("  Use the iOS app session list to switch sessions.")
                            print("\n  Press Enter to return...", terminator: "")
                            _ = readLine()
                            enableRawMode(); hideCursor()
                            return .stay
                        }
                        return .attachSession(sid)
                    })
                }
            }

            items.append(MenuItem(label: green("+ New session")) {
                newSessionAction()
            })

            let headerText: String
            if isNested {
                headerText = "\(sessions.count) active session\(sessions.count == 1 ? "" : "s")  " + yellow("(nested — attach disabled)")
            } else {
                headerText = "\(sessions.count) active session\(sessions.count == 1 ? "" : "s")"
            }

            let result = runMenu(
                title: "Sessions",
                items: items,
                header: headerText,
                footer: {
                    if isNested {
                        return "r rename  p path  x kill  ⌫ back  q quit"
                    }
                    let hasMac = sessions.contains(where: { $0.controller == .mac })
                    if sessions.isEmpty {
                        return "⏎ select  ⌫ back  q quit"
                    } else if hasMac {
                        return "a/⏎ attach  r rename  p path  d detach  x kill  ⌫ back  q quit"
                    } else {
                        return "a/⏎ attach  r rename  p path  x kill  ⌫ back  q quit"
                    }
                }(),
                charActions: [
                    "a": { cursor in
                        guard cursor < sessions.count else { return .stay }
                        if isNested {
                            disableRawMode(); showCursor()
                            print("\n  Attach is not available from a nested TermOnMac session.")
                            print("  Use the iOS app session list to switch sessions.")
                            print("\n  Press Enter to return...", terminator: "")
                            _ = readLine()
                            enableRawMode(); hideCursor()
                            return .stay
                        }
                        return .attachSession(sessions[cursor].sessionId)
                    },
                    "d": { cursor in
                        guard cursor < sessions.count else { return .stay }
                        let s = sessions[cursor]
                        guard s.controller == .mac else { return .stay }
                        return detachSessionAction(sessionId: s.sessionId, name: s.name)
                    },
                    "r": { cursor in
                        guard cursor < sessions.count else { return .stay }
                        let s = sessions[cursor]
                        return renameSessionAction(sessionId: s.sessionId, name: s.name)
                    },
                    "p": { cursor in
                        guard cursor < sessions.count else { return .stay }
                        let s = sessions[cursor]
                        let path = s.cwd.map { shortPath($0) } ?? "(no working directory)"
                        disableRawMode()
                        showCursor()
                        print("\n  \(path)\n")
                        print("  Press Enter to return...", terminator: "")
                        _ = readLine()
                        enableRawMode()
                        hideCursor()
                        return .stay
                    },
                    "x": { cursor in
                        guard cursor < sessions.count else { return .stay }
                        let s = sessions[cursor]
                        return killSessionAction(sessionId: s.sessionId, name: s.name)
                    },
                ]
            )

            switch result {
            case .stay, .refreshMenu: continue
            case .back: return .stay
            case .quit: return .quit
            case .attachSession, .upgrade: return result
            }
        }
    }

    private static func newSessionAction() -> MenuResult {
        if CLIRouter.isInsideManagedSession(fetchSessions()) {
            disableRawMode(); showCursor()
            print("\n  Cannot create and attach from a nested TermOnMac session.")
            print("  Use: termonmac session create --bg <work-dir>")
            print("\n  Press Enter to return...", terminator: "")
            _ = readLine()
            enableRawMode(); hideCursor()
            return .stay
        }
        guard let workDir = promptPath("Work directory:") else { return .stay }
        let expanded = NSString(string: workDir).expandingTildeInPath
        let absolute = expanded.hasPrefix("/")
            ? expanded
            : FileManager.default.currentDirectoryPath + "/" + expanded

        guard FileManager.default.fileExists(atPath: absolute) else {
            disableRawMode()
            showCursor()
            print("\nDirectory not found: \(absolute)")
            print("Press Enter to return...", terminator: "")
            _ = readLine()
            enableRawMode()
            hideCursor()
            return .stay
        }

        // Prompt session name (default: last path component)
        let defaultName = URL(fileURLWithPath: absolute).lastPathComponent
        guard let sessionName = prompt("Session name:", default: defaultName) else { return .stay }

        // Create session via IPC
        let fd = CLIRouter.connectToAgentSocket()
        var ws = winsize()
        let cols = ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0 ? Int(ws.ws_col) : 80
        let rawRows = ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0 ? Int(ws.ws_row) : 24
        let rows = CLIRouter.isAttachStatusBarEnabled() && rawRows > 2 ? rawRows - 1 : rawRows

        guard case .createSessionResult(let newId, let error) =
                CLIRouter.localRequest(.createSession(name: sessionName, cols: cols, rows: rows, workDir: absolute), fd: fd) else {
            close(fd)
            disableRawMode()
            showCursor()
            print("\nFailed to create session.")
            print("Press Enter to return...", terminator: "")
            _ = readLine()
            enableRawMode()
            hideCursor()
            return .stay
        }
        close(fd)

        guard let newId else {
            disableRawMode()
            showCursor()
            print("\nCreate failed: \(error ?? "unknown")")
            print("Press Enter to return...", terminator: "")
            _ = readLine()
            enableRawMode()
            hideCursor()
            return .stay
        }

        return .attachSession(newId)
    }

    private static func killSessionAction(sessionId: String, name: String) -> MenuResult {
        guard confirm("Kill session '\(name)'? [y/N]") else { return .stay }
        guard confirmExact("Are you sure? Type uppercase Y to confirm:", expected: "Y") else { return .stay }
        let fd = CLIRouter.connectToAgentSocketOrNil()
        guard let fd else { return .stay }
        _ = CLIRouter.localRequest(.killSession(sessionId: sessionId), fd: fd)
        close(fd)
        return .refreshMenu
    }

    private static func detachSessionAction(sessionId: String, name: String) -> MenuResult {
        guard confirm("Detach session '\(name)'? [y/N]") else { return .stay }
        let fd = CLIRouter.connectToAgentSocketOrNil()
        guard let fd else { return .stay }
        _ = CLIRouter.localRequest(.forceDetach(sessionId: sessionId), fd: fd)
        close(fd)
        return .refreshMenu
    }

    private static func renameSessionAction(sessionId: String, name: String) -> MenuResult {
        guard let newName = prompt("Rename '\(name)' to:") else { return .stay }
        let fd = CLIRouter.connectToAgentSocketOrNil()
        guard let fd else { return .stay }
        _ = CLIRouter.localRequest(.renameSession(sessionId: sessionId, name: newName), fd: fd)
        close(fd)
        return .refreshMenu
    }

    private static func fetchSessions() -> [LocalSessionInfo] {
        let fd = CLIRouter.connectToAgentSocketOrNil()
        guard let fd else { return [] }
        defer { close(fd) }
        guard case .sessionList(let sessions) = CLIRouter.localRequest(.listSessions, fd: fd) else {
            return []
        }
        return sessions
    }

    private static func shortPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    // MARK: - Rooms

    private static func roomsMenu() -> MenuResult {
        while true {
            let localRoomId = CLIRouter.localRoomId()
            let roomData = CLIRouter.fetchRooms()
            let rooms = roomData?.rooms ?? []

            var items: [MenuItem] = []

            // Room list (informational)
            if rooms.isEmpty {
                items.append(MenuItem(label: dim("(no rooms)")) { .stay })
            } else {
                for room in rooms {
                    guard let roomId = room["room_id"] as? String else { continue }
                    let macOk = room["mac_connected"] as? Bool ?? false
                    let iosOk = room["ios_connected"] as? Bool ?? false
                    let lastSeen = room["last_seen"] as? Double ?? 0
                    let isLocal = roomId == localRoomId
                    let macIcon = macOk ? green("✓") : dim("✗")
                    let iosIcon = iosOk ? green("✓") : dim("✗")
                    let timeStr = CLIRouter.relativeTime(from: lastSeen)
                    let suffix = isLocal ? yellow(" ← this mac") : ""
                    let idShort = String(roomId.prefix(6))
                    let label = "\(idShort)  mac:\(macIcon) ios:\(iosIcon)  \(dim(timeStr))\(suffix)"
                    items.append(MenuItem(label: label) { .stay })
                }
            }

            // Separator: logs for local room
            items.append(MenuItem(label: "") { .stay })
            items.append(MenuItem(label: "View logs (last 1h)") {
                runAction(label: "Logs — last 1h") { CLIRouter.logsCommand(["termonmac", "logs"]) }
            })
            items.append(MenuItem(label: "Stream live logs") {
                runAction(label: "Live Logs (Ctrl-C to stop)") {
                    CLIRouter.logsCommand(["termonmac", "logs", "--stream"])
                }
            })

            // Pair
            items.append(MenuItem(label: green("+ Pair new device")) {
                runAction(label: "Pair iOS") { CLIRouter.pairCommand() }
            })

            let headerLine: String
            if let data = roomData {
                headerLine = "\(rooms.count)/\(data.limit) rooms (\(data.tier) tier)"
            } else {
                headerLine = dim("(not logged in)")
            }

            let result = runMenu(
                title: "Rooms",
                items: items,
                header: headerLine,
                footer: "⏎ select  ⌫ back  q quit"
            )

            switch result {
            case .stay, .refreshMenu: continue
            case .back: return .stay
            case .quit: return .quit
            case .attachSession, .upgrade: return result
            }
        }
    }

    // MARK: - Service

    private static func servicesMenu() -> MenuResult {
        while true {
            let running = CLIRouter.isServiceLoaded()
            let enabled = CLIRouter.isServiceEnabled()

            let statusLine: String
            if running {
                statusLine = green("● running")
            } else if enabled {
                statusLine = yellow("● stopped")
            } else {
                statusLine = red("● disabled")
            }

            var items: [MenuItem] = []

            // enable: only when not enabled
            if !enabled {
                items.append(MenuItem(label: "Enable service") {
                    runAction(label: "Enable service") { CLIRouter.installServiceCommand() }
                })
            }
            // start: only when not running (and enabled)
            if !running && enabled {
                items.append(MenuItem(label: "Start service") {
                    runAction(label: "Start service") { CLIRouter.startCommand() }
                })
            }
            // restart: only when running
            if running {
                items.append(MenuItem(label: "Restart service") {
                    guard confirm("Restart the background service? Sessions will be kept. [y/N]") else { return .stay }
                    return runAction(label: "Restart") { CLIRouter.restartCommand() }
                })
            }
            // full restart: only when running
            if running {
                items.append(MenuItem(label: "Full restart (drops sessions)") {
                    guard confirm("Restart service and terminal sessions? All sessions will be lost. [y/N]") else { return .stay }
                    return runAction(label: "Full restart") { CLIRouter.restartCommand(restartHelper: true) }
                })
            }
            // stop: only when running
            if running {
                items.append(MenuItem(label: "Stop service") {
                    guard confirm("Stop the background service? [y/N]") else { return .stay }
                    return runAction(label: "Stop") { CLIRouter.stopCommand() }
                })
            }
            // disable: only when enabled (least common)
            if enabled {
                items.append(MenuItem(label: "Disable service") {
                    guard confirm("Disable the background service? [y/N]") else { return .stay }
                    return runAction(label: "Disable service") { CLIRouter.disableServiceCommand() }
                })
            }

            let result = runMenu(
                title: "Service",
                items: items,
                header: "Status: \(statusLine)",
                footer: "⏎ select  ⌫ back  q quit"
            )

            switch result {
            case .stay, .refreshMenu: continue
            case .back: return .stay
            case .quit: return .quit
            case .attachSession, .upgrade: return result
            }
        }
    }

    // MARK: - Account

    private static func accountMenu() -> MenuResult {
        while true {
            // Fetch profile (network call, but only on menu entry/refresh)
            let profile = CLIRouter.fetchProfile()
            let loggedIn = profile != nil
            let headerLine: String
            if let profile,
               let name = profile["name"] as? String ?? profile["email"] as? String {
                let email = (profile["email"] as? String).map { " (\($0))" } ?? ""
                let provider = (profile["primary_provider"] as? String) ?? ""
                let providerSuffix = provider.isEmpty ? "" : " via \(provider.capitalized)"
                headerLine = green("✓") + " \(name)\(email)\(providerSuffix)"
            } else {
                headerLine = red("✗") + " not logged in"
            }

            var items: [MenuItem] = [
                MenuItem(label: "Login (GitHub)") {
                    runAction(label: "Login") { CLIRouter.loginCommand(["termonmac", "auth", "login", "github"]) }
                },
                MenuItem(label: "Login (Google)") {
                    runAction(label: "Login") { CLIRouter.loginCommand(["termonmac", "auth", "login", "google"]) }
                },
                MenuItem(label: "Login (Apple)") {
                    runAction(label: "Login") { CLIRouter.loginCommand(["termonmac", "auth", "login", "apple"]) }
                },
            ]

            if loggedIn {
                items.append(MenuItem(label: "Show full status") {
                    runAction(label: "Account Status") { CLIRouter.statusCommand(["termonmac", "status"]) }
                })
                items.append(MenuItem(label: "Logout") {
                    if confirm("Are you sure you want to logout? [y/N]") {
                        return runAction(label: "Logout") { CLIRouter.logoutCommand() }
                    }
                    return .stay
                })
            }

            let result = runMenu(
                title: "Account",
                items: items,
                header: headerLine,
                footer: "⏎ select  ⌫ back  q quit"
            )

            switch result {
            case .stay, .refreshMenu: continue
            case .back: return .stay
            case .quit: return .quit
            case .attachSession, .upgrade: return result
            }
        }
    }

    // MARK: - Config

    private static func configMenu() -> MenuResult {
        while true {
            let workDirDisplay = CLIRouter.currentWorkDir().map { shortPath($0) } ?? "(not set)"
            let roomNameDisplay = CLIRouter.currentRoomName() ?? "(not set)"
            let statusBarOn = CLIRouter.isAttachStatusBarEnabled()

            let result = runMenu(
                title: "Config",
                items: [
                    MenuItem(label: "work-dir        \(dim(workDirDisplay))") {
                        guard let path = promptPath("New work-dir:") else { return .stay }
                        return runAction(label: "Set work-dir") {
                            CLIRouter.configCommand(["termonmac", "config", "work-dir", path])
                        }
                    },
                    MenuItem(label: "room-name       \(dim(roomNameDisplay))") {
                        guard let name = prompt("New room name:") else { return .stay }
                        return runAction(label: "Set room-name") {
                            CLIRouter.configCommand(["termonmac", "config", "room-name", name])
                        }
                    },
                    MenuItem(label: "status-bar      \(statusBarOn ? green("on") : red("off"))") {
                        CLIRouter.toggleAttachStatusBar()
                        return .refreshMenu
                    },
                    MenuItem(label: "Full Disk Access") {
                        runAction(label: "Full Disk Access") {
                            CLIRouter.configCommand(["termonmac", "config", "full-disk-access"])
                        }
                    },
                ],
                footer: "⏎ edit  ⌫ back  q quit"
            )

            switch result {
            case .stay, .refreshMenu: continue
            case .back: return .stay
            case .quit: return .quit
            case .attachSession, .upgrade: return result
            }
        }
    }

    // MARK: - Reset

    private static func resetMenu() -> MenuResult {
        // resetCommand has its own confirmation prompt — no need to double-confirm here
        return runAction(label: "Reset") {
            CLIRouter.resetCommand(["termonmac", "reset"])
        }
    }
}

#endif
