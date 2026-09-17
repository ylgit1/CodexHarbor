import CryptoKit
import Foundation

public struct TunnelClientInstallResult: Equatable, Sendable {
    public let version: String
    public let executableURL: URL
    public let archiveDigest: String

    public init(version: String, executableURL: URL, archiveDigest: String) {
        self.version = version
        self.executableURL = executableURL
        self.archiveDigest = archiveDigest
    }
}

public struct TunnelClientInstaller: Sendable {
    private static let latestReleaseURL = URL(string: "https://api.github.com/repos/openai/tunnel-client/releases/latest")!

    public init() {}

    public func installLatest(paths: BridgePaths) async throws -> TunnelClientInstallResult {
        try paths.ensureDirectories()
        let release = try await fetchLatestRelease()
        guard let asset = Self.selectRuntimeAsset(from: release.assets) else {
            throw BridgeError.writeFailed("OpenAI tunnel-client 最新版本没有当前 Mac 架构的 runtime 安装包")
        }
        guard let expectedDigest = Self.normalizedSHA256(asset.digest) else {
            throw BridgeError.writeFailed("官方 release 未提供可验证的 SHA-256 digest，已停止安装")
        }

        var request = URLRequest(url: asset.browserDownloadURL)
        request.setValue("CodexHarbor/0.1", forHTTPHeaderField: "User-Agent")
        let (archiveData, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw BridgeError.writeFailed("下载 tunnel-client 失败")
        }

        let actualDigest = SHA256.hash(data: archiveData).map { String(format: "%02x", $0) }.joined()
        guard actualDigest == expectedDigest else {
            throw BridgeError.writeFailed("tunnel-client SHA-256 校验失败，已拒绝安装")
        }

        let downloads = paths.root.appendingPathComponent("downloads", isDirectory: true)
        let binaries = paths.root.appendingPathComponent("bin", isDirectory: true)
        let installDirectory = binaries.appendingPathComponent(release.tagName, isDirectory: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: binaries, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: installDirectory.path) {
            try FileManager.default.removeItem(at: installDirectory)
        }
        try FileManager.default.createDirectory(at: installDirectory, withIntermediateDirectories: true)

        let archiveURL = downloads.appendingPathComponent(asset.name)
        try archiveData.write(to: archiveURL, options: .atomic)
        try Self.expandArchive(archiveURL, to: installDirectory)

        guard let executable = Self.findRuntimeExecutable(in: installDirectory) else {
            throw BridgeError.writeFailed("安装包中没有找到 tunnel-client runtime 可执行文件")
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        return TunnelClientInstallResult(
            version: release.tagName,
            executableURL: executable,
            archiveDigest: actualDigest
        )
    }

    private func fetchLatestRelease() async throws -> ReleaseResponse {
        var request = URLRequest(url: Self.latestReleaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("CodexHarbor/0.1", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw BridgeError.writeFailed("无法读取 OpenAI tunnel-client 最新版本信息")
        }
        return try JSONDecoder().decode(ReleaseResponse.self, from: data)
    }

    fileprivate static func selectRuntimeAsset(from assets: [ReleaseAsset]) -> ReleaseAsset? {
        #if arch(arm64)
        let platformSuffix = "darwin-arm64.zip"
        #elseif arch(x86_64)
        let platformSuffix = "darwin-amd64.zip"
        #else
        return nil
        #endif

        if let runtime = assets.first(where: {
            $0.name.hasPrefix("tunnel-client-runtime-v")
                && !$0.name.contains("cloudflared")
                && $0.name.hasSuffix(platformSuffix)
        }) {
            return runtime
        }
        return assets.first(where: {
            $0.name.hasPrefix("tunnel-client-v") && $0.name.hasSuffix(platformSuffix)
        })
    }

    private static func normalizedSHA256(_ digest: String?) -> String? {
        guard let digest else { return nil }
        let value = digest.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.hasPrefix("sha256:") else { return nil }
        let hash = String(value.dropFirst("sha256:".count))
        guard hash.count == 64, hash.allSatisfy({ $0.isHexDigit }) else { return nil }
        return hash
    }

    private static func expandArchive(_ archive: URL, to directory: URL) throws {
        let process = Process()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, directory.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "unknown error"
            throw BridgeError.writeFailed("解压 tunnel-client 失败：\(detail.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    private static func findRuntimeExecutable(in directory: URL) -> URL? {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        let acceptedNames = Set(["tunnel-client-runtime", "tunnel-client"])
        for case let url as URL in enumerator {
            guard acceptedNames.contains(url.lastPathComponent) else { continue }
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                return url
            }
        }
        return nil
    }
}

fileprivate struct ReleaseResponse: Decodable, Sendable {
    let tagName: String
    let assets: [ReleaseAsset]

    private enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case assets
    }
}

fileprivate struct ReleaseAsset: Decodable, Equatable, Sendable {
    let name: String
    let browserDownloadURL: URL
    let digest: String?

    private enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
        case digest
    }
}
