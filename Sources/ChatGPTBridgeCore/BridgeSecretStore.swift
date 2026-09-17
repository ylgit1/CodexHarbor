import Foundation
import Security

public enum BridgeSecretKey: String, Sendable {
    case tunnelRuntimeAPIKey = "secure-tunnel-runtime-api-key"
    case localMCPAccessToken = "local-mcp-access-token"
}

public struct BridgeSecretStore: Sendable {
    public static let service = "com.codexharbor.chatgptbridge"

    public init() {}

    public func set(_ value: String, for key: BridgeSecretKey) throws {
        let data = Data(value.utf8)
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: key.rawValue
        ]

        let updateAttributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, updateAttributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw BridgeError.writeFailed("Keychain 更新失败（\(updateStatus)）")
        }

        var addQuery = baseQuery
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw BridgeError.writeFailed("Keychain 保存失败（\(addStatus)）")
        }
    }

    public func string(for key: BridgeSecretKey) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: key.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw BridgeError.writeFailed("Keychain 读取失败（\(status)）")
        }
        return String(data: data, encoding: .utf8)
    }

    public func localMCPAccessToken() throws -> String {
        if let existing = try string(for: .localMCPAccessToken), !existing.isEmpty {
            return existing
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = bytes.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return errSecAllocate }
            return SecRandomCopyBytes(kSecRandomDefault, buffer.count, baseAddress)
        }
        guard status == errSecSuccess else {
            throw BridgeError.writeFailed("本地 MCP 访问令牌生成失败（\(status)）")
        }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        try set(token, for: .localMCPAccessToken)
        return token
    }

    public func remove(_ key: BridgeSecretKey) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: key.rawValue
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw BridgeError.writeFailed("Keychain 删除失败（\(status)）")
        }
    }
}
