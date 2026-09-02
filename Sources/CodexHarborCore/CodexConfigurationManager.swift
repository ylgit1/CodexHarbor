import CryptoKit
import Foundation

public actor CodexConfigurationManager {
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

    public func inspect() throws -> CodexEnvironment {
        let manifest = try loadManifestIfPresent()
        let configExists = fileManager.fileExists(atPath: paths.configURL.path)
        let configuration = try currentConfigurationText()
        let provider = CodexTOMLEditor.topLevelString(key: "model_provider", in: configuration)
        let model = CodexTOMLEditor.topLevelString(key: "model", in: configuration)
        let modelCatalogURL = CodexTOMLEditor.topLevelString(key: "model_catalog_json", in: configuration)
            .map { URL(fileURLWithPath: $0) }
            .flatMap { fileManager.fileExists(atPath: $0.path) ? $0 : nil }
        let authenticationData = fileManager.fileExists(atPath: paths.authURL.path)
            ? try? Data(contentsOf: paths.authURL)
            : nil
        let accountMethod = authenticationData.flatMap {
            try? CodexAccountProfileRepository.authenticationMethod(in: $0)
        }
        let activeMode: CodexMode?
        if provider == CodexConfigurationSpec.provider {
            activeMode = .harbor
        } else if accountMethod == .chatGPT || accountMethod == .apiKey {
            activeMode = .chatGPT
        } else {
            activeMode = nil
        }
        let actualAPIBaseURL = activeMode == .harbor
            ? CodexTOMLEditor.string(
                key: "base_url",
                inTable: "model_providers.\(CodexConfigurationSpec.provider)",
                source: configuration
            ).flatMap(URL.init(string:))
            : nil
        let configurationDrift: Bool
        if activeMode == .harbor,
           let manifest,
           let expected = manifest.installedSemanticFingerprint {
            configurationDrift = CodexTOMLEditor.semanticFingerprint(configuration) != expected
        } else {
            configurationDrift = false
        }
        return CodexEnvironment(
            configExists: configExists,
            chatGPTSessionExists: accountMethod == .chatGPT || accountMethod == .apiKey,
            deploymentExists: manifest?.state == .installed,
            activeMode: activeMode,
            apiBaseURL: actualAPIBaseURL,
            model: model,
            effectiveProvider: provider,
            accountMethod: activeMode == .chatGPT ? accountMethod : nil,
            modelCatalogURL: modelCatalogURL,
            configurationDrift: configurationDrift
        )
    }

    /// Upgrades only Harbor's managed provider block while preserving the live
    /// default mode and every user-owned configuration entry.
    @discardableResult
    public func reconcileManagedConfiguration(helperExecutable: URL) throws -> Bool {
        var manifest = try requireInstalledManifest()
        let current = try currentConfigurationText()
        let actualMode = try inspect().activeMode
        let spec = CodexConfigurationSpec(
            apiBaseURL: manifest.apiBaseURL,
            model: manifest.model,
            helperExecutable: helperExecutable,
            modelCatalogURL: manifest.modelCatalogURL
        )
        let harborConfiguration = try CodexTOMLEditor.applying(to: current, spec: spec)
        let reconciled: String
        if actualMode != .harbor {
            reconciled = try CodexTOMLEditor.selectingAccountConfiguration(
                in: harborConfiguration,
                original: current
            )
        } else {
            reconciled = harborConfiguration
        }
        // A rewrite can be necessary even when the effective TOML values did
        // not change (for example after a line-ending or whitespace rewrite by
        // Codex). Only semantic changes should make the UI ask to reload.
        let semanticChanged = CodexTOMLEditor.semanticFingerprint(reconciled) !=
            CodexTOMLEditor.semanticFingerprint(current)
        if reconciled != current {
            try write(Data(reconciled.utf8), to: paths.configURL, permissions: manifest.originalPermissions)
        }
        manifest.helperExecutablePath = helperExecutable.path
        manifest.installedConfigExists = true
        manifest.installedSHA256 = sha256(Data(reconciled.utf8))
        manifest.installedSemanticFingerprint = CodexTOMLEditor.semanticFingerprint(reconciled)
        manifest.activeMode = try inspect().activeMode ?? manifest.activeMode
        try saveManifest(manifest)
        return semanticChanged
    }

    @discardableResult
    public func deploy(_ request: DeploymentRequest) throws -> CodexEnvironment {
        if let existing = try loadManifestIfPresent() {
            if existing.state == .preparing {
                try recover(manifest: existing)
            } else {
                throw HarborError.deploymentAlreadyExists
            }
        }
        guard request.apiBaseURL.scheme?.lowercased() == "https" else { throw HarborError.invalidBaseURL }
        guard !request.token.isEmpty else { throw HarborError.missingToken }

        try fileManager.createDirectory(at: paths.codexHome, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: paths.transactionsURL, withIntermediateDirectories: true)

        let originalExisted = fileManager.fileExists(atPath: paths.configURL.path)
        let originalData = originalExisted ? try Data(contentsOf: paths.configURL) : Data()
        let originalPermissions = originalExisted ? try permissions(of: paths.configURL) : 0o600
        let originalText = String(data: originalData, encoding: .utf8) ?? ""
        guard originalData.isEmpty || String(data: originalData, encoding: .utf8) != nil else {
            throw HarborError.invalidConfiguration("config.toml 不是 UTF-8 文本")
        }

        let spec = CodexConfigurationSpec(
            apiBaseURL: request.apiBaseURL,
            model: request.model,
            helperExecutable: request.helperExecutable,
            modelCatalogURL: request.modelCatalogURL
        )
        let installedText = try CodexTOMLEditor.applying(to: originalText, spec: spec)
        let installedData = Data(installedText.utf8)
        let identifier = UUID()
        let transactionURL = paths.transactionsURL.appendingPathComponent(identifier.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: transactionURL, withIntermediateDirectories: true)
        let backupURL = transactionURL.appendingPathComponent("config.toml.before")
        if originalExisted {
            try write(originalData, to: backupURL, permissions: 0o600)
        }

        var manifest = DeploymentManifest(
            identifier: identifier,
            state: .preparing,
            activeMode: .harbor,
            createdAt: Date(),
            configPath: paths.configURL.path,
            backupPath: originalExisted ? backupURL.path : nil,
            originalExisted: originalExisted,
            originalPermissions: originalPermissions,
            originalSHA256: originalExisted ? sha256(originalData) : nil,
            installedConfigExists: true,
            installedSHA256: sha256(installedData),
            installedSemanticFingerprint: CodexTOMLEditor.semanticFingerprint(installedText),
            apiBaseURL: request.apiBaseURL,
            model: request.model,
            helperExecutablePath: request.helperExecutable.path,
            modelCatalogURL: request.modelCatalogURL
        )

        let previousToken = try store.data(for: .apiToken)
        do {
            try saveManifest(manifest)
            try store.set(request.token, for: .apiToken)
            try write(installedData, to: paths.configURL, permissions: originalPermissions)
            let verified = try String(contentsOf: paths.configURL, encoding: .utf8)
            try CodexTOMLEditor.validate(verified, expectedModel: request.model)
            guard sha256(try Data(contentsOf: paths.configURL)) == manifest.installedSHA256 else {
                throw HarborError.invalidConfiguration("写入后的内容校验不一致")
            }
            manifest.state = .installed
            try saveManifest(manifest)
        } catch {
            try? restoreOriginal(using: manifest)
            if let previousToken {
                try? store.set(previousToken, for: .apiToken)
            } else {
                try? store.remove(.apiToken)
            }
            try? fileManager.removeItem(at: paths.activeManifestURL)
            throw error
        }
        return try inspect()
    }

    @discardableResult
    public func switchMode(_ mode: CodexMode, helperExecutable: URL) throws -> CodexEnvironment {
        var manifest = try requireInstalledManifest()
        let actualMode = try inspect().activeMode
        if actualMode == mode {
            if mode == .chatGPT {
                let current = try currentConfigurationText()
                if !current.contains(CodexConfigurationSpec.beginMarker) {
                    // Upgrade configurations created by older Harbor versions,
                    // which removed the provider block in account mode.
                    let spec = CodexConfigurationSpec(
                        apiBaseURL: manifest.apiBaseURL,
                        model: manifest.model,
                        helperExecutable: helperExecutable,
                        modelCatalogURL: manifest.modelCatalogURL
                    )
                    let withProvider = try CodexTOMLEditor.applying(to: current, spec: spec)
                    let selected = try CodexTOMLEditor.selectingAccountConfiguration(
                        in: withProvider,
                        original: current
                    )
                    try write(Data(selected.utf8), to: paths.configURL, permissions: manifest.originalPermissions)
                }
                try captureCurrentConfigurationAsRestoreBaseline(manifest: &manifest)
            }
            manifest.activeMode = mode
            manifest.installedConfigExists = fileManager.fileExists(atPath: paths.configURL.path)
            manifest.installedSHA256 = manifest.installedConfigExists
                ? sha256(try Data(contentsOf: paths.configURL))
                : sha256(Data())
            manifest.installedSemanticFingerprint = try installedSemanticFingerprint()
            manifest.helperExecutablePath = helperExecutable.path
            try saveManifest(manifest)
            return try inspect()
        }
        if mode == .chatGPT {
            let current = try currentConfigurationText()
            let selected = try CodexTOMLEditor.selectingAccountConfiguration(
                in: current,
                original: try originalConfigurationText(using: manifest)
            )
            try write(Data(selected.utf8), to: paths.configURL, permissions: manifest.originalPermissions)
            try captureCurrentConfigurationAsRestoreBaseline(manifest: &manifest)
            manifest.installedConfigExists = fileManager.fileExists(atPath: paths.configURL.path)
            manifest.installedSHA256 = manifest.installedConfigExists
                ? sha256(try Data(contentsOf: paths.configURL))
                : sha256(Data())
            manifest.installedSemanticFingerprint = try installedSemanticFingerprint()
        } else {
            guard try store.data(for: .apiToken) != nil else { throw HarborError.missingToken }
            let accountText = try currentConfigurationText()
            try captureCurrentConfigurationAsRestoreBaseline(manifest: &manifest)
            let spec = CodexConfigurationSpec(
                apiBaseURL: manifest.apiBaseURL,
                model: manifest.model,
                helperExecutable: helperExecutable,
                modelCatalogURL: manifest.modelCatalogURL
            )
            let configured = try CodexTOMLEditor.applying(to: accountText, spec: spec)
            let data = Data(configured.utf8)
            try write(data, to: paths.configURL, permissions: manifest.originalPermissions)
            try CodexTOMLEditor.validate(configured, expectedModel: manifest.model)
            manifest.installedConfigExists = true
            manifest.installedSHA256 = sha256(data)
            manifest.installedSemanticFingerprint = CodexTOMLEditor.semanticFingerprint(configured)
        }
        manifest.activeMode = mode
        manifest.helperExecutablePath = helperExecutable.path
        try saveManifest(manifest)
        return try inspect()
    }

    @discardableResult
    public func updateConnection(apiBaseURL: URL, model: String, helperExecutable: URL, modelCatalogURL: URL? = nil) throws -> CodexEnvironment {
        let previousManifest = try requireInstalledManifest()
        let actualMode = try inspect().activeMode
        guard apiBaseURL.scheme?.lowercased() == "https", apiBaseURL.host?.isEmpty == false else {
            throw HarborError.invalidBaseURL
        }

        let baseText = try currentConfigurationText()
        let configured = try CodexTOMLEditor.applying(
            to: baseText,
            spec: CodexConfigurationSpec(
                apiBaseURL: apiBaseURL,
                model: model,
                helperExecutable: helperExecutable,
                modelCatalogURL: modelCatalogURL
            )
        )
        let configuredData = Data(configured.utf8)
        var updatedManifest = previousManifest
        updatedManifest.apiBaseURL = apiBaseURL
        updatedManifest.model = model
        updatedManifest.helperExecutablePath = helperExecutable.path
        updatedManifest.modelCatalogURL = modelCatalogURL

        if actualMode == .harbor {
            let previousData = try Data(contentsOf: paths.configURL)
            do {
                try write(configuredData, to: paths.configURL, permissions: previousManifest.originalPermissions)
                try CodexTOMLEditor.validate(configured, expectedModel: model)
                updatedManifest.installedConfigExists = true
                updatedManifest.installedSHA256 = sha256(configuredData)
                updatedManifest.installedSemanticFingerprint = CodexTOMLEditor.semanticFingerprint(configured)
                try saveManifest(updatedManifest)
            } catch {
                try? write(previousData, to: paths.configURL, permissions: previousManifest.originalPermissions)
                try? saveManifest(previousManifest)
                throw error
            }
        } else {
            try saveManifest(updatedManifest)
        }
        return try inspect()
    }

    /// Rebinds every persisted local task to the connection selected in the
    /// live Codex configuration. Call only after the Codex app has stopped so
    /// its SQLite state and rollout files cannot be written concurrently.
    public func migrateAllTasksToCurrentConnection(visibleTaskIDs: Set<String>? = nil) throws -> CodexTaskMigrationResult {
        let environment = try inspect()
        let provider = environment.effectiveProvider
            ?? (environment.activeMode == .chatGPT ? "openai" : nil)
        guard let provider else {
            throw HarborError.invalidConfiguration("当前 Codex 配置没有模型服务商")
        }
        return try CodexTaskConnectionMigrator(paths: paths, fileManager: fileManager)
            .migrateAllTasks(toProvider: provider, model: environment.model, visibleTaskIDs: visibleTaskIDs)
    }

    public func previewTaskMigrationToCurrentConnection() throws -> CodexTaskMigrationPreview {
        let environment = try inspect()
        let provider = environment.effectiveProvider
            ?? (environment.activeMode == .chatGPT ? "openai" : nil)
        guard let provider else {
            throw HarborError.invalidConfiguration("当前 Codex 配置没有模型服务商")
        }
        return try CodexTaskConnectionMigrator(paths: paths, fileManager: fileManager)
            .previewAllTasks(toProvider: provider, model: environment.model)
    }

    public func switchTaskVisibility(to group: CodexTaskVisibilityGroup, externalModelIDs: Set<String> = []) throws -> CodexTaskVisibilityResult {
        try CodexTaskVisibilityManager(paths: paths, fileManager: fileManager).switchTo(group, externalModelIDs: externalModelIDs)
    }

    public func visibleTaskIDs() throws -> Set<String> {
        Set(try CodexTaskVisibilityManager(paths: paths, fileManager: fileManager).visibleTaskIDs())
    }

    public func isModelCatalogValid() -> Bool {
        guard fileManager.fileExists(atPath: paths.customModelsURL.path),
              let data = try? Data(contentsOf: paths.customModelsURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = object["models"] as? [[String: Any]],
              !models.isEmpty else { return false }
        return models.allSatisfy {
            guard let slug = $0["slug"] as? String else { return false }
            return !slug.isEmpty && $0["display_name"] is String && $0["supported_reasoning_levels"] is [[String: Any]]
        }
    }

    /// Forces Codex to fetch the model catalog for the newly selected provider.
    /// The cache is disposable and will be recreated by Codex on next launch.
    public func invalidateModelCatalogCache() throws {
        guard fileManager.fileExists(atPath: paths.modelsCacheURL.path) else { return }
        try fileManager.removeItem(at: paths.modelsCacheURL)
    }

    /// Writes the model catalog format consumed by Codex's model picker. The
    /// catalog deliberately contains only models exposed by the selected API;
    /// this prevents Codex from showing its built-in OpenAI entries for custom
    /// providers such as Kimi.
    public func writeModelCatalog(models: [String]) throws -> URL {
        var seen = Set<String>()
        let ids = models.compactMap { value -> String? in
            let model = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isSafeModel(model), seen.insert(model).inserted else { return nil }
            return model
        }
        guard !ids.isEmpty else { throw HarborError.invalidModel }
        let entries: [[String: Any]] = ids.map { model in
            [
                "slug": model,
                "display_name": model,
                "description": "由当前连接提供商提供",
                "supported_reasoning_levels": [["effort": "medium", "description": "标准推理"]],
                "shell_type": "shell_command",
                "visibility": "list",
                "supported_in_api": true,
                "priority": 0,
                "base_instructions": "You are Codex.",
                "supports_reasoning_summaries": false,
                "support_verbosity": false,
                "truncation_policy": ["mode": "tokens", "limit": 10000],
                "supports_parallel_tool_calls": true,
                "experimental_supported_tools": []
            ]
        }
        let data = try JSONSerialization.data(withJSONObject: ["models": entries], options: [.prettyPrinted, .sortedKeys])
        try write(data, to: paths.customModelsURL, permissions: 0o600)
        return paths.customModelsURL
    }

    public func modelCatalogSnapshot() throws -> Data? {
        guard fileManager.fileExists(atPath: paths.customModelsURL.path) else { return nil }
        return try Data(contentsOf: paths.customModelsURL)
    }

    public func restoreModelCatalog(_ data: Data?) throws {
        if let data {
            try write(data, to: paths.customModelsURL, permissions: 0o600)
        } else if fileManager.fileExists(atPath: paths.customModelsURL.path) {
            try fileManager.removeItem(at: paths.customModelsURL)
        }
    }

    @discardableResult
    public func uninstall(force: Bool = false) throws -> CodexEnvironment {
        let manifest = try requireInstalledManifest()
        if force {
            try restoreOriginal(using: manifest)
        } else {
            // Account mode intentionally retains the provider definition so old
            // Harbor sessions can resume. Uninstall is the operation that removes it.
            try restoreAccountConfigurationPreservingExternalChanges(using: manifest)
        }
        try store.remove(.apiToken)
        if fileManager.fileExists(atPath: paths.customModelsURL.path) {
            try? fileManager.removeItem(at: paths.customModelsURL)
        }
        try fileManager.removeItem(at: paths.activeManifestURL)
        let transactionURL = paths.transactionsURL.appendingPathComponent(manifest.identifier.uuidString, isDirectory: true)
        try? fileManager.removeItem(at: transactionURL)
        return try inspect()
    }

    public func recoverInterruptedDeploymentIfNeeded() throws {
        guard let manifest = try loadManifestIfPresent(), manifest.state == .preparing else { return }
        try recover(manifest: manifest)
    }

    private func recover(manifest: DeploymentManifest) throws {
        try restoreOriginal(using: manifest)
        try? store.remove(.apiToken)
        try? fileManager.removeItem(at: paths.activeManifestURL)
    }

    private func restoreOriginal(using manifest: DeploymentManifest) throws {
        if manifest.originalExisted {
            guard let backupPath = manifest.backupPath else { throw HarborError.missingBackup }
            let backupURL = URL(fileURLWithPath: backupPath)
            guard fileManager.fileExists(atPath: backupURL.path) else { throw HarborError.missingBackup }
            let data = try Data(contentsOf: backupURL)
            if let expected = manifest.originalSHA256, sha256(data) != expected {
                throw HarborError.missingBackup
            }
            try write(data, to: paths.configURL, permissions: manifest.originalPermissions)
        } else if fileManager.fileExists(atPath: paths.configURL.path) {
            try fileManager.removeItem(at: paths.configURL)
        }
    }

    private func originalConfigurationText(using manifest: DeploymentManifest) throws -> String {
        guard manifest.originalExisted else { return "" }
        guard let backupPath = manifest.backupPath else { throw HarborError.missingBackup }
        let data = try Data(contentsOf: URL(fileURLWithPath: backupPath))
        guard manifest.originalSHA256 == sha256(data), let value = String(data: data, encoding: .utf8) else {
            throw HarborError.missingBackup
        }
        return value
    }

    private func currentConfigurationText() throws -> String {
        guard fileManager.fileExists(atPath: paths.configURL.path) else { return "" }
        guard let value = String(data: try Data(contentsOf: paths.configURL), encoding: .utf8) else {
            throw HarborError.invalidConfiguration("config.toml 不是 UTF-8 文本")
        }
        return value
    }

    private func restoreAccountConfigurationPreservingExternalChanges(using manifest: DeploymentManifest) throws {
        let current = try currentConfigurationText()
        let baseline = try CodexTOMLEditor.accountBaseline(from: current)
        let original = try originalConfigurationText(using: manifest)
        if baseline.trimmingCharacters(in: .newlines) == original.trimmingCharacters(in: .newlines) {
            try restoreOriginal(using: manifest)
            return
        }
        let restored = try CodexTOMLEditor.restoringAccountConfiguration(
            in: current,
            original: original
        )
        if restored.trimmingCharacters(in: .newlines) == original.trimmingCharacters(in: .newlines) {
            try restoreOriginal(using: manifest)
            return
        }
        if !manifest.originalExisted && restored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if fileManager.fileExists(atPath: paths.configURL.path) {
                try fileManager.removeItem(at: paths.configURL)
            }
        } else {
            try write(Data(restored.utf8), to: paths.configURL, permissions: manifest.originalPermissions)
        }
    }

    private func captureCurrentConfigurationAsRestoreBaseline(manifest: inout DeploymentManifest) throws {
        let exists = fileManager.fileExists(atPath: paths.configURL.path)
        let data: Data
        if exists {
            let current = try currentConfigurationText()
            data = Data(try CodexTOMLEditor.accountBaseline(from: current).utf8)
        } else {
            data = Data()
        }
        let permissions = exists ? try permissions(of: paths.configURL) : 0o600
        let transactionURL = paths.transactionsURL.appendingPathComponent(manifest.identifier.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: transactionURL, withIntermediateDirectories: true)
        let backupURL = transactionURL.appendingPathComponent("config.toml.before")
        if exists,
           let existing = try? originalConfigurationText(using: manifest),
           String(data: data, encoding: .utf8)?.trimmingCharacters(in: .newlines)
                == existing.trimmingCharacters(in: .newlines) {
            manifest.originalPermissions = permissions
            return
        }
        if exists {
            try write(data, to: backupURL, permissions: 0o600)
            manifest.backupPath = backupURL.path
        } else {
            if fileManager.fileExists(atPath: backupURL.path) {
                try fileManager.removeItem(at: backupURL)
            }
            manifest.backupPath = nil
        }
        manifest.originalExisted = exists
        manifest.originalPermissions = permissions
        manifest.originalSHA256 = exists ? sha256(data) : nil
    }

    private func currentConfigurationMatches(_ manifest: DeploymentManifest) throws -> Bool {
        let exists = fileManager.fileExists(atPath: paths.configURL.path)
        guard exists == manifest.installedConfigExists else { return false }
        guard exists else {
            return (manifest.installedSemanticFingerprint ?? manifest.installedSHA256) ==
                (manifest.installedSemanticFingerprint ?? sha256(Data()))
        }
        let data = try Data(contentsOf: paths.configURL)
        guard let text = String(data: data, encoding: .utf8) else { return false }
        if let expected = manifest.installedSemanticFingerprint {
            return CodexTOMLEditor.semanticFingerprint(text) == expected
        }
        return sha256(data) == manifest.installedSHA256
    }

    private func installedSemanticFingerprint() throws -> String {
        CodexTOMLEditor.semanticFingerprint(try currentConfigurationText())
    }

    private func requireInstalledManifest() throws -> DeploymentManifest {
        guard let manifest = try loadManifestIfPresent(), manifest.state == .installed else {
            throw HarborError.deploymentNotFound
        }
        return manifest
    }

    private func loadManifestIfPresent() throws -> DeploymentManifest? {
        guard fileManager.fileExists(atPath: paths.activeManifestURL.path) else { return nil }
        return try JSONDecoder.harbor.decode(DeploymentManifest.self, from: Data(contentsOf: paths.activeManifestURL))
    }

    private func saveManifest(_ manifest: DeploymentManifest) throws {
        try fileManager.createDirectory(at: paths.appSupport, withIntermediateDirectories: true)
        try write(try JSONEncoder.harbor.encode(manifest), to: paths.activeManifestURL, permissions: 0o600)
    }

    private func write(_ data: Data, to url: URL, permissions: Int) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
    }

    private func permissions(of url: URL) throws -> Int {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o600
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func isSafeModel(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 100 && value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._/")).contains($0)
        }
    }
}

private extension JSONEncoder {
    static var harbor: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var harbor: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
