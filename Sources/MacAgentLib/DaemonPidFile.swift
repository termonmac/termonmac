import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Locates and validates the running daemon via a two-factor `daemon.pid` file
/// containing `<pid>\n<start_timestamp_unix_seconds>\n`. The start timestamp
/// defends against PID-reuse: a stale pid file for a pid now belonging to an
/// unrelated process will not match, and the CLI refuses to send SIGHUP.
public struct DaemonPidInfo: Equatable, Sendable {
    public let pid: pid_t
    public let startTimestamp: Int
}

public enum DaemonPidLookup: Equatable, Sendable {
    /// No pid file on disk.
    case noPidFile
    /// File is malformed (parse error, missing line).
    case malformed(String)
    /// File exists but the pid is no longer running.
    case pidNotAlive(pid_t)
    /// File exists, pid is alive, but the observed start timestamp disagrees
    /// beyond tolerance — treat as a stale pid file pointing at an unrelated
    /// process. Do not send signals.
    case staleStartTimestamp(expected: Int, observed: Int, pid: pid_t)
    /// File matches a live, genuine termonmac daemon.
    case ok(DaemonPidInfo)
}

public enum DaemonPidFile {
    public static let fileName = "daemon.pid"
    /// ±2s slack between when we record start time and the kernel's own value.
    public static let clockSlackSeconds = 2

    public static func path(in configDir: String) -> String {
        configDir + "/" + fileName
    }

    /// Write the current process' pid + start timestamp to `daemon.pid`.
    /// Called by the daemon at startup.
    public static func writeSelf(configDir: String) throws {
        let pid = getpid()
        let startTs: Int
        if let observed = currentProcessStartTimestamp() {
            startTs = observed
        } else {
            startTs = Int(Date().timeIntervalSince1970)
        }
        let content = "\(pid)\n\(startTs)\n"
        let tmpPath = path(in: configDir) + ".tmp.\(pid)"
        let fm = FileManager.default
        try? fm.removeItem(atPath: tmpPath)
        if !fm.createFile(
            atPath: tmpPath,
            contents: Data(content.utf8),
            attributes: [.posixPermissions: 0o600]
        ) {
            throw NSError(domain: "DaemonPidFile", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "tempfile create failed"])
        }
        if Darwin.rename(tmpPath, path(in: configDir)) != 0 {
            let code = errno
            try? fm.removeItem(atPath: tmpPath)
            throw NSError(domain: "DaemonPidFile", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "rename failed errno=\(code)"])
        }
    }

    /// Resolve the daemon.pid file, validating both liveness and start
    /// timestamp. Returns `.ok` only when the CLI should actually send SIGHUP.
    public static func lookup(
        configDir: String,
        startTimestampProvider: (pid_t) -> Int? = DaemonPidFile.processStartTimestamp(pid:),
        isAlive: (pid_t) -> Bool = DaemonPidFile.isPidAlive(_:)
    ) -> DaemonPidLookup {
        let p = path(in: configDir)
        guard let data = FileManager.default.contents(atPath: p),
              let content = String(data: data, encoding: .utf8) else {
            return .noPidFile
        }
        let lines = content.split(separator: "\n", omittingEmptySubsequences: true)
        guard lines.count >= 2,
              let pid = pid_t(lines[0].trimmingCharacters(in: .whitespaces)),
              let ts = Int(lines[1].trimmingCharacters(in: .whitespaces)) else {
            return .malformed(content)
        }
        guard isAlive(pid) else {
            return .pidNotAlive(pid)
        }
        if let observed = startTimestampProvider(pid) {
            if abs(observed - ts) > clockSlackSeconds {
                return .staleStartTimestamp(expected: ts, observed: observed, pid: pid)
            }
        }
        return .ok(DaemonPidInfo(pid: pid, startTimestamp: ts))
    }

    /// Send SIGHUP to the recorded daemon, validating pid + start timestamp
    /// before issuing the signal. Returns true if the signal was sent.
    @discardableResult
    public static func signalDaemon(
        configDir: String,
        startTimestampProvider: (pid_t) -> Int? = DaemonPidFile.processStartTimestamp(pid:),
        isAlive: (pid_t) -> Bool = DaemonPidFile.isPidAlive(_:),
        kill: (pid_t, Int32) -> Int32 = { Darwin.kill($0, $1) }
    ) -> DaemonPidLookup {
        let result = lookup(configDir: configDir,
                            startTimestampProvider: startTimestampProvider,
                            isAlive: isAlive)
        if case .ok(let info) = result {
            _ = kill(info.pid, SIGHUP)
        }
        return result
    }

    // MARK: - Liveness + start-time probes

    /// Returns true if the pid currently corresponds to a running process
    /// owned by the current user (kill(pid, 0) == 0 or EPERM).
    public static func isPidAlive(_ pid: pid_t) -> Bool {
        if pid <= 0 { return false }
        if Darwin.kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    /// Start timestamp (unix seconds) for the given pid, via `sysctl`.
    public static func processStartTimestamp(pid: pid_t) -> Int? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var size = MemoryLayout<kinfo_proc>.size
        var info = kinfo_proc()
        let result = withUnsafeMutablePointer(to: &info) { infoPtr in
            mib.withUnsafeMutableBufferPointer { mibBuf in
                sysctl(mibBuf.baseAddress, UInt32(mibBuf.count),
                       infoPtr, &size, nil, 0)
            }
        }
        if result != 0 || size == 0 {
            return nil
        }
        let tv = info.kp_proc.p_starttime
        return Int(tv.tv_sec)
    }

    private static func currentProcessStartTimestamp() -> Int? {
        processStartTimestamp(pid: getpid())
    }
}
