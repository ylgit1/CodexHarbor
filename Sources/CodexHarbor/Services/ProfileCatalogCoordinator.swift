import CodexHarborCore
import Foundation

struct ProfileCatalogSnapshot: Sendable {
    let profiles: [HarborProfile]
    let selectedProfileID: UUID?
    let activeProfileID: UUID?
    let accountProfiles: [CodexAccountProfile]
    let selectedAccountProfileID: UUID?
}

actor ProfileCatalogCoordinator {
    private let profiles: HarborProfileRepository
    private let accounts: CodexAccountProfileRepository

    init(store: SecretStore) {
        profiles = HarborProfileRepository(store: store)
        accounts = CodexAccountProfileRepository(store: store)
    }

    func snapshot(
        environment: CodexEnvironment,
        activeAPIToken: Data?
    ) async throws -> ProfileCatalogSnapshot {
        let harborProfiles = try await profiles.profiles()
        var selectedHarborID = try await profiles.selectedProfileID()
        let activeHarborID: UUID?
        if environment.activeMode == .harbor, let activeAPIToken {
            activeHarborID = try await profiles.profileID(matchingToken: activeAPIToken)
            if let activeHarborID { selectedHarborID = activeHarborID }
        } else {
            activeHarborID = nil
        }

        let visibleAccounts = try await accounts.profiles().filter {
            $0.method == .chatGPT || $0.method == .apiKey
        }
        let selectedAccount = try await accounts.selectedProfileID()
        let visibleAccountSelection = visibleAccounts.contains(where: { $0.id == selectedAccount })
            ? selectedAccount
            : nil

        return ProfileCatalogSnapshot(
            profiles: harborProfiles,
            selectedProfileID: selectedHarborID,
            activeProfileID: activeHarborID,
            accountProfiles: visibleAccounts,
            selectedAccountProfileID: visibleAccountSelection
        )
    }

    func migrateLegacyIfNeeded(environment: CodexEnvironment) async throws {
        try await profiles.migrateLegacyProfileIfNeeded(environment: environment)
    }

    func synchronizeCurrentAccountIfPresent() async throws {
        try await accounts.synchronizeCurrentLoginIfPresent()
    }

    func saveHosted(
        activationKey: String,
        token: String,
        apiBaseURL: URL,
        model: String,
        expiresAt: String?,
        select: Bool = true
    ) async throws -> HarborProfile {
        try await profiles.save(
            activationKey: activationKey,
            token: token,
            apiBaseURL: apiBaseURL,
            model: model,
            expiresAt: expiresAt,
            select: select
        )
    }

    func saveCustom(
        name: String,
        apiKey: String,
        apiBaseURL: URL,
        model: String,
        models: [String],
        modelsVerified: Bool,
        provider: CustomAPIProvider,
        select: Bool
    ) async throws -> HarborProfile {
        try await profiles.saveCustomResponses(
            name: name,
            apiKey: apiKey,
            apiBaseURL: apiBaseURL,
            model: model,
            models: models,
            modelsVerified: modelsVerified,
            provider: provider,
            select: select
        )
    }

    func profileCredentials(for id: UUID) async throws -> HarborProfileCredentials {
        try await profiles.credentials(for: id)
    }

    func updateModels(_ models: [String], for id: UUID) async throws {
        try await profiles.updateModels(models, for: id)
    }

    func updateCustomConnection(
        _ id: UUID,
        apiBaseURL: URL,
        model: String,
        models: [String]
    ) async throws {
        try await profiles.updateCustomConnection(
            id,
            apiBaseURL: apiBaseURL,
            model: model,
            models: models
        )
    }

    func selectProfile(_ id: UUID) async throws {
        try await profiles.select(id)
    }

    func removeProfile(_ id: UUID) async throws {
        try await profiles.remove(id)
    }

    func renameProfile(_ id: UUID, to name: String) async throws {
        try await profiles.rename(id, to: name)
    }

    func moveProfile(_ id: UUID, toFront: Bool) async throws {
        try await profiles.moveToBoundary(id, toFront: toFront)
    }

    func reorderProfile(_ id: UUID, before target: UUID) async throws {
        try await profiles.reorder(moving: id, before: target)
    }

    func saveCurrentAccount(name: String) async throws -> CodexAccountProfile {
        try await accounts.saveCurrentLogin(name: name)
    }

    func importAccountAuthentication(
        _ authentication: Data,
        name: String?,
        select: Bool
    ) async throws -> CodexAccountProfile {
        try await accounts.importAuthentication(authentication, name: name, select: select)
    }

    func switchAccount(to id: UUID) async throws -> CodexAccountProfile {
        try await accounts.switchToProfile(id)
    }

    func accountCredentialHealth(for id: UUID) async throws -> ConnectionHealth {
        try await accounts.credentialHealth(for: id)
    }

    func removeAccount(_ id: UUID) async throws {
        try await accounts.remove(id)
    }

    func renameAccount(_ id: UUID, to name: String) async throws {
        try await accounts.rename(id, to: name)
    }

    func moveAccount(_ id: UUID, toFront: Bool) async throws {
        try await accounts.moveToBoundary(id, toFront: toFront)
    }

    func reorderAccount(_ id: UUID, before target: UUID) async throws {
        try await accounts.reorder(moving: id, before: target)
    }
}
