import Foundation
import BuildKit

#if os(macOS)
// Status messages go to stderr so stdout is pure xcodebuild output (pipeable to xcbeautify)
func stderr(_ msg: String) {
    FileHandle.standardError.write(Data("\(msg)\n".utf8))
}

func usage() -> Never {
    stderr("""
    Usage:
      BuildCLI list-projects [--workdir <path>]
      BuildCLI list-schemes  [--workdir <path>] [--project <path>]
      BuildCLI signing-info  --scheme <name> [--workdir <path>] [--project <path>]
      BuildCLI build         --scheme <name> [--action <build|archive|exportUpload>] [--project <path>] [--workdir <path>] [--configuration <cfg>] [--sdk <sdk>] [--team-id <id>] [--asc-key-id <id>] [--asc-issuer-id <id>] [--asc-key-path <path>]
      BuildCLI pipeline      --scheme <name> --team-id <id> [--project <path>] [--workdir <path>] [--configuration <cfg>] [--sdk <sdk>] [--asc-key-id <id>] [--asc-issuer-id <id>] [--asc-key-path <path>]
    """)
    exit(1)
}

// MARK: - Argument parsing

let args = Array(CommandLine.arguments.dropFirst())
guard let subcommand = args.first else { usage() }

func flag(_ name: String) -> String? {
    guard let idx = args.firstIndex(of: name), idx + 1 < args.count else { return nil }
    return args[idx + 1]
}

let workDir = flag("--workdir") ?? FileManager.default.currentDirectoryPath
let projectPath = flag("--project")
let scheme = flag("--scheme")
let action = flag("--action") ?? "build"
let configuration = flag("--configuration")
let sdk = flag("--sdk")
let teamId = flag("--team-id")
let ascKeyId = flag("--asc-key-id")
let ascIssuerId = flag("--asc-issuer-id")
let ascKeyPath = flag("--asc-key-path")

let buildManager = BuildManager()

// Configure ASC if provided
if let kid = ascKeyId, let iss = ascIssuerId {
    buildManager.ascConfigState = .configured(ASCConfig(keyId: kid, issuerId: iss, keyPath: ascKeyPath ?? ""))
}

// MARK: - SIGINT handler

signal(SIGINT) { _ in
    buildManager.cancel()
    stderr("\nBuild cancelled.")
    exit(130)
}

// MARK: - Helpers

/// Run a build action synchronously using a semaphore. Returns true on success.
@discardableResult
func runBuildSync(scheme: String, action: String, configuration: String?, sdk: String?, teamId: String?, projectPath: String?, workDir: String) -> Bool {
    let sem = DispatchSemaphore(value: 0)
    var success = false

    buildManager.onOutput = { data in
        FileHandle.standardOutput.write(data)
    }
    buildManager.onStatusChange = { status, message, _, _ in
        if status == "succeeded" || status == "failed" || status == "cancelled" {
            success = status == "succeeded"
            stderr("[BuildCLI] \(message)")
            sem.signal()
        } else {
            stderr("[BuildCLI] \(message)")
        }
    }

    do {
        if let proj = projectPath {
            try buildManager.startBuildInProject(scheme: scheme, action: action, configuration: configuration, sdk: sdk, teamId: teamId, projectPath: proj)
        } else {
            try buildManager.startBuild(scheme: scheme, action: action, configuration: configuration, sdk: sdk, teamId: teamId, workDir: workDir)
        }
    } catch {
        stderr("[BuildCLI] Error: \(error.localizedDescription)")
        return false
    }

    sem.wait()
    return success
}

// MARK: - Subcommands

switch subcommand {
case "list-projects":
    do {
        let projects = try buildManager.listProjects(workDir: workDir)
        if projects.isEmpty {
            stderr("No projects found in \(workDir)")
            exit(1)
        }
        for p in projects {
            print("\(p["type"] ?? "?")  \(p["name"] ?? "?")  \(p["path"] ?? "")")
        }
    } catch {
        stderr("Error: \(error.localizedDescription)")
        exit(1)
    }

case "list-schemes":
    do {
        let result: (schemes: [String], project: String)
        if let proj = projectPath {
            result = try buildManager.listSchemesForProject(projectPath: proj)
        } else {
            result = try buildManager.listSchemes(workDir: workDir)
        }
        stderr("Project: \(result.project)")
        if result.schemes.isEmpty {
            stderr("No schemes found.")
            exit(1)
        }
        for s in result.schemes {
            print(s)
        }
    } catch {
        stderr("Error: \(error.localizedDescription)")
        exit(1)
    }

case "signing-info":
    guard let scheme = scheme else {
        stderr("Error: --scheme is required for signing-info")
        usage()
    }
    do {
        let info: (team: String, style: String, profile: String, cert: String, bundleId: String, ascKeyConfigured: Bool, ascKeyFileExists: Bool, archiveExists: Bool)
        if let proj = projectPath {
            info = try buildManager.getSigningInfoForProject(scheme: scheme, projectPath: proj)
        } else {
            info = try buildManager.getSigningInfo(scheme: scheme, workDir: workDir)
        }
        print("Team:           \(info.team)")
        print("Style:          \(info.style)")
        print("Profile:        \(info.profile)")
        print("Certificate:    \(info.cert)")
        print("Bundle ID:      \(info.bundleId)")
        print("ASC configured: \(info.ascKeyConfigured)")
        print("ASC key exists: \(info.ascKeyFileExists)")
        print("Archive exists: \(info.archiveExists)")
    } catch {
        stderr("Error: \(error.localizedDescription)")
        exit(1)
    }

case "build":
    guard let scheme = scheme else {
        stderr("Error: --scheme is required for build")
        usage()
    }
    let ok = runBuildSync(scheme: scheme, action: action, configuration: configuration, sdk: sdk, teamId: teamId, projectPath: projectPath, workDir: workDir)
    exit(ok ? 0 : 1)

case "pipeline":
    guard let scheme = scheme else {
        stderr("Error: --scheme is required for pipeline")
        usage()
    }
    guard let teamId = teamId else {
        stderr("Error: --team-id is required for pipeline")
        usage()
    }

    let steps = ["build", "archive", "exportUpload"]
    for step in steps {
        stderr("==> Pipeline step: \(step)")
        let ok = runBuildSync(scheme: scheme, action: step, configuration: configuration, sdk: sdk, teamId: teamId, projectPath: projectPath, workDir: workDir)
        if !ok {
            stderr("==> Pipeline failed at step: \(step)")
            exit(1)
        }
    }
    stderr("==> Pipeline completed successfully")
    exit(0)

default:
    stderr("Unknown subcommand: \(subcommand)")
    usage()
}
#else
import Darwin
exit(0)
#endif
