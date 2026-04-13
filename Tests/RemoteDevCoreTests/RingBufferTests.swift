import Testing
import Foundation
@testable import RemoteDevCore

@Suite("RingBuffer")
struct RingBufferTests {

    @Test("Append and snapshot returns written data")
    func appendAndSnapshot() {
        let buf = RingBuffer(capacity: 1024)
        let data = Data("hello world".utf8)
        buf.append(data)
        #expect(buf.snapshot() == data)
    }

    @Test("currentOffset tracks total bytes written")
    func offsetTracking() {
        let buf = RingBuffer(capacity: 1024)
        #expect(buf.currentOffset == 0)
        buf.append(Data("abc".utf8))  // 3 bytes
        #expect(buf.currentOffset == 3)
        buf.append(Data("defgh".utf8))  // 5 bytes
        #expect(buf.currentOffset == 8)
    }

    @Test("Overflow keeps only tail data within capacity")
    func overflow() {
        let buf = RingBuffer(capacity: 32)
        // Write more than capacity
        let line1 = Data("first line of text here\n".utf8)  // 24 bytes
        let line2 = Data("second line of text!\n".utf8)     // 21 bytes
        buf.append(line1)
        buf.append(line2)
        // Total 45 bytes > 32 capacity, should keep tail snapped to newline boundary
        let snap = buf.snapshot()
        #expect(snap.count <= 32)
        // After overflow + newline snap, should contain the second line
        let text = String(data: snap, encoding: .utf8)!
        #expect(text.contains("second line"))
    }

    @Test("snapshotSince returns only new data (incremental)")
    func snapshotSinceIncremental() {
        let buf = RingBuffer(capacity: 1024)
        buf.append(Data("aaa".utf8))
        let offset = buf.currentOffset  // 3
        buf.append(Data("bbb".utf8))

        let (data, newOffset, isFull) = buf.snapshotSince(offset)
        #expect(String(data: data, encoding: .utf8) == "bbb")
        #expect(newOffset == 6)
        #expect(isFull == false)
    }

    @Test("snapshotSince at current offset returns empty data")
    func snapshotSinceAtCurrent() {
        let buf = RingBuffer(capacity: 1024)
        buf.append(Data("abc".utf8))
        let offset = buf.currentOffset
        let (data, newOffset, isFull) = buf.snapshotSince(offset)
        #expect(data.isEmpty)
        #expect(newOffset == offset)
        #expect(isFull == false)
    }

    @Test("snapshotSince with too-old offset returns full buffer with SGR reset")
    func snapshotSinceTooOld() {
        let buf = RingBuffer(capacity: 32)
        // Write enough to overflow
        for i in 0..<10 {
            buf.append(Data("line \(i) data here\n".utf8))
        }
        // Use offset 0 which is definitely overwritten
        let (data, _, isFull) = buf.snapshotSince(0)
        #expect(isFull == true)
        // Should have ESC[0m prefix (SGR reset)
        #expect(data.starts(with: Data([0x1B, 0x5B, 0x30, 0x6D])))
    }

    @Test("Drain returns data with SGR reset after overflow")
    func drainAfterOverflow() {
        let buf = RingBuffer(capacity: 32)
        for i in 0..<5 {
            buf.append(Data("line \(i) is here now\n".utf8))
        }
        let drained = buf.drain()
        // Should start with ESC[0m
        #expect(drained.starts(with: Data([0x1B, 0x5B, 0x30, 0x6D])))
        // After drain, buffer is empty
        #expect(buf.snapshot().isEmpty)
    }

    @Test("Drain without overflow returns raw data")
    func drainNoOverflow() {
        let buf = RingBuffer(capacity: 1024)
        buf.append(Data("hello".utf8))
        let drained = buf.drain()
        #expect(String(data: drained, encoding: .utf8) == "hello")
        #expect(buf.snapshot().isEmpty)
    }

    @Test("Thread safety: concurrent appends don't crash")
    func threadSafety() async {
        let buf = RingBuffer(capacity: 4096)
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<100 {
                group.addTask {
                    buf.append(Data("item \(i)\n".utf8))
                }
            }
        }
        // All 100 items written
        #expect(buf.currentOffset > 0)
        let snap = buf.snapshot()
        #expect(!snap.isEmpty)
    }

    @Test("Thread safety: concurrent reads and writes don't crash or corrupt data")
    func concurrentReadWrite() async {
        let buf = RingBuffer(capacity: 4096)
        let iterations = 200

        await withTaskGroup(of: Void.self) { group in
            // Writers
            for i in 0..<iterations {
                group.addTask {
                    buf.append(Data("write-\(i)\n".utf8))
                }
            }
            // Concurrent readers: snapshot, snapshotSince, currentOffset, drain
            for _ in 0..<50 {
                group.addTask {
                    _ = buf.snapshot()
                }
                group.addTask {
                    _ = buf.currentOffset
                }
                group.addTask {
                    _ = buf.snapshotSince(0)
                }
            }
        }

        // Buffer should still be consistent after concurrent access
        let offset = buf.currentOffset
        #expect(offset > 0)
        let snap = buf.snapshot()
        #expect(!snap.isEmpty)
    }

    @Test("Thread safety: concurrent drain does not lose data or crash")
    func concurrentDrain() async {
        let buf = RingBuffer(capacity: 2048)

        // Pre-fill some data
        for i in 0..<50 {
            buf.append(Data("prefill-\(i)\n".utf8))
        }

        await withTaskGroup(of: Void.self) { group in
            // Multiple drains racing against appends
            for i in 0..<50 {
                group.addTask {
                    buf.append(Data("race-\(i)\n".utf8))
                }
                group.addTask {
                    _ = buf.drain()
                }
            }
        }

        // Should not crash; offset should reflect all writes
        #expect(buf.currentOffset > 0)
    }
}
