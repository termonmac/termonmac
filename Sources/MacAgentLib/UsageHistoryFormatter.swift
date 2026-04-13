import Foundation

public enum UsageHistoryFormatter {
    public static func format(_ history: [[String: Any]]) -> String {
        var lines: [String] = []
        lines.append("Usage History (breakdown)")
        lines.append("───────────────────────────────────────────")
        lines.append("\("Period".padding(toLength: 30, withPad: " ", startingAt: 0))  \("Msgs".padding(toLength: 6, withPad: " ", startingAt: 0))  \("Dur".padding(toLength: 6, withPad: " ", startingAt: 0))")
        lines.append("───────────────────────────────────────────")

        for item in history {
            let label = (item["period_label"] as? String) ?? (item["period"] as? String) ?? "?"
            let msg = item["message_tokens"] as? Int ?? 0
            let total = item["total_tokens"] as? Int ?? 0
            let msgPct = total > 0 ? min(100, max(0, Int(Double(msg) / Double(total) * 100))) : 0
            let durPct = total > 0 ? max(0, 100 - msgPct) : 0
            let msgStr = "\(msgPct)%".padding(toLength: 6, withPad: " ", startingAt: 0)
            let durStr = "\(durPct)%".padding(toLength: 6, withPad: " ", startingAt: 0)
            lines.append("\(label.padding(toLength: 30, withPad: " ", startingAt: 0))  \(msgStr)  \(durStr)")
        }
        return lines.joined(separator: "\n")
    }
}
