import CryptoKit
import Foundation

public struct HarborProfileCredentials: Sendable {
    public let profile: HarborProfile
    public let activationKey: String
    public let token: String
}

public actor HarborProfileRepository {
    private struct Catalog: Codable {
        var selectedProfileID: UUID?
        var profiles: [HarborProfile]
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

    public func profiles() throws -> [HarborProfile] {
        try load().profiles.sorted { $0.createdAt < $1.createdAt }
    }

    public func selectedProfileID() throws -> UUID? {
        try load().selectedProfileID
    }

    @discardableResult
    public func save(
        activationKey: String,
        token: String,
        apiBaseURL: URL,
        model: String,
        expiresAt: String?,
        select: Bool = true
    ) throws -> HarborProfile {
        var catalog = try load()
        let fingerprint = Self.fingerprint(activationKey)
        let suffix = activationKey.suffix(4)
        let profile: HarborProfile
        if let index = catalog.profiles.firstIndex(where: { $0.keyFingerprint == fingerprint }) {
            catalog.profiles[index].apiBaseURL = apiBaseURL
            catalog.profiles[index].model = model
            catalog.profiles[index].kind = .harbor
            catalog.profiles[index].provider = .openAI
            catalog.profiles[index].expiresAt = expiresAt
            profile = catalog.profiles[index]
        } else {
            profile = HarborProfile(
                name: "密钥 ••••\(suffix)",
                keyFingerprint: fingerprint,
                apiBaseURL: apiBaseURL,
                model: model,
                kind: .harbor,
                expiresAt: expiresAt
            )
            catalog.profiles.append(profile)
        }
        try store.set(activationKey, for: .profileActivationKey(profile.id))
        try store.set(token, for: .profileToken(profile.id))
        if select { catalog.selectedProfileID = profile.id }
        try persist(catalog)
        return profile
    }

    @discardableResult
    public func saveCustomResponses(
        name rawName: String,
        apiKey: String,
        apiBaseURL: URL,
        model: String,
        models: [String] = [],
        modelsVerified: Bool = false,
        provider: CustomAPIProvider = .openAICompatible,
        select: Bool = false
    ) throws -> HarborProfile {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !key.isEmpty else { throw HarborError.invalidConfiguration("自定义连接名称和 API Key 不能为空") }
        var catalog = try load()
        let fingerprint = Self.fingerprint(key)
        let profile: HarborProfile
        if let index = catalog.profiles.firstIndex(where: { $0.keyFingerprint == fingerprint }) {
            catalog.profiles[index].name = name
            catalog.profiles[index].apiBaseURL = apiBaseURL
            catalog.profiles[index].model = model
            catalog.profiles[index].models = models
            catalog.profiles[index].modelsUpdatedAt = models.isEmpty ? nil : Date()
            catalog.profiles[index].modelsVerified = modelsVerified
            catalog.profiles[index].kind = .customResponses
            catalog.profiles[index].provider = provider
            catalog.profiles[index].expiresAt = nil
            profile = catalog.profiles[index]
        } else {
            profile = HarborProfile(
                name: name,
                keyFingerprint: fingerprint,
                apiBaseURL: apiBaseURL,
                model: model,
                kind: .customResponses,
                provider: provider,
                models: models,
                modelsUpdatedAt: models.isEmpty ? nil : Date(),
                modelsVerified: modelsVerified,
                expiresAt: nil
            )
            catalog.profiles.append(profile)
        }
        // The profile token slot stores the bearer key used by the command helper.
        // Keeping it in the same vault path lets old Codex sessions keep using the
        // stable codex_harbor provider while switching between connection types.
        try store.set(key, for: .profileActivationKey(profile.id))
        try store.set(key, for: .profileToken(profile.id))
        if select { catalog.selectedProfileID = profile.id }
        try persist(catalog)
        return profile
    }

    public func updateModels(_ models: [String], for identifier: UUID) throws {
        var catalog = try load()
        guard let index = catalog.profiles.firstIndex(where: { $0.id == identifier }) else { return }
        catalog.profiles[index].models = models
        catalog.profiles[index].modelsUpdatedAt = models.isEmpty ? nil : Date()
        catalog.profiles[index].modelsVerified = true
        try persist(catalog)
    }

    public func updateCustomConnection(
        _ identifier: UUID,
        apiBaseURL: URL,
        model: String,
        models: [String]
    ) throws {
        var catalog = try load()
        guard let index = catalog.profiles.firstIndex(where: { $0.id == identifier }) else { return }
        guard catalog.profiles[index].kind == .customResponses else { return }
        catalog.profiles[index].apiBaseURL = apiBaseURL
        catalog.profiles[index].model = model
        catalog.profiles[index].models = models
        catalog.profiles[index].modelsUpdatedAt = models.isEmpty ? nil : Date()
        try persist(catalog)
    }

    public func credentials(for identifier: UUID) throws -> HarborProfileCredentials {
        let catalog = try load()
        guard let profile = catalog.profiles.first(where: { $0.id == identifier }),
              let activationKey = try store.string(for: .profileActivationKey(identifier)),
              let token = try store.string(for: .profileToken(identifier)) else {
            throw HarborError.missingToken
        }
        return HarborProfileCredentials(profile: profile, activationKey: activationKey, token: token)
    }

    public func select(_ identifier: UUID) throws {
        var catalog = try load()
        guard catalog.profiles.contains(where: { $0.id == identifier }) else {
            throw HarborError.missingToken
        }
        catalog.selectedProfileID = identifier
        try persist(catalog)
    }

    public func profileID(matchingToken token: Data) throws -> UUID? {
        var catalog = try load()
        guard let profile = try catalog.profiles.first(where: {
            try store.data(for: .profileToken($0.id)) == token
        }) else { return nil }
        if catalog.selectedProfileID != profile.id {
            catalog.selectedProfileID = profile.id
            try persist(catalog)
        }
        return profile.id
    }

    public func remove(_ identifier: UUID) throws {
        var catalog = try load()
        guard let index = catalog.profiles.firstIndex(where: { $0.id == identifier }) else { return }
        catalog.profiles.remove(at: index)
        if catalog.selectedProfileID == identifier {
            catalog.selectedProfileID = nil
        }
        try persist(catalog)
        try store.remove(.profileActivationKey(identifier))
        try store.remove(.profileToken(identifier))
    }

    public func migrateLegacyProfileIfNeeded(environment: CodexEnvironment) throws {
        var catalog = try load()
        guard catalog.profiles.isEmpty,
              environment.deploymentExists,
              let apiBaseURL = environment.apiBaseURL,
              let model = environment.model,
              let activationKey = try store.string(for: .activationKey),
              let token = try store.string(for: .apiToken) else { return }
        let profile = HarborProfile(
            name: "密钥 ••••\(activationKey.suffix(4))",
            keyFingerprint: Self.fingerprint(activationKey),
            apiBaseURL: apiBaseURL,
            model: model
        )
        try store.set(activationKey, for: .profileActivationKey(profile.id))
        try store.set(token, for: .profileToken(profile.id))
        catalog.profiles = [profile]
        catalog.selectedProfileID = profile.id
        try persist(catalog)
    }

    private func load() throws -> Catalog {
        guard fileManager.fileExists(atPath: paths.profilesURL.path) else {
            return Catalog(selectedProfileID: nil, profiles: [])
        }
        return try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: paths.profilesURL))
    }

    private func persist(_ catalog: Catalog) throws {
        try fileManager.createDirectory(at: paths.appSupport, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(catalog)
        try data.write(to: paths.profilesURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.profilesURL.path)
    }

    private static func fingerprint(_ activationKey: String) -> String {
        SHA256.hash(data: Data(activationKey.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
