import Foundation
import RemoteDevCore

#if os(macOS)
/// Persists pipeline execution state to `~/.config/termonmac/pipeline_state.json`.
final class PipelineStateStore {
    private let configDir: String
    private let configPath: String

    init() {
        let home = NSString("~/.config/termonmac").expandingTildeInPath
        configDir = home
        configPath = home + "/pipeline_state.json"
    }

    // MARK: - Public API

    var current: PipelineState? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: configPath)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(PipelineState.self, from: data)
    }

    func update(_ state: PipelineState) {
        let fm = FileManager.default
        if !fm.fileExists(atPath: configDir) {
            try? fm.createDirectory(atPath: configDir, withIntermediateDirectories: true)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(state) else { return }
        do {
            try data.write(to: URL(fileURLWithPath: configPath), options: .atomic)
        } catch {
            log("[pipeline] WARNING: failed to save pipeline_state.json: \(error.localizedDescription)")
        }
    }
}
#endif
