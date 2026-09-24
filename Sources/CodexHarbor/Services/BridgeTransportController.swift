import ChatGPTBridgeCore
import Foundation

struct BridgeTransportController: Sendable {
    private let store: BridgeConfigurationStore
    private let lifecycle: BridgeLifecycleManager
    private let secrets: BridgeSecretStore

    init(
        paths: BridgePaths,
        store: BridgeConfigurationStore? = nil,
        secretStore: BridgeSecretStore? = nil
    ) {
        let resolvedStore = store ?? BridgeConfigurationStore(paths: paths)
        let resolvedSecrets = secretStore ?? BridgeSecretStore(url: paths.credentialsURL)
        self.store = resolvedStore
        self.secrets = resolvedSecrets
        self.lifecycle = BridgeLifecycleManager(
            paths: paths,
            store: resolvedStore,
            secretStore: resolvedSecrets
        )
    }

    func load() throws -> BridgeConfiguration {
        try store.load()
    }

    func save(_ configuration: BridgeConfiguration) throws {
        try store.save(configuration)
    }

    func isConfigured(
        _ mode: BridgeTransportMode,
        configuration: BridgeConfiguration
    ) throws -> Bool {
        switch mode {
        case .secureTunnel:
            guard configuration.secureTunnel != nil else { return false }
            let key = try secrets.string(for: .tunnelRuntimeAPIKey)
            return key?.isEmpty == false
        case .httpsCompatibility:
            return configuration.httpsCompatibility != nil
        }
    }

    func start(
        configuration: BridgeConfiguration,
        agentExecutableURL: URL
    ) async throws -> BridgeLifecycleSnapshot {
        try await lifecycle.start(
            configuration: configuration,
            agentExecutableURL: agentExecutableURL
        )
    }

    func stop(
        configuration: BridgeConfiguration,
        agentExecutableURL: URL?
    ) async -> BridgeLifecycleSnapshot {
        await lifecycle.stop(
            configuration: configuration,
            agentExecutableURL: agentExecutableURL
        )
    }

    func restart(
        configuration: BridgeConfiguration,
        agentExecutableURL: URL
    ) async throws -> BridgeLifecycleSnapshot {
        try await lifecycle.restart(
            configuration: configuration,
            agentExecutableURL: agentExecutableURL
        )
    }

    func switchTransport(
        to mode: BridgeTransportMode,
        configuration: BridgeConfiguration,
        agentExecutableURL: URL
    ) async throws -> BridgeLifecycleSnapshot {
        try await lifecycle.switchTransport(
            to: mode,
            configuration: configuration,
            agentExecutableURL: agentExecutableURL
        )
    }

    func recover(
        configuration: BridgeConfiguration,
        agentExecutableURL: URL
    ) async throws -> BridgeLifecycleSnapshot {
        try await lifecycle.recover(
            configuration: configuration,
            agentExecutableURL: agentExecutableURL
        )
    }

    func healthCheck(configuration: BridgeConfiguration) async -> BridgeLifecycleSnapshot {
        await lifecycle.healthCheck(configuration: configuration)
    }

    func refreshRuntimeKey(
        _ runtimeKey: String,
        configuration: BridgeConfiguration,
        agentExecutableURL: URL?,
        restartIfActive: Bool
    ) async throws -> BridgeLifecycleSnapshot {
        try await lifecycle.refreshRuntimeKey(
            runtimeKey,
            configuration: configuration,
            agentExecutableURL: agentExecutableURL,
            restartIfActive: restartIfActive
        )
    }
}
