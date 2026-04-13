import Foundation
import RemoteDevCore

public struct ASCConfig {
    public let keyId: String
    public let issuerId: String
    public let keyPath: String

    public init(keyId: String, issuerId: String, keyPath: String) {
        self.keyId = keyId
        self.issuerId = issuerId
        self.keyPath = keyPath
    }
}

public enum ASCConfigState {
    case unset               // no config file, env vars fallback active
    case disabled            // user explicitly reset, completely disabled
    case configured(ASCConfig)
}

#if os(macOS)
public final class BuildManager: @unchecked Sendable {
    private let lock = NSLock()
    private var _onOutput: ((Data) -> Void)?
    private var _onStatusChange: ((String, String, String?, String?) -> Void)?
    private var _ascConfigState: ASCConfigState = .unset
    private var _process: Process?
    private var _lastStatus = ""
    private var _lastMessage = ""
    private var _lastAction = ""
    private var _lastBranch: String?
    private var _lastCommit: String?

    public var onOutput: ((Data) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onOutput }
        set { lock.lock(); defer { lock.unlock() }; _onOutput = newValue }
    }
    public var onStatusChange: ((String, String, String?, String?) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onStatusChange }
        set { lock.lock(); defer { lock.unlock() }; _onStatusChange = newValue }
    }
    public var ascConfigState: ASCConfigState {
        get { lock.lock(); defer { lock.unlock() }; return _ascConfigState }
        set { lock.lock(); defer { lock.unlock() }; _ascConfigState = newValue }
    }
    public var lastStatus: String { lock.lock(); defer { lock.unlock() }; return _lastStatus }
    public var lastMessage: String { lock.lock(); defer { lock.unlock() }; return _lastMessage }
    public var lastAction: String { lock.lock(); defer { lock.unlock() }; return _lastAction }
    public var lastBranch: String? { lock.lock(); defer { lock.unlock() }; return _lastBranch }
    public var lastCommit: String? { lock.lock(); defer { lock.unlock() }; return _lastCommit }
    public var isRunning: Bool { lock.lock(); let p = _process; lock.unlock(); return p?.isRunning ?? false }

    private let queue = DispatchQueue(label: "build-manager")
    private let buildBuffer = RingBuffer(capacity: 2 * 1024 * 1024)

    public init() {}

    public func buildReplayInfo() -> (data: Data, status: String, message: String, action: String, branch: String?, commit: String?) {
        lock.lock()
        let result = (buildBuffer.snapshot(), _lastStatus, _lastMessage, _lastAction, _lastBranch, _lastCommit)
        lock.unlock()
        return result
    }

    /// Discover all .xcworkspace and .xcodeproj in workDir (top-level + one level deep).
    public func listProjects(workDir: String) throws -> [[String: String]] {
        let fm = FileManager.default
        let contents = try fm.contentsOfDirectory(atPath: workDir)
        var results: [[String: String]] = []

        func scan(dir: String, items: [String]) {
            for item in items {
                if item.hasSuffix(".xcworkspace") {
                    let name = (item as NSString).deletingPathExtension
                    results.append(["name": name, "path": "\(dir)/\(item)", "type": "workspace"])
                } else if item.hasSuffix(".xcodeproj") {
                    let name = (item as NSString).deletingPathExtension
                    results.append(["name": name, "path": "\(dir)/\(item)", "type": "project"])
                }
            }
        }

        // Top-level
        scan(dir: workDir, items: contents)

        // One level deep
        for item in contents {
            let subPath = "\(workDir)/\(item)"
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: subPath, isDirectory: &isDir), isDir.boolValue else { continue }
            // Skip hidden dirs and build artifacts
            guard !item.hasPrefix("."), item != "build", item != "DerivedData" else { continue }
            guard let subContents = try? fm.contentsOfDirectory(atPath: subPath) else { continue }
            scan(dir: subPath, items: subContents)
        }

        return results
    }

    /// List schemes for a specific project/workspace path (e.g. "/path/to/Foo.xcodeproj").
    public func listSchemesForProject(projectPath: String) throws -> (schemes: [String], project: String) {
        let name = (URL(fileURLWithPath: projectPath).deletingPathExtension().lastPathComponent)
        let argFlag = projectPath.hasSuffix(".xcworkspace") ? "-workspace" : "-project"

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/xcodebuild")
        proc.arguments = ["-list", "-json", argFlag, projectPath]

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        proc.standardInput = FileHandle.nullDevice

        let start = CFAbsoluteTimeGetCurrent()
        let data = try Self.runWithTimeout(proc, pipe: pipe)
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        log("[build] xcodebuild -list (project) completed in \(String(format: "%.1f", elapsed))s")
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ([], name)
        }

        if let ws = json["workspace"] as? [String: Any],
           let schemes = ws["schemes"] as? [String] {
            return (schemes, name)
        }
        if let proj = json["project"] as? [String: Any],
           let schemes = proj["schemes"] as? [String] {
            return (schemes, name)
        }

        return ([], name)
    }

    public func listSchemes(workDir: String) throws -> (schemes: [String], project: String) {
        let (projectArg, projectName) = try detectProject(workDir: workDir)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/xcodebuild")
        proc.arguments = ["-list", "-json"] + projectArg
        proc.currentDirectoryURL = URL(fileURLWithPath: workDir)

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        proc.standardInput = FileHandle.nullDevice

        let start = CFAbsoluteTimeGetCurrent()
        let data = try Self.runWithTimeout(proc, pipe: pipe)
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        log("[build] xcodebuild -list completed in \(String(format: "%.1f", elapsed))s")
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ([], projectName)
        }

        // Try workspace first, then project
        if let ws = json["workspace"] as? [String: Any],
           let schemes = ws["schemes"] as? [String] {
            return (schemes, projectName)
        }
        if let proj = json["project"] as? [String: Any],
           let schemes = proj["schemes"] as? [String] {
            return (schemes, projectName)
        }

        return ([], projectName)
    }

    func resolvedASCCredentials() -> (keyId: String, issuerId: String, keyPath: String)? {
        guard case .configured(let config) = ascConfigState else { return nil }
        guard let keyId = config.keyId.nilIfEmpty, let issuerId = config.issuerId.nilIfEmpty else { return nil }
        let resolved = (config.keyPath.nilIfEmpty ?? "~/.private_keys/AuthKey_\(keyId).p8")
            .replacingOccurrences(of: "~", with: FileManager.default.homeDirectoryForCurrentUser.path)
        return (keyId, issuerId, resolved)
    }

    public func startBuild(scheme: String, action: String, configuration: String?, sdk: String?, teamId: String?, workDir: String) throws {
        guard !isRunning else {
            onStatusChange?("failed", "A build is already running", nil, nil)
            return
        }

        // Reset buffer and state for new build
        _ = buildBuffer.drain()
        lock.lock()
        _lastStatus = ""
        _lastMessage = ""
        _lastAction = action
        _lastBranch = nil
        _lastCommit = nil
        lock.unlock()

        let (projectArg, _) = try detectProject(workDir: workDir)
        var args: [String]

        switch action {
        case "build":
            args = ["build", "-scheme", scheme] + projectArg
            if let sdk = sdk {
                args += ["-sdk", sdk]
            }
        case "archive":
            guard let teamId = teamId, !teamId.isEmpty else {
                onStatusChange?("failed", "Team ID is required for archive", nil, nil)
                return
            }
            let archivePath = "\(workDir)/build/\(scheme).xcarchive"
            args = ["archive", "-scheme", scheme, "-archivePath", archivePath] + projectArg
            args += ["DEVELOPMENT_TEAM=\(teamId)", "CODE_SIGN_STYLE=Automatic", "-allowProvisioningUpdates"]
        case "exportUpload":
            guard let teamId = teamId, !teamId.isEmpty else {
                onStatusChange?("failed", "Team ID is required for export", nil, nil)
                return
            }

            guard let asc = resolvedASCCredentials() else {
                onStatusChange?("failed", "Missing ASC API Key configuration. Set them in the iOS app or via `termonmac asc set`.", nil, nil)
                return
            }

            let archivePath = "\(workDir)/build/\(scheme).xcarchive"
            let exportPath = "\(workDir)/build/export"
            let exportOptionsPlistPath = "\(workDir)/build/ExportOptions.plist"
            let plistContent = """
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>app-store-connect</string>
    <key>destination</key>
    <string>upload</string>
    <key>teamID</key>
    <string>\(teamId)</string>
    <key>uploadSymbols</key>
    <true/>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>signingCertificate</key>
    <string>Apple Distribution</string>
</dict>
</plist>
"""
            do {
                try plistContent.write(toFile: exportOptionsPlistPath, atomically: true, encoding: .utf8)
            } catch {
                onStatusChange?("failed", "Failed to write ExportOptions.plist: \(error.localizedDescription)", nil, nil)
                return
            }
            args = ["-exportArchive",
                    "-archivePath", archivePath,
                    "-exportPath", exportPath,
                    "-exportOptionsPlist", exportOptionsPlistPath,
                    "-allowProvisioningUpdates",
                    "-authenticationKeyPath", asc.keyPath,
                    "-authenticationKeyID", asc.keyId,
                    "-authenticationKeyIssuerID", asc.issuerId]
        default:
            onStatusChange?("failed", "Unknown action: \(action)", nil, nil)
            return
        }

        if let config = configuration {
            args += ["-configuration", config]
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/xcodebuild")
        proc.arguments = args
        proc.currentDirectoryURL = URL(fileURLWithPath: workDir)

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        proc.standardInput = FileHandle.nullDevice

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if !data.isEmpty {
                self?.buildBuffer.append(data)
                self?.onOutput?(data)
            }
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if !data.isEmpty {
                self?.buildBuffer.append(data)
                self?.onOutput?(data)
            }
        }

        let capturedWorkDir = workDir
        proc.terminationHandler = { [weak self] proc in
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            let status = proc.terminationStatus == 0 ? "succeeded" : "failed"
            let msg = proc.terminationStatus == 0 ? "Build succeeded" : "Build failed (exit \(proc.terminationStatus))"
            var gitBranch: String? = nil
            var gitCommit: String? = nil
            if proc.terminationStatus == 0 {
                gitBranch = Self.runGitCommand(["rev-parse", "--abbrev-ref", "HEAD"], workDir: capturedWorkDir)
                gitCommit = Self.runGitCommand(["rev-parse", "--short", "HEAD"], workDir: capturedWorkDir)
            }
            guard let self else { return }
            self.lock.lock()
            self._lastStatus = status
            self._lastMessage = msg
            self._lastBranch = gitBranch
            self._lastCommit = gitCommit
            let statusChange = self._onStatusChange
            self._process = nil
            self.lock.unlock()
            statusChange?(status, msg, gitBranch, gitCommit)
        }

        lock.lock()
        _process = proc
        _lastStatus = "running"
        _lastMessage = "Build started: \(action) \(scheme)"
        let statusChange = _onStatusChange
        lock.unlock()
        statusChange?("running", "Build started: \(action) \(scheme)", nil, nil)
        try proc.run()
    }

    public func getSigningInfo(scheme: String, workDir: String) throws -> (team: String, style: String, profile: String, cert: String, bundleId: String, ascKeyConfigured: Bool, ascKeyFileExists: Bool, archiveExists: Bool) {
        let (projectArg, _) = try detectProject(workDir: workDir)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/xcodebuild")
        proc.arguments = ["-showBuildSettings", "-scheme", scheme] + projectArg
        proc.currentDirectoryURL = URL(fileURLWithPath: workDir)

        let pipe = Pipe()
        proc.standardOutput = pipe
        let errPipe = Pipe()
        proc.standardError = errPipe
        proc.standardInput = FileHandle.nullDevice

        let start = CFAbsoluteTimeGetCurrent()
        let data = try Self.runWithTimeout(proc, pipe: pipe)
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        log("[build] xcodebuild -showBuildSettings completed in \(String(format: "%.1f", elapsed))s, exit=\(proc.terminationStatus)")
        if proc.terminationStatus != 0 {
            let stderrData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrStr = String(data: stderrData, encoding: .utf8) ?? ""
            log("[build] xcodebuild -showBuildSettings stderr: \(String(stderrStr.prefix(500)))")
        }
        let output = String(data: data, encoding: .utf8) ?? ""

        func extractSetting(_ key: String) -> String {
            for line in output.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("\(key) = ") {
                    return String(trimmed.dropFirst("\(key) = ".count))
                }
            }
            return ""
        }

        // Check ASC API Key via centralized resolver
        let ascCreds = resolvedASCCredentials()
        let ascKeyConfigured = ascCreds != nil
        let ascKeyFileExists = ascCreds.map { FileManager.default.fileExists(atPath: $0.keyPath) } ?? false

        // Check archive existence
        let archivePath = "\(workDir)/build/\(scheme).xcarchive"
        let archiveExists = FileManager.default.fileExists(atPath: archivePath)

        return (
            team: extractSetting("DEVELOPMENT_TEAM"),
            style: extractSetting("CODE_SIGN_STYLE"),
            profile: extractSetting("PROVISIONING_PROFILE_SPECIFIER"),
            cert: extractSetting("CODE_SIGN_IDENTITY"),
            bundleId: extractSetting("PRODUCT_BUNDLE_IDENTIFIER"),
            ascKeyConfigured: ascKeyConfigured,
            ascKeyFileExists: ascKeyFileExists,
            archiveExists: archiveExists
        )
    }

    /// Start a build using an explicit project path (bypasses detectProject).
    public func startBuildInProject(scheme: String, action: String, configuration: String?, sdk: String?, teamId: String?, projectPath: String) throws {
        guard !isRunning else {
            onStatusChange?("failed", "A build is already running", nil, nil)
            return
        }

        // Reset buffer and state for new build
        _ = buildBuffer.drain()
        lock.lock()
        _lastStatus = ""
        _lastMessage = ""
        _lastAction = action
        _lastBranch = nil
        _lastCommit = nil
        lock.unlock()

        let argFlag = projectPath.hasSuffix(".xcworkspace") ? "-workspace" : "-project"
        let projectArg = [argFlag, projectPath]
        // Derive workDir from project path (parent directory)
        let workDir = URL(fileURLWithPath: projectPath).deletingLastPathComponent().path

        var args: [String]

        switch action {
        case "build":
            args = ["build", "-scheme", scheme] + projectArg
            if let sdk = sdk {
                args += ["-sdk", sdk]
            }
        case "archive":
            guard let teamId = teamId, !teamId.isEmpty else {
                onStatusChange?("failed", "Team ID is required for archive", nil, nil)
                return
            }
            let archivePath = "\(workDir)/build/\(scheme).xcarchive"
            args = ["archive", "-scheme", scheme, "-archivePath", archivePath] + projectArg
            args += ["DEVELOPMENT_TEAM=\(teamId)", "CODE_SIGN_STYLE=Automatic", "-allowProvisioningUpdates"]
        case "exportUpload":
            guard let teamId = teamId, !teamId.isEmpty else {
                onStatusChange?("failed", "Team ID is required for export", nil, nil)
                return
            }

            guard let asc = resolvedASCCredentials() else {
                onStatusChange?("failed", "Missing ASC API Key configuration.", nil, nil)
                return
            }

            let archivePath = "\(workDir)/build/\(scheme).xcarchive"
            let exportPath = "\(workDir)/build/export"
            let exportOptionsPlistPath = "\(workDir)/build/ExportOptions.plist"
            let plistContent = """
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>app-store-connect</string>
    <key>destination</key>
    <string>upload</string>
    <key>teamID</key>
    <string>\(teamId)</string>
    <key>uploadSymbols</key>
    <true/>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>signingCertificate</key>
    <string>Apple Distribution</string>
</dict>
</plist>
"""
            do {
                try plistContent.write(toFile: exportOptionsPlistPath, atomically: true, encoding: .utf8)
            } catch {
                onStatusChange?("failed", "Failed to write ExportOptions.plist: \(error.localizedDescription)", nil, nil)
                return
            }
            args = ["-exportArchive",
                    "-archivePath", archivePath,
                    "-exportPath", exportPath,
                    "-exportOptionsPlist", exportOptionsPlistPath,
                    "-allowProvisioningUpdates",
                    "-authenticationKeyPath", asc.keyPath,
                    "-authenticationKeyID", asc.keyId,
                    "-authenticationKeyIssuerID", asc.issuerId]
        default:
            onStatusChange?("failed", "Unknown action: \(action)", nil, nil)
            return
        }

        if let config = configuration {
            args += ["-configuration", config]
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/xcodebuild")
        proc.arguments = args
        proc.currentDirectoryURL = URL(fileURLWithPath: workDir)

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        proc.standardInput = FileHandle.nullDevice

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if !data.isEmpty {
                self?.buildBuffer.append(data)
                self?.onOutput?(data)
            }
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if !data.isEmpty {
                self?.buildBuffer.append(data)
                self?.onOutput?(data)
            }
        }

        let capturedWorkDir = workDir
        proc.terminationHandler = { [weak self] proc in
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            let status = proc.terminationStatus == 0 ? "succeeded" : "failed"
            let msg = proc.terminationStatus == 0 ? "Build succeeded" : "Build failed (exit \(proc.terminationStatus))"
            var gitBranch: String? = nil
            var gitCommit: String? = nil
            if proc.terminationStatus == 0 {
                gitBranch = Self.runGitCommand(["rev-parse", "--abbrev-ref", "HEAD"], workDir: capturedWorkDir)
                gitCommit = Self.runGitCommand(["rev-parse", "--short", "HEAD"], workDir: capturedWorkDir)
            }
            guard let self else { return }
            self.lock.lock()
            self._lastStatus = status
            self._lastMessage = msg
            self._lastBranch = gitBranch
            self._lastCommit = gitCommit
            let statusChange = self._onStatusChange
            self._process = nil
            self.lock.unlock()
            statusChange?(status, msg, gitBranch, gitCommit)
        }

        lock.lock()
        _process = proc
        _lastStatus = "running"
        _lastMessage = "Build started: \(action) \(scheme)"
        let statusChange = _onStatusChange
        lock.unlock()
        statusChange?("running", "Build started: \(action) \(scheme)", nil, nil)
        try proc.run()
    }

    /// Get signing info for a specific project path.
    public func getSigningInfoForProject(scheme: String, projectPath: String) throws -> (team: String, style: String, profile: String, cert: String, bundleId: String, ascKeyConfigured: Bool, ascKeyFileExists: Bool, archiveExists: Bool) {
        let argFlag = projectPath.hasSuffix(".xcworkspace") ? "-workspace" : "-project"
        let workDir = URL(fileURLWithPath: projectPath).deletingLastPathComponent().path

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/xcodebuild")
        proc.arguments = ["-showBuildSettings", "-scheme", scheme, argFlag, projectPath]
        proc.currentDirectoryURL = URL(fileURLWithPath: workDir)

        let pipe = Pipe()
        proc.standardOutput = pipe
        let errPipe = Pipe()
        proc.standardError = errPipe
        proc.standardInput = FileHandle.nullDevice

        let start = CFAbsoluteTimeGetCurrent()
        let data = try Self.runWithTimeout(proc, pipe: pipe)
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        log("[build] xcodebuild -showBuildSettings (project) completed in \(String(format: "%.1f", elapsed))s, exit=\(proc.terminationStatus)")
        if proc.terminationStatus != 0 {
            let stderrData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrStr = String(data: stderrData, encoding: .utf8) ?? ""
            log("[build] xcodebuild -showBuildSettings (project) stderr: \(String(stderrStr.prefix(500)))")
        }
        let output = String(data: data, encoding: .utf8) ?? ""

        func extractSetting(_ key: String) -> String {
            for line in output.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("\(key) = ") {
                    return String(trimmed.dropFirst("\(key) = ".count))
                }
            }
            return ""
        }

        let ascCreds = resolvedASCCredentials()
        let ascKeyConfigured = ascCreds != nil
        let ascKeyFileExists = ascCreds.map { FileManager.default.fileExists(atPath: $0.keyPath) } ?? false

        let archivePath = "\(workDir)/build/\(scheme).xcarchive"
        let archiveExists = FileManager.default.fileExists(atPath: archivePath)

        return (
            team: extractSetting("DEVELOPMENT_TEAM"),
            style: extractSetting("CODE_SIGN_STYLE"),
            profile: extractSetting("PROVISIONING_PROFILE_SPECIFIER"),
            cert: extractSetting("CODE_SIGN_IDENTITY"),
            bundleId: extractSetting("PRODUCT_BUNDLE_IDENTIFIER"),
            ascKeyConfigured: ascKeyConfigured,
            ascKeyFileExists: ascKeyFileExists,
            archiveExists: archiveExists
        )
    }

    /// Runs a process with a timeout. Returns stdout data, or throws on timeout / non-zero exit.
    private static func runWithTimeout(_ proc: Process, pipe: Pipe, timeout: TimeInterval = 60) throws -> Data {
        let sema = DispatchSemaphore(value: 0)
        proc.terminationHandler = { _ in sema.signal() }
        try proc.run()
        let result = sema.wait(timeout: .now() + timeout)
        if result == .timedOut {
            proc.terminate()
            proc.waitUntilExit()
            throw NSError(domain: "BuildManager", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "xcodebuild timed out after \(Int(timeout))s"])
        }
        return pipe.fileHandleForReading.readDataToEndOfFile()
    }

    public func cancel() {
        lock.lock()
        guard let proc = _process, proc.isRunning else { lock.unlock(); return }
        _process = nil
        let statusChange = _onStatusChange
        lock.unlock()
        proc.terminate()
        statusChange?("cancelled", "Build cancelled", nil, nil)
    }

    // MARK: - Private

    private func detectProject(workDir: String) throws -> (args: [String], name: String) {
        let fm = FileManager.default
        let contents = try fm.contentsOfDirectory(atPath: workDir)

        // Search top-level first
        if let ws = contents.first(where: { $0.hasSuffix(".xcworkspace") }) {
            let name = (ws as NSString).deletingPathExtension
            return (["-workspace", "\(workDir)/\(ws)"], name)
        }
        if let proj = contents.first(where: { $0.hasSuffix(".xcodeproj") }) {
            let name = (proj as NSString).deletingPathExtension
            return (["-project", "\(workDir)/\(proj)"], name)
        }

        // Search one level deep (subdirectories)
        for item in contents {
            let subPath = "\(workDir)/\(item)"
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: subPath, isDirectory: &isDir), isDir.boolValue else { continue }
            guard let subContents = try? fm.contentsOfDirectory(atPath: subPath) else { continue }
            if let ws = subContents.first(where: { $0.hasSuffix(".xcworkspace") }) {
                let name = (ws as NSString).deletingPathExtension
                return (["-workspace", "\(subPath)/\(ws)"], name)
            }
            if let proj = subContents.first(where: { $0.hasSuffix(".xcodeproj") }) {
                let name = (proj as NSString).deletingPathExtension
                return (["-project", "\(subPath)/\(proj)"], name)
            }
        }

        throw NSError(domain: "BuildManager", code: 1,
                       userInfo: [NSLocalizedDescriptionKey: "No .xcworkspace or .xcodeproj found in \(workDir)"])
    }

    private static func runGitCommand(_ args: [String], workDir: String) -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        proc.arguments = args
        proc.currentDirectoryURL = URL(fileURLWithPath: workDir)
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        proc.standardInput = FileHandle.nullDevice
        try? proc.run()
        proc.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
#endif
