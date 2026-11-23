import CodexHarborCore
import Foundation

/// The OpenVPN runtime is shipped with the app so a fresh Mac does not need
/// Homebrew, Go, a VPN profile import, or a network download to use it.
struct HarborMihomoInstaller {
    static func bundledSource(bundle: Bundle = .main) throws -> URL {
        #if arch(arm64)
        let architecture = "arm64"
        #elseif arch(x86_64)
        let architecture = "x86_64"
        #else
        throw HarborProxyError.invalid("当前 Mac CPU 架构没有对应的 Mihomo 内核")
        #endif
        let path = bundle.bundleURL
            .appendingPathComponent("Contents/Resources/Mihomo")
            .appendingPathComponent(architecture)
            .appendingPathComponent("mihomo")
        guard FileManager.default.isExecutableFile(atPath: path.path) else {
            throw HarborProxyError.invalid("安装包缺少适合本机架构的 Mihomo 内核")
        }
        return path
    }

    static func installBundled(into root: URL, source: URL? = nil) throws {
        let source = try source ?? bundledSource()
        let destination = root.appendingPathComponent("mihomo")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let staged = root.appendingPathComponent(".mihomo-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staged) }
        try FileManager.default.copyItem(at: source, to: staged)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: staged.path)
        let result = try HarborProxyCommand.runBlocking(staged, arguments: ["-v"], timeout: 5)
        guard result.status == 0, String(decoding: result.data, as: UTF8.self).hasPrefix("Mihomo ") else {
            throw HarborProxyError.invalid("内置 Mihomo 无法在本机运行")
        }
        try HarborXrayInstaller.replace(staged, at: destination)
    }

    static func matchesBundle(at root: URL, source: URL) -> Bool {
        let path = root.appendingPathComponent("mihomo").path
        return FileManager.default.isExecutableFile(atPath: path)
            && FileManager.default.contentsEqual(atPath: source.path, andPath: path)
    }

    static func dataDirectory(root: URL) -> URL {
        root.appendingPathComponent("mihomo-data", isDirectory: true)
    }

    /// Mihomo expects different geodata filenames than Xray. Share the
    /// packaged assets even on case-sensitive volumes, without fetching updates.
    static func prepareDataDirectory(root: URL) throws {
        let directory = dataDirectory(root: root)
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        for (name, asset) in [("GeoIP.dat", "geoip.dat"), ("GeoSite.dat", "geosite.dat")] {
            let link = directory.appendingPathComponent(name)
            let target = "../\(asset)"
            guard (try? fm.destinationOfSymbolicLink(atPath: link.path)) != target else { continue }
            let staged = directory.appendingPathComponent(".geo-\(UUID().uuidString)")
            defer { try? fm.removeItem(at: staged) }
            try fm.createSymbolicLink(atPath: staged.path, withDestinationPath: target)
            try HarborXrayInstaller.replace(staged, at: link)
        }
    }
}
