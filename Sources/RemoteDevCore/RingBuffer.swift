import Foundation

/// Thread-safe ring buffer for PTY output replay.
/// Stores up to `capacity` bytes, overwriting oldest data when full.
public final class RingBuffer {
    private let capacity: Int
    private var storage: Data
    private let lock = NSLock()
    private var didOverflow = false
    private var totalBytesWritten: UInt64 = 0

    public init(capacity: Int = 256 * 1024) {
        self.capacity = capacity
        self.storage = Data()
    }

    /// Monotonically increasing count of all bytes ever appended.
    public var currentOffset: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return totalBytesWritten
    }

    /// Append data to the buffer. If total exceeds capacity, oldest data is dropped.
    public func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        totalBytesWritten += UInt64(data.count)
        storage.append(data)
        if storage.count > capacity {
            storage = storage.suffix(capacity)
            // Scan forward to first newline so replay starts at a clean line boundary,
            // avoiding mid-line or mid-escape-sequence truncation.
            if let nlIndex = storage.firstIndex(of: 0x0A) {
                storage = storage.suffix(from: storage.index(after: nlIndex))
            }
            didOverflow = true
        }
    }

    /// Return all buffered data without clearing the buffer.
    public func snapshot() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    /// Return data written since `offset`. If the offset is too old (data overwritten),
    /// returns the full buffer with `isFull: true` so the caller can do a terminal reset.
    public func snapshotSince(_ offset: UInt64) -> (data: Data, currentOffset: UInt64, isFull: Bool) {
        lock.lock()
        defer { lock.unlock() }

        let current = totalBytesWritten
        if offset >= current {
            return (Data(), current, false)
        }

        let bytesNeeded = current - offset
        if bytesNeeded > UInt64(storage.count) {
            // Gap exceeds buffer — some data was overwritten. Full replay needed.
            var result = storage
            if didOverflow {
                let sgrReset = Data([0x1B, 0x5B, 0x30, 0x6D]) // ESC[0m
                result = sgrReset + result
            }
            return (result, current, true)
        }

        // Incremental: return only the tail
        let tailLength = Int(bytesNeeded)
        let data = storage.suffix(tailLength)
        return (Data(data), current, false)
    }

    /// Drain all buffered data in chronological order and clear the buffer.
    /// If overflow occurred, prepends ESC[0m to reset text attributes.
    public func drain() -> Data {
        lock.lock()
        defer { lock.unlock() }
        var result = storage
        if didOverflow {
            let sgrReset = Data([0x1B, 0x5B, 0x30, 0x6D]) // ESC[0m
            result = sgrReset + result
        }
        storage = Data()
        didOverflow = false
        return result
    }
}
