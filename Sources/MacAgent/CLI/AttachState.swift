import Foundation

#if os(macOS)

/// Thread-safe shared state for an attach session.
///
/// Accessed from multiple threads during attach:
/// - **stdin thread**: writes `showStatusBar`, `sessionName`
/// - **output thread**: reads `showStatusBar`, `sessionName`
/// - **main queue (SIGWINCH)**: reads `showStatusBar`, `sessionName`
///
/// `String` is 16 bytes on 64-bit — not hardware-atomic — so unsynchronized
/// read/write of `sessionName` can produce a torn read (crash).
/// NSLock protects all fields; contention is negligible because mutations
/// (rename, toggle) are rare human-initiated events.
final class AttachState {
    private let lock = NSLock()
    private var _showStatusBar: Bool
    private var _sessionName: String

    init(showStatusBar: Bool, sessionName: String) {
        self._showStatusBar = showStatusBar
        self._sessionName = sessionName
    }

    var showStatusBar: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _showStatusBar }
        set { lock.lock(); _showStatusBar = newValue; lock.unlock() }
    }

    var sessionName: String {
        get { lock.lock(); defer { lock.unlock() }; return _sessionName }
        set { lock.lock(); _sessionName = newValue; lock.unlock() }
    }
}

#endif
