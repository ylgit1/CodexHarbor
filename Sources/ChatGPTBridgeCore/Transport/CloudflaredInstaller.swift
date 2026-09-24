import CryptoKit
import Foundation

public struct CloudflaredInstallResult: Equatable, Sendable {
    public let version: String
    public let executableURL: URL
    public let archiveDigest: String

    public init(version: String, executableURL: URL, archiveDigest: String) {
        self.version = version
        self.executableURL = executableURL
        self.archiveDigest = archiveDigest
    }
}

public struct CloudflaredInstaller: Sendable {
    static let latestReleaseURL = URL(string: "https://api.github.com/repos/cloudflare/cloudflared/releases/latest")!

    public init() {}

    public func installLatest(paths: BridgePaths) async throws -> CloudflaredInstallResult {
        try paths.ensureDirectories()
        let release = try await fetchLatestRelease()
        guard let asset = Self.selectDarwinAsset(from: release.assets) else {
            throw BridgeError.writeFailed("Cloudflare cloudflared 最新版本没有当前 Mac 架构的安装包")
        }

        let expectedDigest = Self.normalizedSHA256(asset.digest)
            ?? Self.checksum(for: asset.name, in: release.body)
        guard let expectedDigest else {
            throw BridgeError.writeFailed("Cloudflare 官方 release 未提供可验证的 SHA-256 checksum，已停止安装")
        }

        var request = URLRequest(url: asset.browserDownloadURL)
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        request.setValue("CodexHarbor/0.1", forHTTPHeaderField: "User-Agent")
        let (archiveData, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw BridgeError.writeFailed("下载 cloudflared 失败")
        }

        let actualDigest = SHA256.hash(data: archiveData)
            .map { String(format: "%02x", $0) }
            .joined()
        guard actualDigest == expectedDigest else {
            throw BridgeError.writeFailed("cloudflared SHA-256 校验失败，已拒绝安装")
        }

        let downloads = paths.root.appendingPathComponent("downloads/cloudflared", isDirectory: true)
        let installDirectory = paths.root.appendingPathComponent("bin/cloudflared", isDirectory: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: installDirectory, withIntermediateDirectories: true)

        let archiveURL = downloads.appendingPathComponent(asset.name)
        try archiveData.write(to: archiveURL, options: .atomic)

        let stagingDirectory = paths.root
            .appendingPathComponent("downloads/cloudflared-staging-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stagingDirectory) }

        try Self.expandArchive(archiveURL, to: stagingDirectory)
        guard let extractedExecutable = Self.findExecutable(in: stagingDirectory) else {
            throw BridgeError.writeFailed("cloudflared 安装包中没有找到可执行文件")
        }

        let executableURL = installDirectory.appendingPathComponent("cloudflared")
        if FileManager.default.fileExists(atPath: executableURL.path) {
            try FileManager.default.removeItem(at: executableURL)
        }
        try FileManager.default.copyItem(at: extractedExecutable, to: executableURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)
        try Self.verifyExecutable(executableURL)

        let versionURL = installDirectory.appendingPathComponent("version")
        try Data(release.tagName.utf8).write(to: versionURL, options: .atomic)

        return CloudflaredInstallResult(
            version: release.tagName,
            executableURL: executableURL,
            archiveDigest: actualDigest
        )
    }

    private func fetchLatestRelease() async throws -> CloudflaredReleaseResponse {
        var request = URLRequest(url: Self.latestReleaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("CodexHarbor/0.1", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw BridgeError.writeFailed("无法读取 Cloudflare cloudflared 最新版本信息")
        }
        do {
            return try JSONDecoder().decode(CloudflaredReleaseResponse.self, from: data)
        } catch {
            throw BridgeError.writeFailed("无法解析 Cloudflare cloudflared 版本信息：\(error.localizedDescription)")
        }
    }

    static func selectDarwinAsset(from assets: [CloudflaredReleaseAsset]) -> CloudflaredReleaseAsset? {
        #if arch(arm64)
        let name = "cloudflared-darwin-arm64.tgz"
        #elseif arch(x86_64)
        let name = "cloudflared-darwin-amd64.tgz"
        #else
        return nil
        #endif
        return assets.first { $0.name == name }
    }

    static func normalizedSHA256(_ digest: String?) -> String? {
        guard let digest else { return nil }
        let value = digest.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let hash = value.hasPrefix("sha256:") ? String(value.dropFirst("sha256:".count)) : value
        guard hash.count == 64, hash.allSatisfy({ $0.isHexDigit }) else { return nil }
        return hash
    }

    static func checksum(for assetName: String, in releaseBody: String?) -> String? {
        guard let releaseBody else { return nil }
        for rawLine in releaseBody.components(separatedBy: .newlines) {
            let line = rawLine
                .replacingOccurrences(of: "\u{0060}", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("\(assetName):") else { continue }
            let value = line.dropFirst(assetName.count + 1)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let normalized = normalizedSHA256(value) {
                return normalized
            }
        }
        return nil
    }

    private static func expandArchive(_ archive: URL, to directory: URL) throws {
        let process = Process()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xzf", archive.path, "-C", directory.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(
                decoding: stderr.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            throw BridgeError.writeFailed("解压 cloudflared 失败：\(detail)")
        }
    }

    private static func findExecutable(in directory: URL) -> URL? {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        for case let url as URL in enumerator {
            guard url.lastPathComponent == "cloudflared" else { continue }
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                return url
            }
        }
        return nil
    }

    private static func verifyExecutable(_ executable: URL) throws {
        let process = Process()
        let stderr = Pipe()
        process.executableURL = executable
        process.arguments = ["--version"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(
                decoding: stderr.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            throw BridgeError.writeFailed("cloudflared 安装后校验失败：\(detail)")
        }
    }
}

struct CloudflaredReleaseResponse: Decodable, Sendable {
    let tagName: String
    let body: String?
    let assets: [CloudflaredReleaseAsset]

    private enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case body
        case assets
    }
}

struct CloudflaredReleaseAsset: Decodable, Equatable, Sendable {
    let name: String
    let browserDownloadURL: URL
    let digest: String?

    private enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
        case digest
    }
}
