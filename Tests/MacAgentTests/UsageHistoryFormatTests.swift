import Testing
import Foundation
@testable import MacAgentLib

@Suite struct UsageHistoryFormatTests {

    @Test("formats single row with correct column alignment")
    func testSingleRow() {
        let history: [[String: Any]] = [
            ["period_label": "Mar 8, 10:00 – 15:00 UTC", "message_tokens": 100, "duration_tokens": 50, "total_tokens": 150]
        ]

        let output = UsageHistoryFormatter.format(history)
        let lines = output.components(separatedBy: "\n")

        #expect(lines.count == 5) // title + separator + header + separator + 1 data row
        #expect(lines[0] == "Usage History (breakdown)")
        #expect(lines[2].hasPrefix("Period"))
        #expect(lines[4].contains("66%"))
        #expect(lines[4].contains("34%"))
        #expect(lines[4].hasPrefix("Mar 8, 10:00 – 15:00 UTC"))
    }

    @Test("falls back to period key when period_label missing")
    func testFallbackToPeriodKey() {
        let history: [[String: Any]] = [
            ["period": "2024-03-08T10:00:00Z", "message_tokens": 1, "duration_tokens": 2, "total_tokens": 3]
        ]

        let output = UsageHistoryFormatter.format(history)
        #expect(output.contains("2024-03-08T10:00:00Z"))
    }

    @Test("shows ? when both period keys missing")
    func testMissingPeriod() {
        let history: [[String: Any]] = [
            ["message_tokens": 10, "duration_tokens": 20, "total_tokens": 30]
        ]

        let output = UsageHistoryFormatter.format(history)
        let lastLine = output.components(separatedBy: "\n").last!
        #expect(lastLine.hasPrefix("?"))
    }

    @Test("defaults missing token values to 0%")
    func testMissingTokens() {
        let history: [[String: Any]] = [
            ["period_label": "Test Period"]
        ]

        let output = UsageHistoryFormatter.format(history)
        let lastLine = output.components(separatedBy: "\n").last!
        // Should contain 0% for both msg and dur when total is 0
        #expect(lastLine.contains("0%"))
    }

    @Test("formats multiple rows with percentages")
    func testMultipleRows() {
        let history: [[String: Any]] = [
            ["period_label": "Period A", "message_tokens": 100, "duration_tokens": 200, "total_tokens": 300],
            ["period_label": "Period B", "message_tokens": 400, "duration_tokens": 500, "total_tokens": 900],
        ]

        let output = UsageHistoryFormatter.format(history)
        let lines = output.components(separatedBy: "\n")
        #expect(lines.count == 6) // title + sep + header + sep + 2 data rows
        // Period A: msg 33%, dur 67%
        #expect(lines[4].contains("33%"))
        #expect(lines[4].contains("67%"))
        // Period B: msg 44%, dur 56%
        #expect(lines[5].contains("44%"))
        #expect(lines[5].contains("56%"))
    }

    @Test("long period label is truncated to 30 chars")
    func testLongLabelTruncated() {
        let longLabel = String(repeating: "A", count: 50)
        let history: [[String: Any]] = [
            ["period_label": longLabel, "message_tokens": 1, "duration_tokens": 2, "total_tokens": 3]
        ]

        let output = UsageHistoryFormatter.format(history)
        let lastLine = output.components(separatedBy: "\n").last!
        // The label column should be exactly 30 chars before the double-space separator
        let labelPart = String(lastLine.prefix(30))
        #expect(labelPart == String(repeating: "A", count: 30))
        // Should still contain percentages after the truncated label
        #expect(lastLine.contains("%"))
    }
}
