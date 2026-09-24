import Foundation

/// Removes only artifacts created or managed locally by Codex Harbor.
/// Remote OpenAI tunnels, Cloudflare tunnels, DNS records and user files are
/// deliberately left untouched.
public struct BridgeTransportArtifactCleaner {
    private let fileManager: FileManager
    private let homeDirectory: URL

    public init(
        fileManager: FileManager = .default,
        homeDirectory: URL? = nil
    ) {
        self.fileManager = fileManager
        self.homeDirectory = homeDirectory ?? fileManager.homeDirectoryForCurrentUser
    }

    public func removeArtifacts(
        for mode: BridgeTransportMode,
        configuration: BridgeConfiguration,
        paths: BridgePaths
    ) throws {
        switch mode {
        case .secureTunnel:
            try removeSecureTunnelArtifacts(configuration: configuration, paths: paths)
        case .httpsCompatibility:
            try removeHTTPSArtifacts(configuration: configuration, paths: paths)
        }
    }

    private func removeSecureTunnelArtifacts(
        configuration: BridgeConfiguration,
        paths: BridgePaths
    ) throws {
        if let executablePath = configuration.secureTunnel?.executablePath {
            let executable = URL(fileURLWithPath: executablePath).standardizedFileURL
            let managedBin = paths.root.appendingPathComponent("bin", isDirectory: true).standardizedFileURL
            if isInside(executable, directory: managedBin),
               executable.lastPathComponent.contains("tunnel-client") {
                let installDirectory = executable.deletingLastPathComponent()
                try removeIfPresent(installDirectory == managedBin ? executable : installDirectory)
            }
        }

        let downloads = paths.root.appendingPathComponent("downloads", isDirectory: true)
        try removeChildren(in: downloads) { item in
            item.lastPathComponent.hasPrefix("tunnel-client-")
        }

        for name in ["tunnel-health.url", "tunnel.pid", "tunnel-client.log"] {
            try removeIfPresent(paths.root.appendingPathComponent(name))
        }
    }

    private func removeHTTPSArtifacts(
        configuration: BridgeConfiguration,
        paths: BridgePaths
    ) throws {
        try removeIfPresent(paths.root.appendingPathComponent("bin/cloudflared", isDirectory: true))
        try removeIfPresent(paths.root.appendingPathComponent("downloads/cloudflared", isDirectory: true))
        try removeChildren(in: paths.root.appendingPathComponent("downloads", isDirectory: true)) { item in
            item.lastPathComponent.hasPrefix("cloudflared-staging-")
        }
        try removeIfPresent(paths.root.appendingPathComponent("https-compat", isDirectory: true))
        try removeIfPresent(paths.logsDirectory.appendingPathComponent("https-compat-cloudflared.log"))

        let cloudflareHome = homeDirectory
            .appendingPathComponent(".cloudflared", isDirectory: true)
            .standardizedFileURL
        if let credentialsPath = configuration.httpsCompatibility?.credentialsFilePath {
            let credentials = URL(fileURLWithPath: credentialsPath).standardizedFileURL
            if isInside(credentials, directory: cloudflareHome) {
                try removeIfPresent(credentials)
            }
        }

        // ~/.cloudflared/cert.pem is user-scoped and may be shared by
        // unrelated Cloudflare workflows. Never remove it from Codex Harbor.
    }

    private func removeChildren(
        in directory: URL,
        matching predicate: (URL) -> Bool
    ) throws {
        guard fileManager.fileExists(atPath: directory.path) else { return }
        for item in try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) where predicate(item) {
            try removeIfPresent(item)
        }
    }

    private func removeIfPresent(_ url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    private func isInside(_ item: URL, directory: URL) -> Bool {
        let itemPath = item.standardizedFileURL.path
        let directoryPath = directory.standardizedFileURL.path
        return itemPath == directoryPath || itemPath.hasPrefix(directoryPath + "/")
    }
}
