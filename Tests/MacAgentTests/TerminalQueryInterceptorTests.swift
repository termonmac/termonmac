import Testing
import Foundation
@testable import MacAgentLib

@Suite("TerminalQueryInterceptor")
struct TerminalQueryInterceptorTests {

    // MARK: - Passthrough (no interception)

    @Test("regular text passes through unchanged")
    func regularText() {
        let input = Data("hello world\r\n".utf8)
        let result = TerminalQueryInterceptor.intercept(input)
        #expect(result.filteredOutput == input)
        #expect(result.responses.isEmpty)
    }

    @Test("normal CSI sequences pass through")
    func normalCSI() {
        let input = Data("\u{1B}[2J\u{1B}[H\u{1B}[31m".utf8)
        let result = TerminalQueryInterceptor.intercept(input)
        #expect(result.filteredOutput == input)
        #expect(result.responses.isEmpty)
    }

    @Test("CPR query passes through (iOS side handles it)")
    func cprPassthrough() {
        let input = Data("\u{1B}[6n".utf8)
        let result = TerminalQueryInterceptor.intercept(input)
        #expect(result.filteredOutput == input)
        #expect(result.responses.isEmpty)
    }

    @Test("DSR 5 query intercepted with status OK")
    func dsrIntercepted() {
        let input = Data("\u{1B}[5n".utf8)
        let result = TerminalQueryInterceptor.intercept(input)
        #expect(result.filteredOutput.isEmpty)
        #expect(result.responses.count == 1)
        #expect(result.responses[0] == Data("\u{1B}[0n".utf8))
    }

    @Test("DA2 query (ESC [ > c) intercepted")
    func da2Intercepted() {
        let input = Data("\u{1B}[>c".utf8)
        let result = TerminalQueryInterceptor.intercept(input)
        #expect(result.filteredOutput.isEmpty)
        #expect(result.responses.count == 1)
        #expect(result.responses[0] == Data("\u{1B}[>65;20;1c".utf8))
    }

    @Test("DA2 query (ESC [ > 0 c) intercepted")
    func da2WithZero() {
        let input = Data("\u{1B}[>0c".utf8)
        let result = TerminalQueryInterceptor.intercept(input)
        #expect(result.filteredOutput.isEmpty)
        #expect(result.responses.count == 1)
    }

    @Test("OSC set title passes through")
    func oscTitle() {
        let input = Data("\u{1B}]0;my title\u{07}".utf8)
        let result = TerminalQueryInterceptor.intercept(input)
        #expect(result.filteredOutput == input)
        #expect(result.responses.isEmpty)
    }

    // MARK: - DA1 interception

    @Test("DA1 query (ESC [ c) is intercepted")
    func da1Query() {
        let input = Data("\u{1B}[c".utf8)
        let result = TerminalQueryInterceptor.intercept(input)
        #expect(result.filteredOutput == Data())
        #expect(result.responses.count == 1)
        #expect(result.responses[0] == Data("\u{1B}[?65;20;1c".utf8))
    }

    @Test("DA1 query (ESC [ 0 c) is intercepted")
    func da1QueryWithZero() {
        let input = Data("\u{1B}[0c".utf8)
        let result = TerminalQueryInterceptor.intercept(input)
        #expect(result.filteredOutput == Data())
        #expect(result.responses.count == 1)
    }

    @Test("DA1 embedded in output — only query removed")
    func da1Embedded() {
        let input = Data("before\u{1B}[cafter".utf8)
        let result = TerminalQueryInterceptor.intercept(input)
        #expect(result.filteredOutput == Data("beforeafter".utf8))
        #expect(result.responses.count == 1)
    }

    // MARK: - OSC 10/11 query interception

    @Test("OSC 10 query (BEL terminated) is intercepted")
    func osc10Bel() {
        let input = Data("\u{1B}]10;?\u{07}".utf8)
        let result = TerminalQueryInterceptor.intercept(input)
        #expect(result.filteredOutput == Data())
        #expect(result.responses.count == 1)
        // Response should be OSC 10 with white foreground
        let resp = String(data: result.responses[0], encoding: .utf8)!
        #expect(resp.contains("10;rgb:ffff/ffff/ffff"))
    }

    @Test("OSC 10 query (ST terminated) is intercepted")
    func osc10ST() {
        let input = Data("\u{1B}]10;?\u{1B}\\".utf8)
        let result = TerminalQueryInterceptor.intercept(input)
        #expect(result.filteredOutput == Data())
        #expect(result.responses.count == 1)
    }

    @Test("OSC 11 query is intercepted")
    func osc11() {
        let input = Data("\u{1B}]11;?\u{07}".utf8)
        let result = TerminalQueryInterceptor.intercept(input)
        #expect(result.filteredOutput == Data())
        #expect(result.responses.count == 1)
        let resp = String(data: result.responses[0], encoding: .utf8)!
        #expect(resp.contains("11;rgb:0000/0000/0000"))
    }

    @Test("OSC 10 color SET (not a query) passes through")
    func osc10Set() {
        // Setting color — content is NOT "?", so not a query
        let input = Data("\u{1B}]10;white\u{07}".utf8)
        let result = TerminalQueryInterceptor.intercept(input)
        #expect(result.filteredOutput == input)
        #expect(result.responses.isEmpty)
    }

    // MARK: - DECRPM interception

    @Test("DECRPM query is intercepted")
    func decrpm() {
        // ESC [ ? 12 $ p
        let input = Data("\u{1B}[?12$p".utf8)
        let result = TerminalQueryInterceptor.intercept(input)
        #expect(result.filteredOutput == Data())
        #expect(result.responses.count == 1)
        let resp = String(data: result.responses[0], encoding: .utf8)!
        #expect(resp.contains("12;2$y"))
    }

    @Test("DECRPM with different mode number")
    func decrpmOtherMode() {
        let input = Data("\u{1B}[?25$p".utf8)
        let result = TerminalQueryInterceptor.intercept(input)
        #expect(result.filteredOutput == Data())
        #expect(result.responses.count == 1)
        let resp = String(data: result.responses[0], encoding: .utf8)!
        #expect(resp.contains("25;2$y"))
    }

    // MARK: - Multiple queries

    @Test("multiple queries in one buffer all intercepted")
    func multipleQueries() {
        var s = "prompt % "
        s += "\u{1B}[c"           // DA1
        s += "\u{1B}]10;?\u{07}"  // OSC 10
        s += "\u{1B}]11;?\u{07}"  // OSC 11
        s += "\u{1B}[?12$p"       // DECRPM
        s += "more text"
        let input = Data(s.utf8)
        let result = TerminalQueryInterceptor.intercept(input)
        #expect(result.filteredOutput == Data("prompt % more text".utf8))
        #expect(result.responses.count == 4)
    }

    // MARK: - Edge cases

    @Test("empty data")
    func emptyData() {
        let result = TerminalQueryInterceptor.intercept(Data())
        #expect(result.filteredOutput == Data())
        #expect(result.responses.isEmpty)
    }

    @Test("lone ESC at end passes through")
    func loneEsc() {
        let input = Data("text\u{1B}".utf8)
        let result = TerminalQueryInterceptor.intercept(input)
        #expect(result.filteredOutput == input)
        #expect(result.responses.isEmpty)
    }

    @Test("ESC + non-CSI/OSC escape passes through")
    func nonQueryEscape() {
        // ESC D (IND), ESC 7 (DECSC), ESC M (RI) — not queries, pass through
        let input = Data("\u{1B}D\u{1B}7\u{1B}M".utf8)
        let result = TerminalQueryInterceptor.intercept(input)
        #expect(result.filteredOutput == input)
        #expect(result.responses.isEmpty)
    }

    @Test("ESC [ at end of buffer (incomplete CSI)")
    func incompleteCSIAtEnd() {
        let input = Data("text\u{1B}[".utf8)
        let result = TerminalQueryInterceptor.intercept(input)
        #expect(result.filteredOutput == input)
        #expect(result.responses.isEmpty)
    }

    @Test("ESC ] at end of buffer (incomplete OSC)")
    func incompleteOSCAtEnd() {
        let input = Data("text\u{1B}]".utf8)
        let result = TerminalQueryInterceptor.intercept(input)
        #expect(result.filteredOutput == input)
        #expect(result.responses.isEmpty)
    }
}

// MARK: - CSI Matching Edge Cases

@Suite("TerminalQueryInterceptor — CSI Edge Cases")
struct TerminalQueryInterceptorCSIEdgeTests {

    @Test("DA1 with non-zero param (ESC [ 1 c) is NOT intercepted")
    func da1NonZeroParam() {
        let input = Data("\u{1B}[1c".utf8)
        let result = TerminalQueryInterceptor.intercept(input)
        #expect(result.filteredOutput == input)
        #expect(result.responses.isEmpty)
    }

    @Test("DA2 with non-zero param (ESC [ > 1 c) is NOT intercepted")
    func da2NonZeroParam() {
        // ESC [ > 1 c — bytes[j] == '1', not '0' and not 'c'
        let input = Data("\u{1B}[>1c".utf8)
        let result = TerminalQueryInterceptor.intercept(input)
        #expect(result.filteredOutput == input)
        #expect(result.responses.isEmpty)
    }

    @Test("ESC [ > at end of buffer passes through")
    func da2IncompleteAtEnd() {
        let input = Data("text\u{1B}[>".utf8)
        let result = TerminalQueryInterceptor.intercept(input)
        #expect(result.filteredOutput == input)
        #expect(result.responses.isEmpty)
    }

    @Test("DSR with non-5 param passes through")
    func dsrNon5() {
        // ESC [ 3 n — not DSR 5
        let input = Data("\u{1B}[3n".utf8)
        let result = TerminalQueryInterceptor.intercept(input)
        #expect(result.filteredOutput == input)
        #expect(result.responses.isEmpty)
    }

    @Test("ESC [ 5 followed by non-n passes through")
    func dsr5NonN() {
        // ESC [ 5 x — '5' matches but 'x' is not 'n'
        let input = Data("\u{1B}[5x".utf8)
        let result = TerminalQueryInterceptor.intercept(input)
        #expect(result.filteredOutput == input)
        #expect(result.responses.isEmpty)
    }

    @Test("DECRPM with no digits (ESC [ ? $ p) is NOT intercepted")
    func decrpmNoDigits() {
        let input = Data("\u{1B}[?$p".utf8)
        let result = TerminalQueryInterceptor.intercept(input)
        #expect(result.filteredOutput == input)
        #expect(result.responses.isEmpty)
    }

    @Test("DECRPM with wrong terminator (ESC [ ? 25 $ q) is NOT intercepted")
    func decrpmWrongTerminator() {
        // $ q instead of $ p
        let input = Data("\u{1B}[?25$q".utf8)
        let result = TerminalQueryInterceptor.intercept(input)
        #expect(result.filteredOutput == input)
        #expect(result.responses.isEmpty)
    }

    @Test("DECSET (ESC [ ? 25 h) is NOT intercepted")
    func decsetPassthrough() {
        // ESC [ ? 25 h — DECTCEM, should pass through as normal CSI
        let input = Data("\u{1B}[?25h".utf8)
        let result = TerminalQueryInterceptor.intercept(input)
        #expect(result.filteredOutput == input)
        #expect(result.responses.isEmpty)
    }

    @Test("DECRPM response includes mode number")
    func decrpmResponseFormat() {
        // ESC [ ? 1049 $ p → response should contain "1049;2$y"
        let input = Data("\u{1B}[?1049$p".utf8)
        let result = TerminalQueryInterceptor.intercept(input)
        #expect(result.responses.count == 1)
        let resp = String(data: result.responses[0], encoding: .utf8)!
        #expect(resp == "\u{1B}[?1049;2$y")
    }

    @Test("ESC [ 5 at end of buffer passes through")
    func dsr5IncompleteAtEnd() {
        let input = Data("text\u{1B}[5".utf8)
        let result = TerminalQueryInterceptor.intercept(input)
        #expect(result.filteredOutput == input)
        #expect(result.responses.isEmpty)
    }
}

// MARK: - OSC Matching Edge Cases

@Suite("TerminalQueryInterceptor — OSC Edge Cases")
struct TerminalQueryInterceptorOSCEdgeTests {

    @Test("OSC 12 query is NOT intercepted (unknown number)")
    func osc12Passthrough() {
        let input = Data("\u{1B}]12;?\u{07}".utf8)
        let result = TerminalQueryInterceptor.intercept(input)
        #expect(result.filteredOutput == input)
        #expect(result.responses.isEmpty)
    }

    @Test("OSC 4 query is NOT intercepted")
    func osc4Passthrough() {
        let input = Data("\u{1B}]4;?\u{07}".utf8)
        let result = TerminalQueryInterceptor.intercept(input)
        #expect(result.filteredOutput == input)
        #expect(result.responses.isEmpty)
    }

    @Test("OSC with no semicolon passes through")
    func oscNoSemicolon() {
        // ESC ] 10 BEL — no semicolon, not a query
        let input = Data("\u{1B}]10\u{07}".utf8)
        let result = TerminalQueryInterceptor.intercept(input)
        #expect(result.filteredOutput == input)
        #expect(result.responses.isEmpty)
    }

    @Test("OSC query without terminator at end of buffer passes through")
    func oscQueryNoTerminator() {
        // ESC ] 10 ; ? (no BEL or ST) — truncated
        let input = Data("\u{1B}]10;?".utf8)
        let result = TerminalQueryInterceptor.intercept(input)
        #expect(result.filteredOutput == input)
        #expect(result.responses.isEmpty)
    }

    @Test("OSC query with invalid terminator passes through")
    func oscQueryBadTerminator() {
        // ESC ] 10 ; ? X — 'X' is not BEL or ST
        let input = Data("\u{1B}]10;?X".utf8)
        let result = TerminalQueryInterceptor.intercept(input)
        #expect(result.filteredOutput == input)
        #expect(result.responses.isEmpty)
    }

    @Test("OSC with no number passes through")
    func oscNoNumber() {
        // ESC ] ; ? BEL — no digits before semicolon
        let input = Data("\u{1B}];?\u{07}".utf8)
        let result = TerminalQueryInterceptor.intercept(input)
        #expect(result.filteredOutput == input)
        #expect(result.responses.isEmpty)
    }

    @Test("OSC 11 query with ST terminator")
    func osc11ST() {
        let input = Data("\u{1B}]11;?\u{1B}\\".utf8)
        let result = TerminalQueryInterceptor.intercept(input)
        #expect(result.filteredOutput.isEmpty)
        #expect(result.responses.count == 1)
        let resp = String(data: result.responses[0], encoding: .utf8)!
        #expect(resp.contains("11;rgb:0000/0000/0000"))
    }

    @Test("OSC 10 query embedded in output — only query removed")
    func osc10Embedded() {
        let input = Data("before\u{1B}]10;?\u{07}after".utf8)
        let result = TerminalQueryInterceptor.intercept(input)
        #expect(result.filteredOutput == Data("beforeafter".utf8))
        #expect(result.responses.count == 1)
    }
}

// MARK: - Category 1: Non-standard prefix immunity

@Suite("TerminalQueryInterceptor — Non-standard Prefix Immunity")
struct TerminalQueryInterceptorPrefixImmunityTests {

    @Test("ESC [ < c should NOT be intercepted as DA1 (has < prefix)")
    func csiLessThanC() {
        // '<' prefix makes this a different sequence, not DA1
        let input = Data("\u{1B}[<c".utf8)
        let result = TerminalQueryInterceptor.intercept(input)
        #expect(result.filteredOutput == input)
        #expect(result.responses.isEmpty)
    }

    @Test("ESC [ > 1 c — DA2 with non-zero param is NOT intercepted")
    func da2WithParam1() {
        // DA2 query only matches ESC[>c or ESC[>0c, not ESC[>1c
        let input = Data("\u{1B}[>1c".utf8)
        let result = TerminalQueryInterceptor.intercept(input)
        #expect(result.filteredOutput == input)
        #expect(result.responses.isEmpty)
    }

    @Test("ESC [ > 2 c — DA2 with param 2 is NOT intercepted")
    func da2WithParam2() {
        let input = Data("\u{1B}[>2c".utf8)
        let result = TerminalQueryInterceptor.intercept(input)
        #expect(result.filteredOutput == input)
        #expect(result.responses.isEmpty)
    }

    @Test("ESC [ < 5 n should NOT be intercepted as DSR")
    func csiLessThan5n() {
        // '<' prefix makes this a different sequence
        let input = Data("\u{1B}[<5n".utf8)
        let result = TerminalQueryInterceptor.intercept(input)
        #expect(result.filteredOutput == input)
        #expect(result.responses.isEmpty)
    }

    @Test("ESC [ ? u — kitty keyboard query should NOT be intercepted as DECRPM")
    func kittyKeyboardQuery() {
        // ESC[?u is kitty keyboard protocol query — no digits before 'u',
        // and 'u' is not '$p', so DECRPM branch should not match
        let input = Data("\u{1B}[?u".utf8)
        let result = TerminalQueryInterceptor.intercept(input)
        #expect(result.filteredOutput == input)
        #expect(result.responses.isEmpty)
    }

    @Test("ESC [ ? 1 u — kitty keyboard with mode number should NOT be intercepted")
    func kittyKeyboardQueryWithMode() {
        // Has digits after '?' but terminator is 'u' not '$p'
        let input = Data("\u{1B}[?1u".utf8)
        let result = TerminalQueryInterceptor.intercept(input)
        #expect(result.filteredOutput == input)
        #expect(result.responses.isEmpty)
    }

    @Test("ESC [ = c — DA3 (tertiary device attributes) should NOT be intercepted")
    func da3Query() {
        let input = Data("\u{1B}[=c".utf8)
        let result = TerminalQueryInterceptor.intercept(input)
        #expect(result.filteredOutput == input)
        #expect(result.responses.isEmpty)
    }
}

// MARK: - Category 2: Partial/incomplete matches

@Suite("TerminalQueryInterceptor — Partial/Incomplete Matches")
struct TerminalQueryInterceptorPartialMatchTests {

    @Test("ESC [ 5 (truncated, no 'n') — should not trigger DSR")
    func truncatedDSR() {
        let input = Data("\u{1B}[5".utf8)
        let result = TerminalQueryInterceptor.intercept(input)
        #expect(result.filteredOutput == input)
        #expect(result.responses.isEmpty)
    }

    @Test("ESC [ alone — should not trigger anything")
    func escBracketOnly() {
        let input = Data("\u{1B}[".utf8)
        let result = TerminalQueryInterceptor.intercept(input)
        #expect(result.filteredOutput == input)
        #expect(result.responses.isEmpty)
    }

    @Test("ESC ] 10 (no semicolon, no ?) — should not trigger OSC color query")
    func oscNumberNoSemicolon() {
        // Just ESC]10 at end of buffer, no terminator
        let input = Data("\u{1B}]10".utf8)
        let result = TerminalQueryInterceptor.intercept(input)
        #expect(result.filteredOutput == input)
        #expect(result.responses.isEmpty)
    }

    @Test("ESC ] 10 ; x (not '?') — should not trigger OSC color query")
    func oscSemicolonNonQuery() {
        // Content after semicolon is 'x', not '?'
        let input = Data("\u{1B}]10;x\u{07}".utf8)
        let result = TerminalQueryInterceptor.intercept(input)
        #expect(result.filteredOutput == input)
        #expect(result.responses.isEmpty)
    }

    @Test("ESC [ > alone at end — incomplete DA2")
    func incompleteDA2() {
        let input = Data("\u{1B}[>".utf8)
        let result = TerminalQueryInterceptor.intercept(input)
        #expect(result.filteredOutput == input)
        #expect(result.responses.isEmpty)
    }

    @Test("ESC [ > 0 alone at end — incomplete DA2 with param")
    func incompleteDA2WithParam() {
        let input = Data("\u{1B}[>0".utf8)
        let result = TerminalQueryInterceptor.intercept(input)
        #expect(result.filteredOutput == input)
        #expect(result.responses.isEmpty)
    }

    @Test("ESC [ ? 25 $ alone at end — incomplete DECRPM")
    func incompleteDECRPM() {
        let input = Data("\u{1B}[?25$".utf8)
        let result = TerminalQueryInterceptor.intercept(input)
        #expect(result.filteredOutput == input)
        #expect(result.responses.isEmpty)
    }

    @Test("ESC [ ? 25 alone at end — DECRPM without $ p")
    func decrpmNoTerminator() {
        let input = Data("\u{1B}[?25".utf8)
        let result = TerminalQueryInterceptor.intercept(input)
        #expect(result.filteredOutput == input)
        #expect(result.responses.isEmpty)
    }

    @Test("ESC ] 10 ; ? alone at end — OSC query without terminator")
    func oscQueryTruncated() {
        let input = Data("\u{1B}]10;?".utf8)
        let result = TerminalQueryInterceptor.intercept(input)
        #expect(result.filteredOutput == input)
        #expect(result.responses.isEmpty)
    }

    @Test("ESC ] 10 ; ? ESC alone at end — OSC query with partial ST")
    func oscQueryPartialST() {
        // ESC]10;?\x1B — the ESC could start ST but no backslash follows
        let input = Data("\u{1B}]10;?\u{1B}".utf8)
        let result = TerminalQueryInterceptor.intercept(input)
        #expect(result.filteredOutput == input)
        #expect(result.responses.isEmpty)
    }
}

// MARK: - Category 3: String sequence boundary

@Suite("TerminalQueryInterceptor — Sequence Boundary")
struct TerminalQueryInterceptorBoundaryTests {

    @Test("Normal text 'escape[c' — should not be intercepted")
    func plainTextNotIntercepted() {
        // The literal text "escape[c" has no ESC byte
        let input = Data("escape[c".utf8)
        let result = TerminalQueryInterceptor.intercept(input)
        #expect(result.filteredOutput == input)
        #expect(result.responses.isEmpty)
    }

    @Test("Multiple queries in one chunk — all should be intercepted")
    func multipleQueriesAllIntercepted() {
        var bytes = [UInt8]()
        // DA1: ESC [ c
        bytes.append(contentsOf: [0x1B, 0x5B, 0x63])
        // DA2: ESC [ > c
        bytes.append(contentsOf: [0x1B, 0x5B, 0x3E, 0x63])
        // DSR 5: ESC [ 5 n
        bytes.append(contentsOf: [0x1B, 0x5B, 0x35, 0x6E])
        // OSC 10: ESC ] 10 ; ? BEL
        bytes.append(contentsOf: [0x1B, 0x5D, 0x31, 0x30, 0x3B, 0x3F, 0x07])
        // OSC 11: ESC ] 11 ; ? ESC \
        bytes.append(contentsOf: [0x1B, 0x5D, 0x31, 0x31, 0x3B, 0x3F, 0x1B, 0x5C])
        // DECRPM: ESC [ ? 25 $ p
        bytes.append(contentsOf: [0x1B, 0x5B, 0x3F, 0x32, 0x35, 0x24, 0x70])

        let input = Data(bytes)
        let result = TerminalQueryInterceptor.intercept(input)
        #expect(result.filteredOutput.isEmpty)
        #expect(result.responses.count == 6)

        // Verify each response type
        let resps = result.responses.map { String(data: $0, encoding: .utf8)! }
        #expect(resps[0].contains("?65;20;1c"))       // DA1
        #expect(resps[1].contains(">65;20;1c"))        // DA2
        #expect(resps[2] == "\u{1B}[0n")               // DSR OK
        #expect(resps[3].contains("10;rgb:ffff"))       // OSC 10
        #expect(resps[4].contains("11;rgb:0000"))       // OSC 11
        #expect(resps[5].contains("25;2$y"))            // DECRPM
    }

    @Test("Queries interleaved with normal text — only queries stripped")
    func queriesInterleavedWithText() {
        let input = Data("AAA\u{1B}[cBBB\u{1B}[5nCCC\u{1B}]10;?\u{07}DDD".utf8)
        let result = TerminalQueryInterceptor.intercept(input)
        #expect(result.filteredOutput == Data("AAABBBCCCDDD".utf8))
        #expect(result.responses.count == 3)
    }

    @Test("DA1 query immediately followed by another DA1 query")
    func backToBackDA1() {
        let input = Data("\u{1B}[c\u{1B}[c".utf8)
        let result = TerminalQueryInterceptor.intercept(input)
        #expect(result.filteredOutput.isEmpty)
        #expect(result.responses.count == 2)
        #expect(result.responses[0] == result.responses[1])
    }

    @Test("Non-intercepted CSI followed by intercepted query")
    func nonInterceptedThenIntercepted() {
        // ESC[2J (clear screen, not intercepted) then ESC[c (DA1, intercepted)
        let input = Data("\u{1B}[2J\u{1B}[c".utf8)
        let result = TerminalQueryInterceptor.intercept(input)
        #expect(result.filteredOutput == Data("\u{1B}[2J".utf8))
        #expect(result.responses.count == 1)
    }

    @Test("Intercepted query followed by non-intercepted CSI")
    func interceptedThenNonIntercepted() {
        let input = Data("\u{1B}[c\u{1B}[2J".utf8)
        let result = TerminalQueryInterceptor.intercept(input)
        #expect(result.filteredOutput == Data("\u{1B}[2J".utf8))
        #expect(result.responses.count == 1)
    }
}

// MARK: - Category 4: Edge cases

@Suite("TerminalQueryInterceptor — Edge Cases")
struct TerminalQueryInterceptorEdgeCaseTests {

    @Test("Empty data returns empty")
    func emptyDataEdge() {
        let result = TerminalQueryInterceptor.intercept(Data())
        #expect(result.filteredOutput == Data())
        #expect(result.responses.isEmpty)
    }

    @Test("Single ESC byte only")
    func singleEscByte() {
        let input = Data([0x1B])
        let result = TerminalQueryInterceptor.intercept(input)
        #expect(result.filteredOutput == input)
        #expect(result.responses.isEmpty)
    }

    @Test("Very large data (>16KB) with a query buried in the middle")
    func largeDataWithQueryInMiddle() {
        let padding = Data(repeating: 0x41, count: 8192) // 8KB of 'A'
        let query = Data("\u{1B}[c".utf8)                // DA1
        let trailing = Data(repeating: 0x42, count: 8192) // 8KB of 'B'

        var input = Data()
        input.append(padding)
        input.append(query)
        input.append(trailing)

        let result = TerminalQueryInterceptor.intercept(input)

        var expected = Data()
        expected.append(padding)
        expected.append(trailing)

        #expect(result.filteredOutput == expected)
        #expect(result.filteredOutput.count == 16384)
        #expect(result.responses.count == 1)
        #expect(result.responses[0] == Data("\u{1B}[?65;20;1c".utf8))
    }

    @Test("Query at the very end of data (last bytes)")
    func queryAtEnd() {
        let input = Data("some output text\u{1B}[c".utf8)
        let result = TerminalQueryInterceptor.intercept(input)
        #expect(result.filteredOutput == Data("some output text".utf8))
        #expect(result.responses.count == 1)
    }

    @Test("Query at the very start of data (first bytes)")
    func queryAtStart() {
        let input = Data("\u{1B}[csome output text".utf8)
        let result = TerminalQueryInterceptor.intercept(input)
        #expect(result.filteredOutput == Data("some output text".utf8))
        #expect(result.responses.count == 1)
    }

    @Test("Data is exactly one query and nothing else (DA1)")
    func exactlyDA1() {
        let input = Data("\u{1B}[c".utf8)
        let result = TerminalQueryInterceptor.intercept(input)
        #expect(result.filteredOutput.isEmpty)
        #expect(result.responses.count == 1)
    }

    @Test("Data is exactly one query and nothing else (OSC 10)")
    func exactlyOSC10() {
        let input = Data("\u{1B}]10;?\u{07}".utf8)
        let result = TerminalQueryInterceptor.intercept(input)
        #expect(result.filteredOutput.isEmpty)
        #expect(result.responses.count == 1)
    }

    @Test("Multiple ESC bytes in a row without forming valid sequences")
    func multipleEscBytes() {
        let input = Data([0x1B, 0x1B, 0x1B, 0x1B])
        let result = TerminalQueryInterceptor.intercept(input)
        #expect(result.filteredOutput == input)
        #expect(result.responses.isEmpty)
    }

    @Test("ESC followed by [ then ESC — nested ESC does not crash")
    func escBracketEsc() {
        // ESC [ ESC — the inner ESC is not 'c' or any query char
        let input = Data([0x1B, 0x5B, 0x1B])
        let result = TerminalQueryInterceptor.intercept(input)
        // matchCSIQuery gets called with start pointing at the inner ESC.
        // 0x1B is not 'c', '0', '>', '5', or '?', so returns nil.
        // The outer ESC and [ pass through; then inner ESC is processed
        // on next iteration but i+1 is past end, so it passes through too.
        #expect(result.filteredOutput == input)
        #expect(result.responses.isEmpty)
    }

    @Test("Binary data with embedded query still works")
    func binaryDataWithQuery() {
        var input = Data([0x00, 0xFF, 0x80, 0x7F])
        input.append(Data("\u{1B}[5n".utf8))
        input.append(Data([0x00, 0xFF]))

        let result = TerminalQueryInterceptor.intercept(input)
        #expect(result.filteredOutput == Data([0x00, 0xFF, 0x80, 0x7F, 0x00, 0xFF]))
        #expect(result.responses.count == 1)
        #expect(result.responses[0] == Data("\u{1B}[0n".utf8))
    }

    @Test("DECRPM with very large mode number")
    func decrpmLargeModeNumber() {
        // ESC [ ? 999999 $ p
        let input = Data("\u{1B}[?999999$p".utf8)
        let result = TerminalQueryInterceptor.intercept(input)
        #expect(result.filteredOutput.isEmpty)
        #expect(result.responses.count == 1)
        let resp = String(data: result.responses[0], encoding: .utf8)!
        #expect(resp == "\u{1B}[?999999;2$y")
    }

    @Test("DA1 with ESC [ 0 c — zero param variant at end of buffer")
    func da1ZeroParamAtEnd() {
        let input = Data("output\u{1B}[0c".utf8)
        let result = TerminalQueryInterceptor.intercept(input)
        #expect(result.filteredOutput == Data("output".utf8))
        #expect(result.responses.count == 1)
        #expect(result.responses[0] == Data("\u{1B}[?65;20;1c".utf8))
    }

    @Test("DA2 with ESC [ > 0 c — zero param variant at end of buffer")
    func da2ZeroParamAtEnd() {
        let input = Data("output\u{1B}[>0c".utf8)
        let result = TerminalQueryInterceptor.intercept(input)
        #expect(result.filteredOutput == Data("output".utf8))
        #expect(result.responses.count == 1)
        #expect(result.responses[0] == Data("\u{1B}[>65;20;1c".utf8))
    }

    @Test("When no queries found, filteredOutput is same Data object (optimization)")
    func noQueryOptimization() {
        let input = Data("hello world".utf8)
        let result = TerminalQueryInterceptor.intercept(input)
        // Should return the original data, not a copy
        #expect(result.filteredOutput == input)
        #expect(result.responses.isEmpty)
    }

    @Test("ESC [ 0 at end of buffer — incomplete DA1 with param")
    func incompleteDA1WithParam() {
        let input = Data("\u{1B}[0".utf8)
        let result = TerminalQueryInterceptor.intercept(input)
        #expect(result.filteredOutput == input)
        #expect(result.responses.isEmpty)
    }

    @Test("OSC 10 with ST terminator preserves surrounding text")
    func osc10STWithSurroundingText() {
        let input = Data("before\u{1B}]10;?\u{1B}\\after".utf8)
        let result = TerminalQueryInterceptor.intercept(input)
        #expect(result.filteredOutput == Data("beforeafter".utf8))
        #expect(result.responses.count == 1)
    }
}

// MARK: - Query Splitting (cross-buffer boundary)

@Suite("TerminalQueryInterceptor — Query Splitting")
struct TerminalQueryInterceptorSplitTests {

    /// Simulate what happens when a terminal query is split across two
    /// consecutive read() calls. The interceptor is stateless — each call
    /// only sees its own buffer. If a query spans two calls, neither call
    /// can match it and the query leaks through to the Mac terminal.

    @Test("DA1 split: ESC at end of first buffer, [c at start of second")
    func da1SplitAtEsc() {
        // First read ends with lone ESC
        let part1 = Data("output\u{1B}".utf8)
        let r1 = TerminalQueryInterceptor.intercept(part1)
        // ESC at end passes through (existing behavior, tested in loneEsc)
        #expect(r1.responses.isEmpty, "part1: no interception expected")

        // Second read starts with [c — remainder of DA1 query
        let part2 = Data("[cmore output".utf8)
        let r2 = TerminalQueryInterceptor.intercept(part2)
        // "[c" doesn't start with ESC, so interceptor can't match it
        #expect(r2.responses.isEmpty, "part2: DA1 query leaked — interceptor missed it")
        // The raw "[c" bytes pass through to stdout → Mac terminal won't treat
        // "[c" without ESC as a query, so no response is generated. SAFE.
    }

    @Test("DA1 split: ESC[ at end of first buffer, c at start of second")
    func da1SplitAtBracket() {
        // First read ends with ESC[
        let part1 = Data("output\u{1B}[".utf8)
        let r1 = TerminalQueryInterceptor.intercept(part1)
        // ESC[ at end: ESC found, i+1 < count → bytes[i+1]==0x5B → matchCSIQuery
        // called with from: i+2, but i+2 == count → matchCSIQuery returns nil
        // → ESC is appended to output, then [ is appended
        #expect(r1.responses.isEmpty, "part1: incomplete CSI, no interception")

        // Second read starts with just 'c'
        let part2 = Data("cmore output".utf8)
        let r2 = TerminalQueryInterceptor.intercept(part2)
        // 'c' alone is not a query
        #expect(r2.responses.isEmpty, "part2: lone 'c' not intercepted")
        // Both ESC[ and c pass through to stdout separately.
        // Mac terminal receives ESC[ then c in separate writes — it MAY
        // reassemble them as a DA1 query and respond. This is the leak scenario.
    }

    @Test("DSR split: ESC[5 at end of first buffer, n at start of second")
    func dsrSplitAtDigit() {
        let part1 = Data("output\u{1B}[5".utf8)
        let r1 = TerminalQueryInterceptor.intercept(part1)
        #expect(r1.responses.isEmpty, "part1: incomplete DSR, no interception")
        // ESC[5 passes through (matchCSIQuery sees '5' but needs 'n' next)

        let part2 = Data("nmore output".utf8)
        let r2 = TerminalQueryInterceptor.intercept(part2)
        #expect(r2.responses.isEmpty, "part2: lone 'n' not intercepted")
    }

    @Test("DECRPM split: ESC[?25$ at end, p at start of next")
    func decrpmSplit() {
        let part1 = Data("output\u{1B}[?25$".utf8)
        let r1 = TerminalQueryInterceptor.intercept(part1)
        #expect(r1.responses.isEmpty, "part1: incomplete DECRPM")

        let part2 = Data("pmore output".utf8)
        let r2 = TerminalQueryInterceptor.intercept(part2)
        #expect(r2.responses.isEmpty, "part2: lone 'p' not intercepted")
    }

    @Test("OSC 10 split: ESC]10;? at end, BEL at start of next")
    func osc10Split() {
        let part1 = Data("output\u{1B}]10;?".utf8)
        let r1 = TerminalQueryInterceptor.intercept(part1)
        // Existing test "oscQueryNoTerminator" confirms this passes through
        #expect(r1.responses.isEmpty, "part1: OSC without terminator passes through")

        let part2 = Data("\u{07}more output".utf8)
        let r2 = TerminalQueryInterceptor.intercept(part2)
        // BEL alone is not a query
        #expect(r2.responses.isEmpty, "part2: lone BEL not intercepted")
    }

    // MARK: - Verify the RISK of each split scenario

    @Test("RISK: ESC[ split is dangerous — Mac terminal reassembles across writes")
    func splitRiskAssessment() {
        // When the CLI writes ESC[ to stdout in one write() and 'c' in the next,
        // the Mac terminal's input parser is STATEFUL — it will reassemble them
        // as a complete DA1 query and respond.
        //
        // This test documents that the interceptor CANNOT catch this case.
        // The fix requires either:
        // (a) Buffering trailing incomplete escape sequences across read() calls
        // (b) Accepting the low probability (query 3-8 bytes vs 16KB read buffer)
        let part1 = Data("output\u{1B}[".utf8)
        let part2 = Data("c".utf8)

        let r1 = TerminalQueryInterceptor.intercept(part1)
        let r2 = TerminalQueryInterceptor.intercept(part2)

        let totalIntercepted = r1.responses.count + r2.responses.count
        #expect(totalIntercepted == 0, "Split query escapes interception — known limitation")

        // For comparison: unsplit query IS intercepted
        let whole = Data("output\u{1B}[c".utf8)
        let rWhole = TerminalQueryInterceptor.intercept(whole)
        #expect(rWhole.responses.count == 1, "Unsplit query is correctly intercepted")
    }
}
