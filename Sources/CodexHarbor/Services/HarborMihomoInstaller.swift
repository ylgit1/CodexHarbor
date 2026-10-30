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
        guard !FileManager.default.fileExists(atPath: destination.path) else { return }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let staged = root.appendingPathComponent(".mihomo-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staged) }
        try FileManager.default.copyItem(at: source, to: staged)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: staged.path)
        let process = Process()
        process.executableURL = staged
        process.arguments = ["-v"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw HarborProxyError.invalid("内置 Mihomo 无法在本机运行")
        }
        try FileManager.default.moveItem(at: staged, to: destination)
    }
}
