import Foundation
import Security

public struct HarborSecret: RawRepresentable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let apiToken = HarborSecret(rawValue: "api-token")
    public static let activationKey = HarborSecret(rawValue: "activation-key")
    public static let deviceIdentifier = HarborSecret(rawValue: "device-identifier")

    public static func profileToken(_ identifier: UUID) -> HarborSecret {
        HarborSecret(rawValue: "profile.\(identifier.uuidString.lowercased()).api-token")
    }

    public static func profileActivationKey(_ identifier: UUID) -> HarborSecret {
        HarborSecret(rawValue: "profile.\(identifier.uuidString.lowercased()).activation-key")
    }

    public static func accountAuthentication(_ identifier: UUID) -> HarborSecret {
        HarborSecret(rawValue: "account.\(identifier.uuidString.lowercased()).authentication")
    }
}

public protocol SecretStore: Sendable {
    func data(for secret: HarborSecret) throws -> Data?
    func set(_ data: Data, for secret: HarborSecret) throws
    func remove(_ secret: HarborSecret) throws
}

public extension SecretStore {
    func string(for secret: HarborSecret) throws -> String? {
        guard let data = try data(for: secret) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func set(_ value: String, for secret: HarborSecret) throws {
        try set(Data(value.utf8), for: secret)
    }
}

public final class KeychainSecretStore: SecretStore, @unchecked Sendable {
    private let service: String

    public init(service: String = "com.codexharbor.credentials") {
        self.service = service
    }

    public func data(for secret: HarborSecret) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: secret.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw HarborError.keychainFailure(status) }
        return result as? Data
    }

    public func set(_ data: Data, for secret: HarborSecret) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: secret.rawValue
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var item = query
            attributes.forEach { item[$0.key] = $0.value }
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw HarborError.keychainFailure(addStatus) }
            return
        }
        guard updateStatus == errSecSuccess else { throw HarborError.keychainFailure(updateStatus) }
    }

    public func remove(_ secret: HarborSecret) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: secret.rawValue
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw HarborError.keychainFailure(status)
        }
    }

    public func allItems() throws -> [HarborSecret: Data] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [:] }
        guard status == errSecSuccess else { throw HarborError.keychainFailure(status) }
        let items = result as? [[String: Any]] ?? []
        return items.reduce(into: [:]) { values, item in
            guard let account = item[kSecAttrAccount as String] as? String,
                  let data = item[kSecValueData as String] as? Data else { return }
            values[HarborSecret(rawValue: account)] = data
        }
    }
}

/// Harbor-owned credential storage. The file is readable only by the current
/// macOS user and is replaced atomically, so the command-line token helper can
/// read it without triggering Keychain authorization dialogs.
public final class LocalSecretStore: SecretStore, @unchecked Sendable {
    private struct Vault: Codable {
        var version = 1
        var values: [String: String] = [:]
    }

    private let url: URL
    private let fileManager: FileManager
    private let lock = NSLock()

    public init(
        url: URL = CodexPaths.live().credentialsURL,
        fileManager: FileManager = .default
    ) {
        self.url = url
        self.fileManager = fileManager
    }

    public static func liveMigratingLegacyKeychain() -> LocalSecretStore {
        let store = LocalSecretStore()
        guard !store.fileManager.fileExists(atPath: store.url.path) else { return store }
        do {
            try store.replace(with: KeychainSecretStore().allItems())
        } catch {
            // Do not ask again on every launch. Existing profile metadata remains
            // visible and the user can re-add a credential that was not migrated.
            try? store.replace(with: [:])
        }
        return store
    }

    public func data(for secret: HarborSecret) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard let encoded = try load().values[secret.rawValue] else { return nil }
        return Data(base64Encoded: encoded)
    }

    public func set(_ data: Data, for secret: HarborSecret) throws {
        lock.lock()
        defer { lock.unlock() }
        var vault = try load()
        vault.values[secret.rawValue] = data.base64EncodedString()
        try persist(vault)
    }

    public func remove(_ secret: HarborSecret) throws {
        lock.lock()
        defer { lock.unlock() }
        var vault = try load()
        vault.values.removeValue(forKey: secret.rawValue)
        try persist(vault)
    }

    private func replace(with values: [HarborSecret: Data]) throws {
        let encoded = values.reduce(into: [String: String]()) {
            $0[$1.key.rawValue] = $1.value.base64EncodedString()
        }
        try persist(Vault(values: encoded))
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
