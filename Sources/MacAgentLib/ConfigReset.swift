#if os(macOS)
import Foundation

public struct ConfigReset {
    public let configDir: String
    public let preserve: Set<String>

    public init(configDir: String, preserve: Set<String>) {
        self.configDir = configDir
        self.preserve = preserve
    }

    /// Delete all files (not subdirs) from configDir, preserving files named in `self.preserve`.
    /// Returns the number of files deleted.
    public func deleteAll() throws -> Int {
        let fm = FileManager.default

        guard fm.fileExists(atPath: configDir) else {
            throw ConfigResetError.configDirNotFound(configDir)
        }

        let contents = try fm.contentsOfDirectory(atPath: configDir)
        var count = 0
        for name in contents {
            if self.preserve.contains(name) { continue }
            let path = configDir + "/" + name
            let attrs = try fm.attributesOfItem(atPath: path)
            let fileType = attrs[.type] as? FileAttributeType
            if fileType == .typeDirectory { continue }
            try fm.removeItem(atPath: path)
            count += 1
        }
        return count
    }
}

public enum ConfigResetError: Error, LocalizedError {
    case configDirNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .configDirNotFound(let path):
            return "Config directory not found: \(path)"
        }
    }
}
#endif
