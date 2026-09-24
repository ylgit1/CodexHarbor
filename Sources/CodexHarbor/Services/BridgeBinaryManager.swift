import ChatGPTBridgeCore
import Foundation

struct BridgeBinaryResolution: Sendable {
    let executableURL: URL
    let installedVersion: String?
}

struct BridgeBinaryManager: Sendable {
    private let paths: BridgePaths

    init(paths: BridgePaths) {
        self.paths = paths
    }

    func locateTunnelClient(preferredPath: String?) -> URL? {
        if let preferred = executableURL(at: preferredPath) {
            return preferred
        }

        let bin = paths.root.appendingPathComponent("bin", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: bin,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        let acceptedNames = Set(["tunnel-client-runtime", "tunnel-client"])
        for case let candidate as URL in enumerator {
            guard acceptedNames.contains(candidate.lastPathComponent),
                  FileManager.default.isExecutableFile(atPath: candidate.path) else {
                continue
            }
            return candidate
        }
        return nil
    }

    func installTunnelClient() async throws -> TunnelClientInstallResult {
        try await TunnelClientInstaller().installLatest(paths: paths)
    }

    func locateCloudflared(preferredPath: String?) -> URL? {
        if let preferred = executableURL(at: preferredPath) {
            return preferred
        }
        let managed = paths.root.appendingPathComponent("bin/cloudflared/cloudflared")
        guard FileManager.default.isExecutableFile(atPath: managed.path) else {
            return nil
        }
        return managed
    }

    func ensureCloudflared(preferredPath: String?) async throws -> BridgeBinaryResolution {
        if let existing = locateCloudflared(preferredPath: preferredPath) {
            return BridgeBinaryResolution(
                executableURL: existing,
                installedVersion: nil
            )
        }

        let installed = try await CloudflaredInstaller().installLatest(paths: paths)
        return BridgeBinaryResolution(
            executableURL: installed.executableURL,
            installedVersion: installed.version
        )
    }

    private func executableURL(at path: String?) -> URL? {
        guard let path = path?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty,
              FileManager.default.isExecutableFile(atPath: path) else {
            return nil
        }
        return URL(fileURLWithPath: path)
    }
}
