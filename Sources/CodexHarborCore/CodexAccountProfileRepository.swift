import CryptoKit
import Foundation

public actor CodexAccountProfileRepository {
    private struct Catalog: Codable {
        var selectedProfileID: UUID?
        var profiles: [CodexAccountProfile]
    }

    private let paths: CodexPaths
    private let store: SecretStore
    private let fileManager: FileManager

    public init(
        paths: CodexPaths = .live(),
        store: SecretStore = LocalSecretStore(),
        fileManager: FileManager = .default
    ) {
        self.paths = paths
        self.store = store
        self.fileManager = fileManager
    }

    public func profiles() throws -> [CodexAccountProfile] {
        try load().profiles.sorted { $0.createdAt < $1.createdAt }
    }

    public func selectedProfileID() throws -> UUID? {
        try load().selectedProfileID
    }

    public func credentialHealth(for identifier: UUID, now: Date = Date()) throws -> ConnectionHealth {
        guard let authentication = try store.data(for: .accountAuthentication(identifier)),
              let object = try JSONSerialization.jsonObject(with: authentication) as? [String: Any] else {
            return .unavailable("本地凭据缺失")
        }
        let method = try Self.authenticationMethod(in: authentication)
        if method == .apiKey {
            return .available("本地密钥完整")
        }
        guard method == .chatGPT, let tokens = object["tokens"] as? [String: Any] else {
            return .unavailable("登录凭据无效")
        }
        if (tokens["refresh_token"] as? String)?.isEmpty == false {
            return .available("支持自动续期")
        }
        let expiry = [tokens["access_token"], tokens["id_token"]]
            .compactMap { $0 as? String }
            .compactMap(Self.jwtPayload(in:))
            .compactMap { ($0["exp"] as? NSNumber)?.doubleValue }
            .min()
        if let expiry, Date(timeIntervalSince1970: expiry) <= now {
            return .expired("登录已过期")
        }
        return .available("本地凭据完整")
    }

    public func synchronizeCurrentLoginIfPresent() throws {
        guard fileManager.fileExists(atPath: paths.authURL.path) else { return }
        let authentication = try currentAuthenticationData()
        let method = try Self.authenticationMethod(in: authentication)
        guard method == .chatGPT || method == .apiKey else { return }
        _ = try saveCurrentLogin(name: nil)
    }

    @discardableResult
    public func saveCurrentLogin(name rawName: String?) throws -> CodexAccountProfile {
        let authentication = try currentAuthenticationData()
        return try saveAuthentication(authentication, name: rawName, select: true)
    }

    /// Imports a completed Codex login without touching the live Codex auth file.
    /// This lets callers stage a new login under an isolated CODEX_HOME and only
    /// switch the real account after the staged credentials have been validated.
    @discardableResult
    public func importAuthentication(
        _ authentication: Data,
        name rawName: String?,
        select: Bool = false
    ) throws -> CodexAccountProfile {
        try saveAuthentication(authentication, name: rawName, select: select)
    }

    private func saveAuthentication(
        _ authentication: Data,
        name rawName: String?,
        select: Bool
    ) throws -> CodexAccountProfile {
        let method = try Self.authenticationMethod(in: authentication)
        let fingerprint = try Self.identityFingerprint(in: authentication)
        let detectedName = Self.accountDisplayName(in: authentication, method: method, fingerprint: fingerprint)
        var catalog = try load()
        let trimmedName = rawName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let profile: CodexAccountProfile
        if let index = catalog.profiles.firstIndex(where: { $0.credentialFingerprint == fingerprint }) {
            if !trimmedName.isEmpty {
                catalog.profiles[index].name = trimmedName
            } else if Self.isGeneratedName(catalog.profiles[index].name) {
                catalog.profiles[index].name = detectedName
            }
            catalog.profiles[index].method = method
            catalog.profiles[index].lastUsedAt = Date()
            profile = catalog.profiles[index]
        } else {
            profile = CodexAccountProfile(
                name: trimmedName.isEmpty ? detectedName : trimmedName,
                method: method,
                credentialFingerprint: fingerprint
            )
            catalog.profiles.append(profile)
        }
        try store.set(authentication, for: .accountAuthentication(profile.id))
        if select {
            catalog.selectedProfileID = profile.id
        }
        try persist(catalog)
        return profile
    }

    @discardableResult
    public func switchToProfile(_ identifier: UUID) throws -> CodexAccountProfile {
        var catalog = try load()
        guard let targetIndex = catalog.profiles.firstIndex(where: { $0.id == identifier }),
              let targetAuthentication = try store.data(for: .accountAuthentication(identifier)) else {
            throw HarborError.missingAccountCredentials
        }
        _ = try Self.authenticationMethod(in: targetAuthentication)
        if catalog.selectedProfileID == identifier,
           fileManager.fileExists(atPath: paths.authURL.path),
           try Data(contentsOf: paths.authURL) == targetAuthentication {
            return catalog.profiles[targetIndex]
        }

        let previousAuthentication = fileManager.fileExists(atPath: paths.authURL.path)
            ? try Data(contentsOf: paths.authURL)
            : nil
        let previousPermissions = try currentPermissions()
        if let selectedID = catalog.selectedProfileID,
           catalog.profiles.contains(where: { $0.id == selectedID }),
           let previousAuthentication {
            try store.set(previousAuthentication, for: .accountAuthentication(selectedID))
        }

        do {
            try writeAuthentication(targetAuthentication)
            guard try Data(contentsOf: paths.authURL) == targetAuthentication else {
                throw HarborError.invalidAccountCredentials
            }
            catalog.profiles[targetIndex].lastUsedAt = Date()
            catalog.selectedProfileID = identifier
            try persist(catalog)
            return catalog.profiles[targetIndex]
        } catch {
            if let previousAuthentication {
                try? previousAuthentication.write(to: paths.authURL, options: .atomic)
                try? fileManager.setAttributes(
                    [.posixPermissions: previousPermissions],
                    ofItemAtPath: paths.authURL.path
                )
            } else {
                try? fileManager.removeItem(at: paths.authURL)
            }
            throw error
        }
    }

    public func remove(_ identifier: UUID) throws {
        var catalog = try load()
        guard let index = catalog.profiles.firstIndex(where: { $0.id == identifier }) else { return }
        guard catalog.selectedProfileID != identifier else {
            throw HarborError.invalidConfiguration("不能删除当前正在使用的账户档案")
        }
        catalog.profiles.remove(at: index)
        try store.remove(.accountAuthentication(identifier))
        try persist(catalog)
    }

    private func currentAuthenticationData() throws -> Data {
        guard fileManager.fileExists(atPath: paths.authURL.path) else {
            throw HarborError.missingAccountCredentials
        }
        let data = try Data(contentsOf: paths.authURL)
        _ = try Self.authenticationMethod(in: data)
        return data
    }

    public nonisolated static func authenticationMethod(in data: Data) throws -> CodexAccountMethod {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], !object.isEmpty else {
            throw HarborError.invalidAccountCredentials
        }
        if let apiKey = object["OPENAI_API_KEY"] as? String, !apiKey.isEmpty { return .apiKey }
        if let tokens = object["tokens"] as? [String: Any],
           (tokens["access_token"] as? String)?.isEmpty == false
                || (tokens["id_token"] as? String)?.isEmpty == false {
            return .chatGPT
        }
        return .unknown
    }

    private nonisolated static func identityFingerprint(in data: Data) throws -> String {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HarborError.invalidAccountCredentials
        }
        if let apiKey = object["OPENAI_API_KEY"] as? String {
            return fingerprint(Data("api:\(apiKey)".utf8))
        }
        if let tokens = object["tokens"] as? [String: Any] {
            if let accountID = tokens["account_id"] as? String, !accountID.isEmpty {
                return fingerprint(Data("account:\(accountID)".utf8))
            }
            if let idToken = tokens["id_token"] as? String,
               let subject = jwtSubject(in: idToken) {
                return fingerprint(Data("subject:\(subject)".utf8))
            }
        }
        return fingerprint(data)
    }

    private nonisolated static func jwtSubject(in token: String) -> String? {
        guard let payload = jwtPayload(in: token) else { return nil }
        return (payload["sub"] as? String) ?? (payload["email"] as? String)
    }

    private nonisolated static func jwtPayload(in token: String) -> [String: Any]? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count > 1 else { return nil }
        var encoded = String(parts[1]).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return payload
    }

    private func writeAuthentication(_ data: Data) throws {
        try fileManager.createDirectory(at: paths.codexHome, withIntermediateDirectories: true)
        try data.write(to: paths.authURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.authURL.path)
    }

    private func currentPermissions() throws -> Int {
        guard fileManager.fileExists(atPath: paths.authURL.path) else { return 0o600 }
        let attributes = try fileManager.attributesOfItem(atPath: paths.authURL.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o600
    }

    private func load() throws -> Catalog {
        guard fileManager.fileExists(atPath: paths.accountProfilesURL.path) else {
            return Catalog(selectedProfileID: nil, profiles: [])
        }
        return try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: paths.accountProfilesURL))
    }

    private func persist(_ catalog: Catalog) throws {
        try fileManager.createDirectory(at: paths.appSupport, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(catalog).write(to: paths.accountProfilesURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.accountProfilesURL.path)
    }

    private nonisolated static func accountDisplayName(
        in data: Data,
        method: CodexAccountMethod,
        fingerprint: String
    ) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return stableFallbackName(method: method, fingerprint: fingerprint)
        }
        if method == .apiKey,
           let key = object["OPENAI_API_KEY"] as? String,
           !key.isEmpty {
            return "OpenAI 密钥 ••••\(key.suffix(4))"
        }
        if let tokens = object["tokens"] as? [String: Any] {
            if let idToken = tokens["id_token"] as? String,
               let payload = jwtPayload(in: idToken) {
                let profile = payload["https://api.openai.com/profile"] as? [String: Any]
                if let email = (profile?["email"] as? String) ?? (payload["email"] as? String),
                   !email.isEmpty {
                    return email
                }
                if let name = (profile?["name"] as? String)
                    ?? (payload["name"] as? String)
                    ?? (payload["preferred_username"] as? String),
                   !name.isEmpty {
                    return name
                }
            }
            if let accountID = tokens["account_id"] as? String, !accountID.isEmpty {
                return "ChatGPT ••••\(accountID.suffix(6))"
            }
        }
        return stableFallbackName(method: method, fingerprint: fingerprint)
    }

    private nonisolated static func stableFallbackName(method: CodexAccountMethod, fingerprint: String) -> String {
        let suffix = fingerprint.suffix(6).uppercased()
        return method == .apiKey ? "OpenAI 密钥 ••••\(suffix)" : "ChatGPT ••••\(suffix)"
    }

    private nonisolated static func isGeneratedName(_ name: String) -> Bool {
        name.range(of: #"^(ChatGPT|Codex) 账户 \d+$"#, options: .regularExpression) != nil
    }

    private nonisolated static func fingerprint(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
