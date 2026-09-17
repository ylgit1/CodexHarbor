import Foundation

public struct BridgeConfigurationStore: Sendable {
    public let paths: BridgePaths

    public init(paths: BridgePaths) {
        self.paths = paths
    }

    public func load() throws -> BridgeConfiguration {
        try paths.ensureDirectories()
        guard FileManager.default.fileExists(atPath: paths.configurationURL.path) else {
            return BridgeConfiguration()
        }
        let data = try Data(contentsOf: paths.configurationURL)
        return try JSONDecoder().decode(BridgeConfiguration.self, from: data)
    }

    public func save(_ configuration: BridgeConfiguration) throws {
        try paths.ensureDirectories()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(configuration)
        try data.write(to: paths.configurationURL, options: .atomic)
    }
}
