import Testing
import Foundation
@testable import MacAgentLib
import RemoteDevCore

// MARK: - stripFileURL replica
// stripFileURL lives in the TermOnMac executable target (AgentService.swift),
// which cannot be @testable-imported. We duplicate the function here to test
// its logic without changing production code layout.

private func stripFileURL(_ path: String) -> String {
    guard path.hasPrefix("file://") else { return path }
    if let url = URL(string: path), url.scheme == "file" {
        return url.path
    }
    let afterScheme = path.dropFirst(7) // drop "file://"
    if let slashIdx = afterScheme.firstIndex(of: "/") {
        return String(afterScheme[slashIdx...])
    }
    return path
}

// MARK: - CLIRouter.run command parsing replica
// Tests the command dispatch logic: given args, which command string is selected.

private func parseCommand(_ args: [String]) -> String {
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
        return "default"
    case "pair", "reset-room", "status", "setup-asc", "reset",
         "login", "logout", "logs", "config", "restart", "reload":
        return command
    case "rename-room":
        return "rename-room"
    case "enable":
        return "enable"
    case "disable":
        return "disable"   // separate from uninstall-service in real CLI
    case "uninstall-service":
        return "uninstall-service"
    case "version", "--version", "-v":
        return "version"
    case "help", "--help", "-h":
        return "help"
    default:
        return "unknown"
    }
}

// MARK: - Tests

@Suite("AgentService — stripFileURL")
struct StripFileURLTests {

    @Test("plain path returned unchanged")
    func plainPath() {
        #expect(stripFileURL("/Users/dev/project") == "/Users/dev/project")
    }

    @Test("relative path returned unchanged")
    func relativePath() {
        #expect(stripFileURL("some/relative/path") == "some/relative/path")
    }

    @Test("file:// URL with hostname stripped to path")
    func fileURLWithHostname() {
        let result = stripFileURL("file://macbook.local/Users/dev/project")
        #expect(result == "/Users/dev/project")
    }

    @Test("file:// URL without hostname (triple slash)")
    func fileURLTripleSlash() {
        let result = stripFileURL("file:///Users/dev/project")
        #expect(result == "/Users/dev/project")
    }

    @Test("file:// URL with localhost hostname")
    func fileURLLocalhost() {
        let result = stripFileURL("file://localhost/Users/dev/project")
        #expect(result == "/Users/dev/project")
    }

    @Test("empty string returned unchanged")
    func emptyString() {
        #expect(stripFileURL("") == "")
    }

    @Test("file:// with spaces in path")
    func fileURLWithSpaces() {
        // URL(string:) may fail with spaces, test fallback
        let result = stripFileURL("file://host/Users/dev/my project")
        #expect(result.contains("/Users/dev/my project") || result.hasPrefix("/"))
    }

    @Test("non-file URL scheme returned unchanged")
    func nonFileScheme() {
        #expect(stripFileURL("https://example.com/path") == "https://example.com/path")
    }
}

@Suite("CLIRouter — command parsing")
struct CLIRouterCommandParsingTests {

    @Test("no args defaults to 'default'")
    func noArgs() {
        #expect(parseCommand(["termonmac"]) == "default")
    }

    @Test("empty args defaults to 'default'")
    func emptyArgs() {
        #expect(parseCommand([]) == "default")
    }

    @Test("'pair' command recognized")
    func pairCommand() {
        #expect(parseCommand(["termonmac", "pair"]) == "pair")
    }

    @Test("'status' command recognized")
    func statusCommand() {
        #expect(parseCommand(["termonmac", "status"]) == "status")
    }

    @Test("'version' command recognized")
    func versionCommand() {
        #expect(parseCommand(["termonmac", "version"]) == "version")
    }

    @Test("'--version' alias works")
    func versionAlias() {
        #expect(parseCommand(["termonmac", "--version"]) == "version")
    }

    @Test("'-v' alias works")
    func versionShortAlias() {
        #expect(parseCommand(["termonmac", "-v"]) == "version")
    }

    @Test("'help' command recognized")
    func helpCommand() {
        #expect(parseCommand(["termonmac", "help"]) == "help")
    }

    @Test("'--help' alias works")
    func helpAlias() {
        #expect(parseCommand(["termonmac", "--help"]) == "help")
    }

    @Test("'-h' alias works")
    func helpShortAlias() {
        #expect(parseCommand(["termonmac", "-h"]) == "help")
    }

    @Test("'enable' command recognized")
    func enableCommand() {
        #expect(parseCommand(["termonmac", "enable"]) == "enable")
    }

    @Test("'disable' command recognized")
    func disableCommand() {
        #expect(parseCommand(["termonmac", "disable"]) == "disable")
    }

    @Test("unknown command returns 'unknown'")
    func unknownCommand() {
        #expect(parseCommand(["termonmac", "foobar"]) == "unknown")
    }

    @Test("'login' command recognized")
    func loginCommand() {
        #expect(parseCommand(["termonmac", "login"]) == "login")
    }

    @Test("'logout' command recognized")
    func logoutCommand() {
        #expect(parseCommand(["termonmac", "logout"]) == "logout")
    }

    @Test("'config' command recognized")
    func configCommand() {
        #expect(parseCommand(["termonmac", "config"]) == "config")
    }

    @Test("extra args after command are preserved")
    func extraArgs() {
        #expect(parseCommand(["termonmac", "pair", "--extra"]) == "pair")
    }

    @Test("--config-dir before command is skipped")
    func configDirBeforeCommand() {
        #expect(parseCommand(["termonmac", "--config-dir", "/tmp/cfg", "pair"]) == "pair")
    }

    @Test("--config-dir without command defaults to 'default'")
    func configDirOnly() {
        #expect(parseCommand(["termonmac", "--config-dir", "/tmp/cfg"]) == "default")
    }

    @Test("--config-dir without value defaults to 'default'")
    func configDirNoValue() {
        #expect(parseCommand(["termonmac", "--config-dir"]) == "default")
    }

    @Test("multiple --config-dir flags skipped")
    func multipleConfigDir() {
        #expect(parseCommand(["termonmac", "--config-dir", "/a", "--config-dir", "/b", "status"]) == "status")
    }
}
