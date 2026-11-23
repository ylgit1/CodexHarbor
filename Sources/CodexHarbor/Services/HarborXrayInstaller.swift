import CodexHarborCore
import Darwin
import Foundation

/// Copies the Xray runtime shipped inside Codex Harbor into the app-owned
/// writable directory. This path performs no network requests.
struct HarborXrayInstaller {
    struct Installed: Sendable {
        let version: String
    }

    private static let names = ["xray", "geoip.dat", "geosite.dat"]

    static func bundledSource(bundle: Bundle = .main) throws -> URL {
        #if arch(arm64)
        let architecture = "arm64"
        #elseif arch(x86_64)
        let architecture = "x86_64"
        #else
        throw HarborProxyError.invalid("当前 Mac CPU 架构没有对应的内置 Xray")
        #endif
        let source = bundle.bundleURL
            .appendingPathComponent("Contents/Resources/Xray", isDirectory: true)
            .appendingPathComponent(architecture, isDirectory: true)
        guard names.allSatisfy({ FileManager.default.fileExists(
            atPath: source.appendingPathComponent($0).path
        ) }) else {
            throw HarborProxyError.invalid("安装包缺少适合本机架构的 Xray 内置资源")
        }
        return source
    }

    static func matchesBundle(at root: URL, source: URL) -> Bool {
        let fm = FileManager.default
        return fm.isExecutableFile(atPath: root.appendingPathComponent("xray").path) && names.allSatisfy {
            fm.contentsEqual(atPath: source.appendingPathComponent($0).path,
                             andPath: root.appendingPathComponent($0).path)
        }
    }

    static func installBundled(into root: URL, source: URL? = nil) throws -> Installed {
        let fm = FileManager.default
        let source = try source ?? bundledSource()
        let staging = root.deletingLastPathComponent()
            .appendingPathComponent(".xray-install-\(UUID().uuidString)", isDirectory: true)
        let backup = staging.appendingPathComponent("previous", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        var keepBackup = false
        defer { if !keepBackup { try? fm.removeItem(at: staging) } }

        for name in names {
            let item = source.appendingPathComponent(name)
            let values = try item.resourceValues(forKeys: [
                .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey
            ])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  (values.fileSize ?? 0) > 1024 else {
                throw HarborProxyError.invalid("安装包中的 \(name) 无效")
            }
            try fm.copyItem(at: item, to: staging.appendingPathComponent(name))
        }

        let stagedXray = staging.appendingPathComponent("xray")
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stagedXray.path)
        // Running the binary verifies that macOS can execute its architecture.
        // Do not call /usr/bin/lipo here: on a clean macOS install it is an
        // Xcode Command Line Tools shim and fails even for a valid arm64 Xray.
        // The bundle path already selects the architecture at packaging time.
        let version = try HarborProxyCommand.runBlocking(stagedXray, arguments: ["version"], timeout: 5)
        guard version.status == 0, let versionLine = String(decoding: version.data, as: UTF8.self)
            .split(separator: "\n").first, versionLine.hasPrefix("Xray ") else {
            throw HarborProxyError.invalid("安装包中的 Xray 无法运行")
        }
        let check = staging.appendingPathComponent("check.json")
        try Data(#"{"inbounds":[],"outbounds":[{"tag":"direct","protocol":"freedom"}],"routing":{"rules":[{"type":"field","domain":["geosite:cn"],"outboundTag":"direct"},{"type":"field","ip":["geoip:cn"],"outboundTag":"direct"}]}}"#.utf8).write(to: check)
        let validation = try HarborProxyCommand.runBlocking(
            stagedXray, arguments: ["run", "-test", "-config", check.path], timeout: 8, outputLimit: 16_384,
            environment: ProcessInfo.processInfo.environment.merging(["XRAY_LOCATION_ASSET": staging.path]) { _, new in new }
        )
        guard validation.status == 0 else {
            throw HarborProxyError.invalid("安装包中的 Xray 地区资源未通过校验")
        }

        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.createDirectory(at: backup, withIntermediateDirectories: true)
        var installed: [String] = []
        do {
            for name in names {
                let destination = root.appendingPathComponent(name)
                if fm.fileExists(atPath: destination.path) {
                    try fm.linkItem(at: destination, to: backup.appendingPathComponent(name))
                }
            }
            for name in names {
                try replace(staging.appendingPathComponent(name), at: root.appendingPathComponent(name))
                installed.append(name)
            }
        } catch {
            for name in installed.reversed() {
                let previous = backup.appendingPathComponent(name)
                let destination = root.appendingPathComponent(name)
                do {
                    if fm.fileExists(atPath: previous.path) { try replace(previous, at: destination) }
                    else { try fm.removeItem(at: destination) }
                } catch {
                    keepBackup = true
                }
            }
            throw error
        }
        return Installed(version: String(versionLine))
    }

    static func replace(_ staged: URL, at destination: URL) throws {
        guard Darwin.rename(staged.path, destination.path) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
    }
}
