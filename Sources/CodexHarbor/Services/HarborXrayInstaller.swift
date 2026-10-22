import CodexHarborCore
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

    static func installBundled(into root: URL, source: URL? = nil) throws -> Installed {
        let fm = FileManager.default
        let source = try source ?? bundledSource()
        let staging = root.deletingLastPathComponent()
            .appendingPathComponent(".xray-install-\(UUID().uuidString)", isDirectory: true)
        let backup = staging.appendingPathComponent("previous", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

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
        let versionOutput = try command(stagedXray.path, ["version"])
        guard let versionLine = versionOutput.split(separator: "\n").first else {
            throw HarborProxyError.invalid("安装包中的 Xray 无法运行")
        }

        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.createDirectory(at: backup, withIntermediateDirectories: true)
        var installed: [String] = []
        do {
            for name in names {
                let destination = root.appendingPathComponent(name)
                if fm.fileExists(atPath: destination.path) {
                    try fm.moveItem(at: destination, to: backup.appendingPathComponent(name))
                }
            }
            for name in names {
                try fm.moveItem(at: staging.appendingPathComponent(name),
                                to: root.appendingPathComponent(name))
                installed.append(name)
            }
        } catch {
            for name in installed { try? fm.removeItem(at: root.appendingPathComponent(name)) }
            for name in names {
                let previous = backup.appendingPathComponent(name)
                if fm.fileExists(atPath: previous.path) {
                    try? fm.moveItem(at: previous, to: root.appendingPathComponent(name))
                }
            }
            throw error
        }
        return Installed(version: String(versionLine))
    }

    @discardableResult
    private static func command(_ path: String, _ args: [String]) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let result = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            let reason = result.trimmingCharacters(in: .whitespacesAndNewlines)
            let message = reason.isEmpty ? "无详细信息" : String(reason.prefix(200))
            throw HarborProxyError.invalid(
                "内置 Xray 无法运行（退出码 \(process.terminationStatus)）：\(message)"
            )
        }
        return result
    }
}
