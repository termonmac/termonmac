import Foundation
import RemoteDevCore

#if os(macOS)
/// Persists pipeline configuration to `~/.config/termonmac/pipeline.json`.
final class PipelineConfigStore {
    private let configDir: String
    private let configPath: String
    private var config: PipelineConfig

    init() {
        let home = NSString("~/.config/termonmac").expandingTildeInPath
        configDir = home
        configPath = home + "/pipeline.json"
        config = .default
        load()
    }

    // MARK: - Public API

    var current: PipelineConfig { config }

    func applyUpdate(_ newConfig: PipelineConfig) {
        config = newConfig
        save()
        log("[pipeline] config updated — \(config.steps.count) steps")
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: configPath)),
              let loaded = try? JSONDecoder().decode(PipelineConfig.self, from: data) else {
            // First run: write defaults
            save()
            return
        }
        config = loaded
    }

    private func save() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: configDir) {
            try? fm.createDirectory(atPath: configDir, withIntermediateDirectories: true)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(config) else { return }
        do {
            try data.write(to: URL(fileURLWithPath: configPath), options: .atomic)
        } catch {
            log("[pipeline] WARNING: failed to save pipeline.json: \(error.localizedDescription)")
        }
    }
}
#endif
