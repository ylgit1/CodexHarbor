import Foundation
import Security

public enum BridgeSecretKey: String, Sendable {
    case tunnelRuntimeAPIKey = "secure-tunnel-runtime-api-key"
    case localMCPAccessToken = "local-mcp-access-token"
    case httpsCompatibilityAccessToken = "https-compatibility-access-token"
    case cloudflareZoneAPIToken = "cloudflare-zone-api-token"
}

/// Harbor-owned local credential vault. It deliberately avoids Keychain so an
/// independently launched Agent does not request authorization whenever the
/// app is rebuilt or re-signed. The file is atomic and readable only by the
/// current macOS user.
public final class BridgeSecretStore: @unchecked Sendable {
    private struct Vault: Codable {
        var version = 1
        var values: [String: String] = [:]
    }

    private let url: URL
    private let fileManager: FileManager
    private let lock = NSLock()

    public init(url: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        if let url {
            self.url = url
        } else if let paths = try? BridgePaths.live(fileManager: fileManager) {
            self.url = paths.credentialsURL
        } else {
            self.url = fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/CodexHarbor/ChatGPTBridge/credentials.json")
        }
    }

    public func set(_ value: String, for key: BridgeSecretKey) throws {
        lock.lock()
        defer { lock.unlock() }
        var vault = try load()
        let encoded = Data(value.utf8).base64EncodedString()
        vault.values[key.rawValue] = encoded
        try persist(vault)
        guard try load().values[key.rawValue] == encoded else {
            throw BridgeError.writeFailed("本地凭据保存后校验失败")
        }
    }

    public func string(for key: BridgeSecretKey) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let encoded = try load().values[key.rawValue],
              let data = Data(base64Encoded: encoded) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func localMCPAccessToken() throws -> String {
        try generatedToken(for: .localMCPAccessToken, label: "本地 MCP")
    }

    public func httpsCompatibilityAccessToken() throws -> String {
        try generatedToken(for: .httpsCompatibilityAccessToken, label: "公网 HTTPS")
    }

    public func remove(_ key: BridgeSecretKey) throws {
        lock.lock()
        defer { lock.unlock() }
        var vault = try load()
        vault.values.removeValue(forKey: key.rawValue)
        try persist(vault)
    }

    private func generatedToken(for key: BridgeSecretKey, label: String) throws -> String {
        lock.lock()
        defer { lock.unlock() }
        var vault = try load()
        if let encoded = vault.values[key.rawValue],
           let data = Data(base64Encoded: encoded),
           let existing = String(data: data, encoding: .utf8),
           !existing.isEmpty {
            return existing
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = bytes.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return errSecAllocate }
            return SecRandomCopyBytes(kSecRandomDefault, buffer.count, baseAddress)
        }
        guard status == errSecSuccess else {
            throw BridgeError.writeFailed("\(label) 访问令牌生成失败（\(status)）")
        }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        vault.values[key.rawValue] = Data(token.utf8).base64EncodedString()
        try persist(vault)
        return token
    }

    private func load() throws -> Vault {
        guard fileManager.fileExists(atPath: url.path) else { return Vault() }
        return try JSONDecoder().decode(Vault.self, from: Data(contentsOf: url))
    }

    private func persist(_ vault: Vault) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(vault).write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
