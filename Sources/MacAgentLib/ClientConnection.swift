import Foundation

#if os(macOS)

/// Thread-safe wrapper for a client socket fd.
///
/// Provides mutual exclusion between write and close operations,
/// preventing fd-reuse races and double-close bugs. Used by both
/// HelperServer and LocalSocketServer for per-client fd management.
public final class ClientConnection {
    public let fd: Int32
    private let lock = NSLock()
    private var closed = false

    public init(fd: Int32) {
        self.fd = fd
        // Prevent blocking write from holding the lock forever (5s timeout).
        // After timeout, write() returns -1 with errno EAGAIN.
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        // Prevent SIGPIPE from killing the process when writing to a disconnected socket.
        // The agent service process does not have a global SIG_IGN for SIGPIPE
        // (only the pty-helper process does), so per-socket protection is needed.
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    /// Execute a write operation under this connection's lock.
    ///
    /// Returns `nil` if the connection is already closed.
    /// Supports compound atomic operations (e.g. writeFrame + c_sendfd).
    ///
    /// Usage:
    /// ```
    /// conn.safeWrite { fd in try IPCFraming.writeFrame(response, to: fd) }
    /// ```
    public func safeWrite<T>(_ action: (Int32) throws -> T) rethrows -> T? {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return nil }
        return try action(fd)
    }

    /// Idempotent close — only the first caller actually closes the fd.
    /// Calls shutdown(SHUT_RDWR) first to unblock any concurrent read().
    public func closeOnce() {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        closed = true
        lock.unlock()
        Darwin.shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
    }
}

#endif
