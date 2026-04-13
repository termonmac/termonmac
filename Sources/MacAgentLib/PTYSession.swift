import Foundation
import Darwin
#if os(macOS)
import CPosixHelpers

final class PTYSession {
    private var masterFD: Int32 = -1
    private var childPID: pid_t = 0
    /// PTY slave device path (e.g. /dev/ttys003). Used to detect nested attach.
    private(set) var slavePath: String?
    private var dispatchSource: DispatchSourceRead?
    private var outputBuffer = Data()
    private var flushTimer: DispatchSourceTimer?
    private let outputQueue = DispatchQueue(label: "pty.output")
    var onOutput: ((Data) -> Void)?
    var onExit: (() -> Void)?

    /// Thread-safe setter for onOutput — serializes with flushOutput on outputQueue.
    func setOnOutput(_ handler: ((Data) -> Void)?) {
        outputQueue.async { [weak self] in
            self?.onOutput = handler
        }
    }

    func start(command: String = "/bin/zsh", workDir: String? = nil, rows: UInt16 = 24, cols: UInt16 = 80, sessionId: String? = nil) throws {
        var masterFD: Int32 = 0
        var ws = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)

        let pid = c_forkpty(&masterFD, &ws)
        guard pid >= 0 else {
            throw PTYError.forkFailed
        }

        if pid == 0 {
            // Child process
            setenv("TERM", "xterm-256color", 1)
            setenv("LANG", "en_US.UTF-8", 1)
            setenv("SHELL_SESSIONS_DISABLE", "1", 1)
            if let sid = sessionId { setenv("TERMONMAC_SESSION", sid, 1) }
            if let dir = workDir {
                chdir(dir)
            }
            let cmd = command.withCString { strdup($0)! }
            // Use "-shell" as argv[0] to start a login shell, matching Terminal.app behavior.
            // This ensures /etc/zprofile (path_helper) and ~/.zprofile are sourced,
            // so PATH includes Homebrew and other user-configured paths.
            let shellName = (command as NSString).lastPathComponent
            let loginArg = "-\(shellName)".withCString { strdup($0)! }
            let args: [UnsafeMutablePointer<CChar>?] = [loginArg, nil]
            execvp(cmd, args)
            _exit(1)
        }

        // Parent process
        self.masterFD = masterFD
        self.childPID = pid
        if let name = ptsname(masterFD) { self.slavePath = String(cString: name) }

        let flags = fcntl(masterFD, F_GETFL)
        _ = fcntl(masterFD, F_SETFL, flags | O_NONBLOCK)

        let source = DispatchSource.makeReadSource(fileDescriptor: masterFD, queue: .global(qos: .userInteractive))
        source.setEventHandler { [weak self] in
            guard let self, self.masterFD >= 0 else { return }
            var buf = [UInt8](repeating: 0, count: 8192)
            let n = read(self.masterFD, &buf, buf.count)
            if n > 0 {
                self.outputQueue.async {
                    self.outputBuffer.append(Data(buf[0..<n]))
                    if self.outputBuffer.count >= 32768 {
                        self.flushOutput()
                    } else if self.flushTimer == nil {
                        let timer = DispatchSource.makeTimerSource(queue: self.outputQueue)
                        timer.schedule(deadline: .now() + .milliseconds(200))
                        timer.setEventHandler { [weak self] in
                            self?.flushOutput()
                        }
                        timer.resume()
                        self.flushTimer = timer
                    }
                }
            } else if n == 0 || (n < 0 && errno != EAGAIN && errno != EINTR) {
                source.cancel()
            }
        }
        source.setCancelHandler { [weak self] in
            self?.stop()
            self?.onExit?()
        }
        source.resume()
        self.dispatchSource = source
    }

    func write(_ data: Data) {
        guard masterFD >= 0 else { return }
        data.withUnsafeBytes { buf in
            var totalWritten = 0
            while totalWritten < buf.count {
                let ptr = buf.baseAddress!.advanced(by: totalWritten)
                let remaining = buf.count - totalWritten
                let n = Darwin.write(masterFD, ptr, remaining)
                if n > 0 {
                    totalWritten += n
                } else if n < 0 {
                    if errno == EAGAIN || errno == EINTR {
                        usleep(1000)  // 1ms backoff
                        continue
                    }
                    break  // real error
                } else {
                    break  // EOF
                }
            }
        }
    }

    func resize(cols: UInt16, rows: UInt16) {
        guard masterFD >= 0 else { return }
        var ws = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(masterFD, TIOCSWINSZ, &ws)
    }

    // MARK: - fd passing support

    /// The PTY master file descriptor. Used for fd passing to CLI.
    var ptyMasterFD: Int32 { masterFD }

    private var outputSuspended = false

    /// Suspend DispatchSource.read — called before passing master fd to CLI.
    /// Flushes pending output before suspending.
    func suspendOutput() {
        guard !outputSuspended else { return }
        outputQueue.sync {
            flushOutput()
        }
        dispatchSource?.suspend()
        outputSuspended = true
    }

    /// Resume DispatchSource.read — called after CLI returns the master fd.
    func resumeOutput() {
        guard outputSuspended else { return }
        outputSuspended = false
        dispatchSource?.resume()
    }

    /// Accept tee data from CLI and deliver it through the normal onOutput path.
    /// Bypasses the 200ms timer and TerminalQueryInterceptor — the CLI already
    /// read this data directly from the PTY fd and displayed it. We only need it
    /// for scrollback buffering. Re-intercepting would send duplicate query responses.
    func appendTeeOutput(_ data: Data) {
        outputQueue.async { [weak self] in
            guard let self, !data.isEmpty else { return }
            self.onOutput?(data)
        }
    }

    private func flushOutput() {
        flushTimer?.cancel()
        flushTimer = nil
        guard !outputBuffer.isEmpty else { return }

        let result = TerminalQueryInterceptor.intercept(outputBuffer)
        outputBuffer = Data()

        // Write local responses to PTY (zero-latency reply to shell queries).
        // Must dispatch off outputQueue to avoid blocking the flush path.
        if !result.responses.isEmpty {
            let fd = self.masterFD
            DispatchQueue.global(qos: .userInteractive).async {
                for resp in result.responses {
                    resp.withUnsafeBytes { buf in
                        guard let ptr = buf.baseAddress else { return }
                        _ = Darwin.write(fd, ptr, buf.count)
                    }
                }
            }
        }

        guard !result.filteredOutput.isEmpty else { return }
        onOutput?(result.filteredOutput)
    }

    func stop() {
        outputQueue.sync {
            flushOutput()
        }
        onOutput = nil
        dispatchSource?.cancel()
        dispatchSource = nil
        if childPID > 0 {
            let pid = childPID
            childPID = 0

            // Send SIGHUP first
            kill(pid, SIGHUP)

            // Non-blocking check
            var status: Int32 = 0
            if waitpid(pid, &status, WNOHANG) == 0 {
                // Still alive — force kill
                kill(pid, SIGKILL)
                if waitpid(pid, &status, WNOHANG) == 0 {
                    // Still not reaped — reap in background to avoid zombie
                    DispatchQueue.global().async {
                        var s: Int32 = 0
                        waitpid(pid, &s, 0)
                    }
                }
            }
        }
        if masterFD >= 0 {
            close(masterFD)
            masterFD = -1
        }
    }

    deinit {
        stop()
    }

    enum PTYError: Error {
        case forkFailed
    }
}
#endif
