import Foundation
import RemoteDevCore

#if os(macOS)
final class GitManager: Sendable {

    // MARK: - Git Detection

    func detectGitRepo(at workDir: String) -> GitDetectInfo {
        let isInsideResult = runGit(args: ["rev-parse", "--is-inside-work-tree"], workDir: workDir)
        guard isInsideResult.exitCode == 0,
              isInsideResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "true" else {
            return GitDetectInfo(isGitRepo: false, isWorktree: false, branchName: nil, remoteUrl: nil, repoRootPath: nil)
        }

        let toplevelResult = runGit(args: ["rev-parse", "--show-toplevel"], workDir: workDir)
        let repoRoot = toplevelResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)

        let branchResult = runGit(args: ["rev-parse", "--abbrev-ref", "HEAD"], workDir: workDir)
        let branch = branchResult.exitCode == 0
            ? branchResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            : nil

        let remoteResult = runGit(args: ["remote", "get-url", "origin"], workDir: workDir)
        let remote = remoteResult.exitCode == 0
            ? remoteResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            : nil

        // Detect worktree: .git is a file (not directory) in a worktree
        let gitPath = repoRoot + "/.git"
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: gitPath, isDirectory: &isDir)
        let isWorktree = exists && !isDir.boolValue

        return GitDetectInfo(isGitRepo: true, isWorktree: isWorktree,
                             branchName: branch, remoteUrl: remote,
                             repoRootPath: repoRoot.isEmpty ? nil : repoRoot)
    }

    // MARK: - Worktree Parent Resolution

    struct WorktreeParentInfo {
        let parentRepoPath: String
        let parentBranchName: String
    }

    /// Given a worktree directory, resolve its main repository path and branch.
    func resolveWorktreeParent(worktreePath: String) -> WorktreeParentInfo? {
        // --git-common-dir returns the shared .git directory (e.g. /path/to/main-repo/.git)
        let commonDirResult = runGit(args: ["rev-parse", "--git-common-dir"], workDir: worktreePath)
        guard commonDirResult.exitCode == 0 else { return nil }
        var commonDir = commonDirResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        // Resolve relative path (git may return relative to worktree)
        if !commonDir.hasPrefix("/") {
            commonDir = (worktreePath as NSString).appendingPathComponent(commonDir)
        }
        // Standardize (resolve ../ etc)
        commonDir = (commonDir as NSString).standardizingPath
        // Strip trailing /.git to get repo root
        let parentRepoPath: String
        if commonDir.hasSuffix("/.git") {
            parentRepoPath = String(commonDir.dropLast(5))
        } else {
            parentRepoPath = commonDir
        }
        // Get the main branch of the parent repo
        let branchResult = runGit(args: ["rev-parse", "--abbrev-ref", "HEAD"], workDir: parentRepoPath)
        let parentBranch = branchResult.exitCode == 0
            ? branchResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            : "main"
        return WorktreeParentInfo(parentRepoPath: parentRepoPath, parentBranchName: parentBranch)
    }

    // MARK: - Worktree Create

    struct WorktreeCreateResult {
        let success: Bool
        let path: String?
        let branchName: String?
        let error: String?
    }

    func createWorktree(repoPath: String, name: String, dirLayout: WorktreeDirLayout = .grouped) -> WorktreeCreateResult {
        let sanitizedName = GitNameSanitizer.sanitize(name)
        guard !sanitizedName.isEmpty else {
            return WorktreeCreateResult(success: false, path: nil, branchName: nil, error: "Invalid worktree name")
        }

        let parentDir = (repoPath as NSString).deletingLastPathComponent
        let repoName = (repoPath as NSString).lastPathComponent
        let wtBaseDir: String
        switch dirLayout {
        case .grouped:
            wtBaseDir = parentDir + "/TermOnMac-wt/" + repoName
        case .sibling:
            wtBaseDir = parentDir + "/" + repoName + "-wt"
        case .flat:
            wtBaseDir = parentDir
        }
        if dirLayout != .flat {
            try? FileManager.default.createDirectory(atPath: wtBaseDir, withIntermediateDirectories: true)
        }
        var targetDir = wtBaseDir + "/" + sanitizedName

        // If directory already exists, add hash suffix
        if FileManager.default.fileExists(atPath: targetDir) {
            let hash = String(UUID().uuidString.prefix(6)).lowercased()
            targetDir = wtBaseDir + "/" + sanitizedName + "-" + hash
        }

        // Pre-check: ensure branch name won't collide (exists or checked out in another worktree)
        var branchName = sanitizedName
        if isBranchTaken(branchName, repoPath: repoPath) {
            let hash = String(UUID().uuidString.prefix(6)).lowercased()
            branchName = sanitizedName + "-" + hash
        }

        let result = runGit(args: ["worktree", "add", targetDir, "-b", branchName], workDir: repoPath)
        if result.exitCode == 0 {
            return WorktreeCreateResult(success: true, path: targetDir, branchName: branchName, error: nil)
        } else {
            let errMsg = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return WorktreeCreateResult(success: false, path: nil, branchName: nil, error: errMsg.isEmpty ? "git worktree add failed" : errMsg)
        }
    }

    /// Check if a branch name already exists as a ref or is checked out in another worktree.
    private func isBranchTaken(_ branch: String, repoPath: String) -> Bool {
        // 1. Check if branch ref exists
        let refResult = runGit(args: ["rev-parse", "--verify", "--quiet", "refs/heads/\(branch)"], workDir: repoPath)
        if refResult.exitCode == 0 {
            return true
        }
        // 2. Check if branch is checked out in any worktree (covers detached HEAD edge cases)
        let listResult = runGit(args: ["worktree", "list", "--porcelain"], workDir: repoPath)
        if listResult.exitCode == 0 {
            for line in listResult.stdout.components(separatedBy: "\n") {
                if line == "branch refs/heads/\(branch)" {
                    return true
                }
            }
        }
        return false
    }

    // MARK: - Worktree Remove

    func removeWorktree(repoPath: String, worktreePath: String) -> GitOperationResult {
        let result = runGit(args: ["worktree", "remove", worktreePath, "--force"], workDir: repoPath)
        if result.exitCode == 0 {
            return GitOperationResult(success: true, message: "Worktree removed", sessionId: "")
        } else {
            let errMsg = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return GitOperationResult(success: false, message: errMsg.isEmpty ? "Failed to remove worktree" : errMsg, sessionId: "")
        }
    }

    // MARK: - Merge

    func mergeBranch(repoPath: String, branchName: String, ffOnly: Bool = false) -> GitOperationResult {
        var args = ["merge"]
        if ffOnly { args.append("--ff-only") }
        args.append(branchName)
        let result = runGit(args: args, workDir: repoPath)
        if result.exitCode == 0 {
            return GitOperationResult(success: true, message: "Merged \(branchName) successfully", sessionId: "")
        } else {
            // Abort the failed merge
            _ = runGit(args: ["merge", "--abort"], workDir: repoPath)
            let errMsg = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return GitOperationResult(success: false, message: errMsg.isEmpty ? "Merge failed" : errMsg, sessionId: "")
        }
    }

    // MARK: - Rebase

    func rebaseOnto(worktreePath: String, targetBranch: String) -> GitOperationResult {
        let result = runGit(args: ["rebase", targetBranch], workDir: worktreePath)
        if result.exitCode == 0 {
            return GitOperationResult(success: true, message: "Rebased onto \(targetBranch) successfully", sessionId: "")
        } else {
            _ = runGit(args: ["rebase", "--abort"], workDir: worktreePath)
            let errMsg = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return GitOperationResult(success: false, message: errMsg.isEmpty ? "Rebase failed" : errMsg, sessionId: "")
        }
    }

    // MARK: - Sync Status

    func checkSyncStatus(worktreePath: String, parentRepoPath: String,
                         parentBranch: String, worktreeBranch: String) -> WorktreeSyncInfo {
        // Fetch to make sure we have latest refs
        _ = runGit(args: ["fetch", "--quiet"], workDir: parentRepoPath)

        let mergeBaseResult = runGit(args: ["merge-base", parentBranch, worktreeBranch], workDir: parentRepoPath)
        guard mergeBaseResult.exitCode == 0 else {
            return WorktreeSyncInfo(sessionId: "", isSynced: true, behindCount: 0, aheadCount: 0)
        }

        let behindResult = runGit(args: ["rev-list", "--count", "\(worktreeBranch)..\(parentBranch)"], workDir: parentRepoPath)
        let aheadResult = runGit(args: ["rev-list", "--count", "\(parentBranch)..\(worktreeBranch)"], workDir: parentRepoPath)

        let behind = Int(behindResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        let ahead = Int(aheadResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0

        return WorktreeSyncInfo(sessionId: "", isSynced: behind == 0 && ahead == 0,
                                behindCount: behind, aheadCount: ahead)
    }

    // MARK: - Dirty State Check

    func checkDirtyState(worktreePath: String, parentRepoPath: String,
                         parentBranch: String, worktreeBranch: String,
                         sessionId: String) -> WorktreeDirtyState {
        let failed = { (detail: String) -> WorktreeDirtyState in
            log("[git] checkDirtyState failed: \(detail)")
            return WorktreeDirtyState(sessionId: sessionId, hasUnstagedChanges: false,
                                       hasStagedChanges: false, hasUntrackedFiles: false,
                                       isSynced: false, behindCount: 0, aheadCount: 0,
                                       summary: "Unable to determine worktree state: \(detail)",
                                       checkFailed: true)
        }

        guard !worktreePath.isEmpty else {
            return failed("worktree path is empty")
        }

        // Unstaged changes
        let unstagedResult = runGit(args: ["diff", "--shortstat"], workDir: worktreePath)
        guard unstagedResult.exitCode == 0 else {
            return failed("git diff failed — \(unstagedResult.stderr)")
        }
        let hasUnstaged = !unstagedResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        // Staged changes
        let stagedResult = runGit(args: ["diff", "--cached", "--shortstat"], workDir: worktreePath)
        guard stagedResult.exitCode == 0 else {
            return failed("git diff --cached failed — \(stagedResult.stderr)")
        }
        let hasStaged = !stagedResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        // Untracked files
        let untrackedResult = runGit(args: ["ls-files", "--others", "--exclude-standard"], workDir: worktreePath)
        guard untrackedResult.exitCode == 0 else {
            return failed("git ls-files failed — \(untrackedResult.stderr)")
        }
        let hasUntracked = !untrackedResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        // Ahead/behind using local refs only (no fetch — avoids network hang)
        let mergeBaseResult = runGit(args: ["merge-base", parentBranch, worktreeBranch], workDir: parentRepoPath)
        guard mergeBaseResult.exitCode == 0 else {
            return failed("git merge-base failed — \(mergeBaseResult.stderr)")
        }
        let aheadResult = runGit(args: ["rev-list", "--count", "\(parentBranch)..\(worktreeBranch)"], workDir: parentRepoPath)
        let behindResult = runGit(args: ["rev-list", "--count", "\(worktreeBranch)..\(parentBranch)"], workDir: parentRepoPath)
        guard aheadResult.exitCode == 0, behindResult.exitCode == 0 else {
            return failed("git rev-list failed — \(aheadResult.stderr)\(behindResult.stderr)")
        }
        let aheadCount = Int(aheadResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        let behindCount = Int(behindResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        let isSynced = aheadCount == 0 && behindCount == 0

        // Build summary
        var parts: [String] = []
        if hasUnstaged { parts.append("unstaged changes") }
        if hasStaged { parts.append("staged changes") }
        if hasUntracked { parts.append("untracked files") }
        if aheadCount > 0 { parts.append("\(aheadCount) commit(s) ahead") }
        if behindCount > 0 { parts.append("\(behindCount) commit(s) behind") }
        let summary = parts.isEmpty ? "Clean" : parts.joined(separator: ", ")

        return WorktreeDirtyState(sessionId: sessionId, hasUnstagedChanges: hasUnstaged,
                                   hasStagedChanges: hasStaged, hasUntrackedFiles: hasUntracked,
                                   isSynced: isSynced, behindCount: behindCount,
                                   aheadCount: aheadCount, summary: summary)
    }

    // MARK: - Private Helper

    private struct GitResult {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    private static let gitTimeout: TimeInterval = 30

    private func runGit(args: [String], workDir: String) -> GitResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: workDir)

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            return GitResult(exitCode: -1, stdout: "", stderr: error.localizedDescription)
        }

        // Use terminationHandler instead of waitUntilExit to avoid permanently
        // leaking a GCD thread. waitUntilExit uses CFRunLoop internally, which
        // can hang forever on GCD threads even after the process has exited.
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }

        if done.wait(timeout: .now() + Self.gitTimeout) == .timedOut {
            process.terminate()
            // Give 1s for graceful exit, then force kill to ensure cleanup
            if done.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
            }
            log("[git] WARNING: git \(args.first ?? "") timed out after \(Int(Self.gitTimeout))s")
            return GitResult(exitCode: -1, stdout: "", stderr: "git command timed out")
        }

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        return GitResult(
            exitCode: process.terminationStatus,
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? ""
        )
    }
}
#endif
