import Testing
import Foundation
@testable import MacAgentLib

// MARK: - Helpers

/// Collected writes from `writeToPTY`.
private final class PTYSink {
    var bytes: [UInt8] = []

    func write(_ ptr: UnsafePointer<UInt8>, _ count: Int) {
        bytes.append(contentsOf: UnsafeBufferPointer(start: ptr, count: count))
    }
}

private let PREFIX: UInt8 = 0x1D  // Ctrl-]

private func makeHandler(sink: PTYSink) -> AttachPrefixHandler {
    AttachPrefixHandler(prefixByte: PREFIX, writeToPTY: sink.write)
}

/// Feed a byte array into the handler and return the action.
private func feed(_ handler: inout AttachPrefixHandler, _ bytes: [UInt8]) -> AttachPrefixHandler.Action {
    bytes.withUnsafeBufferPointer { buf in
        handler.feed(buf.baseAddress!, count: buf.count)
    }
}

// MARK: - Basic Actions

@Suite("AttachPrefixHandler — Actions")
struct AttachPrefixHandlerActionTests {

    @Test("prefix + d returns .detach")
    func prefixD() {
        let sink = PTYSink()
        var handler = makeHandler(sink: sink)
        let action = feed(&handler, [PREFIX, UInt8(ascii: "d")])
        #expect(action == .detach)
        #expect(sink.bytes.isEmpty)
    }

    @Test("prefix + k returns .kill")
    func prefixK() {
        let sink = PTYSink()
        var handler = makeHandler(sink: sink)
        let action = feed(&handler, [PREFIX, UInt8(ascii: "k")])
        #expect(action == .kill)
        #expect(sink.bytes.isEmpty)
    }

    @Test("prefix + prefix sends literal prefix to PTY")
    func prefixPrefix() {
        let sink = PTYSink()
        var handler = makeHandler(sink: sink)
        let action = feed(&handler, [PREFIX, PREFIX])
        #expect(action == .none)
        #expect(sink.bytes == [PREFIX])
    }

    @Test("prefix + unknown is silently consumed")
    func prefixUnknown() {
        let sink = PTYSink()
        var handler = makeHandler(sink: sink)
        let action = feed(&handler, [PREFIX, UInt8(ascii: "z")])
        #expect(action == .none)
        #expect(sink.bytes.isEmpty)
    }

    @Test("normal bytes without prefix are forwarded to PTY")
    func normalBytes() {
        let sink = PTYSink()
        var handler = makeHandler(sink: sink)
        let input: [UInt8] = Array("hello".utf8)
        let action = feed(&handler, input)
        #expect(action == .none)
        #expect(sink.bytes == input)
    }
}

// MARK: - Flush Before Action

@Suite("AttachPrefixHandler — Flush before action")
struct AttachPrefixHandlerFlushTests {

    @Test("bytes before prefix + k are flushed to PTY")
    func flushBeforeKill() {
        let sink = PTYSink()
        var handler = makeHandler(sink: sink)
        let input: [UInt8] = [UInt8(ascii: "A"), UInt8(ascii: "B"), PREFIX, UInt8(ascii: "k")]
        let action = feed(&handler, input)
        #expect(action == .kill)
        #expect(sink.bytes == [UInt8(ascii: "A"), UInt8(ascii: "B")])
    }

    @Test("bytes before prefix + d are flushed to PTY")
    func flushBeforeDetach() {
        let sink = PTYSink()
        var handler = makeHandler(sink: sink)
        let input: [UInt8] = [UInt8(ascii: "A"), PREFIX, UInt8(ascii: "d")]
        let action = feed(&handler, input)
        #expect(action == .detach)
        #expect(sink.bytes == [UInt8(ascii: "A")])
    }
}

// MARK: - Split Buffer (prefix at end)

@Suite("AttachPrefixHandler — Split buffer")
struct AttachPrefixHandlerSplitTests {

    @Test("prefix at end of buffer stays pending until next feed")
    func prefixAtEnd() {
        let sink = PTYSink()
        var handler = makeHandler(sink: sink)

        // First feed: data + prefix at end
        let action1 = feed(&handler, [UInt8(ascii: "A"), PREFIX])
        #expect(action1 == .none)
        #expect(sink.bytes == [UInt8(ascii: "A")])

        // Second feed: action byte
        sink.bytes.removeAll()
        let action2 = feed(&handler, [UInt8(ascii: "k")])
        #expect(action2 == .kill)
        #expect(sink.bytes.isEmpty)
    }

    @Test("prefix at end + d in next feed returns .detach")
    func splitDetach() {
        let sink = PTYSink()
        var handler = makeHandler(sink: sink)
        _ = feed(&handler, [PREFIX])
        let action = feed(&handler, [UInt8(ascii: "d")])
        #expect(action == .detach)
    }
}
