import Foundation
import SQLite3
import Testing
@testable import CodexHarborCore

@Suite("Codex configuration transaction")
struct CodexConfigurationManagerTests {
    @Test("Usage parser accepts the service remain_amount field")
    func parsesServiceUsageShape() {
        let usage = HarborServiceClient.usageSnapshot(in: [
            "success": true,
            "used_amount": 12.5,
            "remain_amount": 37.5,
            "expires_at": "2026-09-01T09:03:45"
        ])
        #expect(usage.used == 12.5)
        #expect(usage.remaining == 37.5)
        #expect(usage.expiresAt == "2026-09-01T09:03:45")
    }

    @Test("Codex account auth is recognized from its OPENAI_API_KEY field")
    func recognizesCodexAccountAuth() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.writeConfig("model = \"gpt-5.4\"\nmodel_provider = \"openai\"\n", permissions: 0o600)
        try fixture.writeAuth(try JSONSerialization.data(withJSONObject: [
            "OPENAI_API_KEY": "sk-example"
        ]))

        let environment = try await fixture.manager().inspect()
        #expect(environment.chatGPTSessionExists == true)
        #expect(environment.activeMode == .chatGPT)
    }

    @Test("Multiple activation profiles keep independent credentials")
    func storesIndependentProfiles() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let repository = HarborProfileRepository(paths: fixture.paths, store: fixture.store)
        let first = try await repository.save(
            activationKey: "activation-first-1111",
            token: "token-first",
            apiBaseURL: URL(string: "https://first.example.com/v1")!,
            model: "gpt-5.4",
            expiresAt: nil
        )
        let second = try await repository.save(
            activationKey: "activation-second-2222",
            token: "token-second",
            apiBaseURL: URL(string: "https://second.example.com/v1")!,
            model: "gpt-5.6-terra",
            expiresAt: "2026-10-01"
        )

        #expect(try await repository.profiles().count == 2)
        #expect(try await repository.selectedProfileID() == second.id)
        let firstCredentials = try await repository.credentials(for: first.id)
        let secondCredentials = try await repository.credentials(for: second.id)
        #expect(firstCredentials.activationKey == "activation-first-1111")
        #expect(firstCredentials.token == "token-first")
        #expect(secondCredentials.activationKey == "activation-second-2222")
        #expect(secondCredentials.token == "token-second")
    }

    @Test("Custom Responses profiles keep their endpoint, model, and API key")
    func storesCustomResponsesProfile() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let repository = HarborProfileRepository(paths: fixture.paths, store: fixture.store)
        let profile = try await repository.saveCustomResponses(
            name: "公司网关",
            apiKey: "custom-api-key",
            apiBaseURL: URL(string: "https://gateway.example.com/v1")!,
            model: "gpt-5.3-codex",
            provider: .otherCompatibleGateway
        )
        #expect(profile.kind == .customResponses)
        #expect(profile.provider == .otherCompatibleGateway)
        #expect(profile.name == "公司网关")
        #expect(try await repository.credentials(for: profile.id).token == "custom-api-key")
        #expect(try await repository.credentials(for: profile.id).activationKey == "custom-api-key")
        #expect(try await repository.selectedProfileID() == nil)
    }

    @Test("Generated custom model catalog contains only provider models")
    func writesCustomModelCatalog() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let url = try await fixture.manager().writeModelCatalog(models: [" kimi-k2.6 ", "kimi-k2.7-code", "kimi-k2.6"])
        let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let entries = try #require(object["models"] as? [[String: Any]])
        #expect(entries.map { $0["slug"] as? String } == ["kimi-k2.6", "kimi-k2.7-code"])
        #expect(entries.allSatisfy { ($0["supported_in_api"] as? Bool) == true })
    }

    @Test("Profiles can be deleted together with their credentials")
    func removesInactiveProfiles() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let repository = HarborProfileRepository(paths: fixture.paths, store: fixture.store)
        let first = try await repository.save(
            activationKey: "activation-first-1111",
            token: "token-first",
            apiBaseURL: URL(string: "https://one.example.com/v1")!,
            model: "gpt-5.4",
            expiresAt: nil
        )
        _ = try await repository.save(
            activationKey: "activation-second-2222",
            token: "token-second",
            apiBaseURL: URL(string: "https://two.example.com/v1")!,
            model: "gpt-5.4",
            expiresAt: nil
        )
        try await repository.remove(first.id)
        #expect(try await repository.profiles().contains(where: { $0.id == first.id }) == false)
        #expect(try fixture.store.data(for: .profileToken(first.id)) == nil)
        #expect(try fixture.store.data(for: .profileActivationKey(first.id)) == nil)
    }

    @Test("Account name is detected from the ChatGPT identity token")
    func detectsAccountName() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let payload = try JSONSerialization.data(withJSONObject: ["email": "developer@example.com", "sub": "user-1"])
        let encoded = payload.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        try fixture.writeAuth(try JSONSerialization.data(withJSONObject: [
            "tokens": [
                "account_id": "account-1",
                "access_token": "access-token",
                "id_token": "header.\(encoded).signature"
            ]
        ]))
        let repository = CodexAccountProfileRepository(paths: fixture.paths, store: fixture.store)
        let profile = try await repository.saveCurrentLogin(name: nil)
        #expect(profile.name == "developer@example.com")
    }

    @Test("Account health distinguishes renewable and expired credentials")
    func detectsAccountCredentialHealth() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let repository = CodexAccountProfileRepository(paths: fixture.paths, store: fixture.store)

        func jwt(_ payload: [String: Any]) throws -> String {
            let data = try JSONSerialization.data(withJSONObject: payload)
            let encoded = data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
            return "header.\(encoded).signature"
        }

        try fixture.writeAuth(try JSONSerialization.data(withJSONObject: [
            "tokens": [
                "account_id": "expired-account",
                "access_token": try jwt(["exp": 1_600_000_000])
            ]
        ]))
        let expired = try await repository.saveCurrentLogin(name: "已过期账户")
        #expect(try await repository.credentialHealth(for: expired.id) == .expired("登录已过期"))

        try fixture.writeAuth(try JSONSerialization.data(withJSONObject: [
            "tokens": [
                "account_id": "renewable-account",
                "access_token": try jwt(["exp": 1_600_000_000]),
                "refresh_token": "refresh-token"
            ]
        ]))
        let renewable = try await repository.saveCurrentLogin(name: "可续期账户")
        #expect(try await repository.credentialHealth(for: renewable.id) == .available("支持自动续期"))
    }

    @Test("Local credential vault is restricted to the current user")
    func storesCredentialsLocally() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let store = LocalSecretStore(url: fixture.paths.credentialsURL)
        try store.set("secret-token", for: .apiToken)
        #expect(try store.string(for: .apiToken) == "secret-token")
        let permissions = try FileManager.default.attributesOfItem(atPath: fixture.paths.credentialsURL.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
        try store.remove(.apiToken)
        #expect(try store.data(for: .apiToken) == nil)
    }

    @Test("Codex account profiles switch auth atomically without touching sessions")
    func switchesCodexAccountProfiles() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let repository = CodexAccountProfileRepository(paths: fixture.paths, store: fixture.store)
        let sessionURL = fixture.paths.codexHome.appendingPathComponent("sessions/existing.json")
        try FileManager.default.createDirectory(at: sessionURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let session = Data("conversation-history".utf8)
        try session.write(to: sessionURL)

        let workAuthentication = try JSONSerialization.data(withJSONObject: [
            "tokens": ["account_id": "work-account", "access_token": "work-secret"]
        ])
        try fixture.writeAuth(workAuthentication)
        let work = try await repository.saveCurrentLogin(name: "工作账户")

        let personalAuthentication = try JSONSerialization.data(withJSONObject: [
            "OPENAI_API_KEY": "personal-secret"
        ])
        try fixture.writeAuth(personalAuthentication)
        let personal = try await repository.saveCurrentLogin(name: "个人账户")
        #expect(personal.method == .apiKey)
        #expect(try await repository.selectedProfileID() == personal.id)

        let selected = try await repository.switchToProfile(work.id)
        #expect(selected.method == .chatGPT)
        #expect(try Data(contentsOf: fixture.paths.authURL) == workAuthentication)
        #expect(try fixture.authPermissions() == 0o600)
        #expect(try Data(contentsOf: sessionURL) == session)
        #expect(try await repository.selectedProfileID() == work.id)
    }

    @Test("An isolated account login can be imported without replacing the live account")
    func importsAccountWithoutChangingLiveLogin() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let repository = CodexAccountProfileRepository(paths: fixture.paths, store: fixture.store)
        let originalAuthentication = try JSONSerialization.data(withJSONObject: [
            "tokens": ["account_id": "original", "access_token": "original-token"]
        ])
        try fixture.writeAuth(originalAuthentication)
        let original = try await repository.saveCurrentLogin(name: "原账户")

        let stagedAuthentication = try JSONSerialization.data(withJSONObject: [
            "tokens": ["account_id": "staged", "access_token": "staged-token"]
        ])
        let staged = try await repository.importAuthentication(
            stagedAuthentication,
            name: "新账户",
            select: false
        )

        #expect(try Data(contentsOf: fixture.paths.authURL) == originalAuthentication)
        #expect(try await repository.selectedProfileID() == original.id)
        #expect(staged.id != original.id)

        _ = try await repository.switchToProfile(staged.id)
        #expect(try Data(contentsOf: fixture.paths.authURL) == stagedAuthentication)
        #expect(try await repository.selectedProfileID() == staged.id)
    }

    @Test("Deploy, switch to ChatGPT, and uninstall restores exact original")
    func completeRoundTrip() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let original = """
        model = "gpt-5.6-sol"
        approval_policy = "on-request"

        [projects."/tmp/example"]
        trust_level = "trusted"
        """
        try fixture.writeConfig(original, permissions: 0o640)
        let auth = try JSONSerialization.data(withJSONObject: [
            "tokens": ["account_id": "existing-account", "access_token": "existing-session"]
        ])
        try fixture.writeAuth(auth)
        let sessionURL = fixture.paths.codexHome.appendingPathComponent("sessions/existing-session.json")
        try FileManager.default.createDirectory(at: sessionURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let session = Data("existing-conversation-history".utf8)
        try session.write(to: sessionURL)

        let manager = fixture.manager()
        let request = DeploymentRequest(
            token: "secret-service-token",
            apiBaseURL: URL(string: "https://gateway.example.com/v1")!,
            model: "gpt-5.4",
            helperExecutable: URL(fileURLWithPath: "/Applications/Codex Harbor.app/Contents/MacOS/CodexHarbor")
        )
        let deployed = try await manager.deploy(request)
        #expect(deployed.activeMode == .harbor)
        let deployedText = try String(contentsOf: fixture.paths.configURL, encoding: .utf8)
        #expect(deployedText.contains("model_provider = \"codex_harbor\""))
        #expect(deployedText.contains("approval_policy = \"on-request\""))
        #expect(!deployedText.contains("secret-service-token"))
        #expect(try Data(contentsOf: fixture.paths.authURL) == auth)
        #expect(try Data(contentsOf: sessionURL) == session)

        let switched = try await manager.switchMode(
            .chatGPT,
            helperExecutable: URL(fileURLWithPath: "/Applications/Codex Harbor.app/Contents/MacOS/CodexHarbor")
        )
        #expect(switched.activeMode == .chatGPT)
        let chatGPTText = try String(contentsOf: fixture.paths.configURL, encoding: .utf8)
        #expect(chatGPTText.contains(original))
        #expect(chatGPTText.contains("CODEX HARBOR MANAGED CONFIG"))
        #expect(chatGPTText.contains("refresh_interval_ms = 1000"))
        #expect(try Data(contentsOf: fixture.paths.authURL) == auth)
        #expect(try Data(contentsOf: sessionURL) == session)

        let switchedBack = try await manager.switchMode(
            .harbor,
            helperExecutable: URL(fileURLWithPath: "/Applications/Codex Harbor.app/Contents/MacOS/CodexHarbor")
        )
        #expect(switchedBack.activeMode == .harbor)
        #expect(try String(contentsOf: fixture.paths.configURL, encoding: .utf8).contains("model_provider = \"codex_harbor\""))

        let restored = try await manager.uninstall()
        #expect(!restored.deploymentExists)
        #expect(try String(contentsOf: fixture.paths.configURL, encoding: .utf8) == original)
        #expect(try fixture.permissions() == 0o640)
        #expect(try Data(contentsOf: fixture.paths.authURL) == auth)
        #expect(try fixture.store.string(for: .apiToken) == nil)
    }

    @Test("Switching to the account configuration keeps OPENAI_API_KEY without re-login")
    func switchesToAccountWithoutRelogin() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let original = "model_provider = \"OpenAI\"\nmodel = \"gpt-5.6-terra\"\n"
        try fixture.writeConfig(original, permissions: 0o600)
        let auth = try JSONSerialization.data(withJSONObject: ["OPENAI_API_KEY": "account-key"])
        try fixture.writeAuth(auth)
        let manager = fixture.manager()
        _ = try await manager.deploy(.init(
            token: "harbor-token",
            apiBaseURL: URL(string: "https://gateway.example.com/v1")!,
            model: "gpt-5.6-terra",
            helperExecutable: URL(fileURLWithPath: "/tmp/CodexHarbor")
        ))

        let account = try await manager.switchMode(.chatGPT, helperExecutable: URL(fileURLWithPath: "/tmp/CodexHarbor"))
        #expect(account.activeMode == .chatGPT)
        let accountText = try String(contentsOf: fixture.paths.configURL, encoding: .utf8)
        #expect(accountText.contains(original))
        #expect(accountText.contains("CODEX HARBOR MANAGED CONFIG"))
        #expect(try Data(contentsOf: fixture.paths.authURL) == auth)
    }

    @Test("Uninstall removes config when none existed before deployment")
    func removesCreatedConfig() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let manager = fixture.manager()
        _ = try await manager.deploy(.init(
            token: "token",
            apiBaseURL: URL(string: "https://gateway.example.com/v1")!,
            model: "gpt-5.4",
            helperExecutable: URL(fileURLWithPath: "/tmp/CodexHarbor")
        ))
        #expect(FileManager.default.fileExists(atPath: fixture.paths.configURL.path))
        _ = try await manager.uninstall()
        #expect(!FileManager.default.fileExists(atPath: fixture.paths.configURL.path))
    }

    @Test("Inspection and switching follow live Codex config instead of stale manifest mode")
    func followsLiveCodexConfiguration() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let accountConfig = "model = \"gpt-5.4\"\nmodel_provider = \"openai\"\n"
        try fixture.writeConfig(accountConfig, permissions: 0o600)
        try fixture.writeAuth(try JSONSerialization.data(withJSONObject: [
            "tokens": ["account_id": "account", "access_token": "session"]
        ]))
        let executable = URL(fileURLWithPath: "/tmp/CodexHarbor")
        let manager = fixture.manager()
        _ = try await manager.deploy(.init(
            token: "harbor-token",
            apiBaseURL: URL(string: "https://gateway.example.com/v1")!,
            model: "gpt-5.6-terra",
            helperExecutable: executable
        ))

        try fixture.writeConfig(accountConfig, permissions: 0o600)
        let actualAccount = try await manager.inspect()
        #expect(actualAccount.activeMode == .chatGPT)
        #expect(actualAccount.effectiveProvider == "openai")
        #expect(actualAccount.accountMethod == .chatGPT)
        #expect(actualAccount.apiBaseURL == nil)

        let switched = try await manager.switchMode(.harbor, helperExecutable: executable)
        #expect(switched.activeMode == .harbor)
        #expect(switched.effectiveProvider == "codex_harbor")
        #expect(switched.apiBaseURL?.absoluteString == "https://gateway.example.com/v1")
        #expect(switched.model == "gpt-5.6-terra")
    }

    @Test("Connection settings update safely in both modes")
    func updatesConnectionSettings() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let original = "model = \"gpt-5.6-sol\"\n"
        try fixture.writeConfig(original, permissions: 0o600)
        let executable = URL(fileURLWithPath: "/tmp/CodexHarbor")
        let manager = fixture.manager()
        _ = try await manager.deploy(.init(
            token: "token",
            apiBaseURL: URL(string: "https://gateway.example.com/v1")!,
            model: "gpt-5.4",
            helperExecutable: executable
        ))

        let updated = try await manager.updateConnection(
            apiBaseURL: URL(string: "https://second.example.com/v1")!,
            model: "gpt-5.5",
            helperExecutable: executable
        )
        #expect(updated.apiBaseURL?.absoluteString == "https://second.example.com/v1")
        #expect(updated.model == "gpt-5.5")
        let updatedText = try String(contentsOf: fixture.paths.configURL, encoding: .utf8)
        #expect(updatedText.contains("base_url = \"https://second.example.com/v1\""))
        #expect(updatedText.contains("model = \"gpt-5.5\""))

        _ = try await manager.switchMode(.chatGPT, helperExecutable: executable)
        _ = try await manager.updateConnection(
            apiBaseURL: URL(string: "https://third.example.com/v1")!,
            model: "gpt-5.6-sol",
            helperExecutable: executable
        )
        let accountText = try String(contentsOf: fixture.paths.configURL, encoding: .utf8)
        #expect(accountText.contains(original))
        #expect(accountText.contains("CODEX HARBOR MANAGED CONFIG"))
        let switchedBack = try await manager.switchMode(.harbor, helperExecutable: executable)
        #expect(switchedBack.apiBaseURL?.absoluteString == "https://third.example.com/v1")
        #expect(try String(contentsOf: fixture.paths.configURL, encoding: .utf8).contains("model = \"gpt-5.6-sol\""))
    }

    @Test("Startup reconciliation upgrades only the managed provider block")
    func reconcilesLegacyManagedConfiguration() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let original = "model = \"gpt-5.4\"\ncustom_setting = \"keep-me\"\n"
        try fixture.writeConfig(original, permissions: 0o600)
        let manager = fixture.manager()
        _ = try await manager.deploy(.init(
            token: "token",
            apiBaseURL: URL(string: "https://gateway.example.com/v1")!,
            model: "gpt-5.4",
            helperExecutable: URL(fileURLWithPath: "/tmp/OldHarbor")
        ))
        var legacy = try String(contentsOf: fixture.paths.configURL, encoding: .utf8)
        legacy = legacy.replacingOccurrences(of: "refresh_interval_ms = 1000", with: "refresh_interval_ms = 60000")
        try fixture.writeConfig(legacy, permissions: 0o600)

        let changed = try await manager.reconcileManagedConfiguration(
            helperExecutable: URL(fileURLWithPath: "/tmp/NewHarbor")
        )
        let reconciled = try String(contentsOf: fixture.paths.configURL, encoding: .utf8)
        #expect(changed)
        #expect(reconciled.contains("refresh_interval_ms = 1000"))
        #expect(reconciled.contains("command = \"/tmp/NewHarbor\""))
        #expect(reconciled.contains("custom_setting = \"keep-me\""))
        #expect(try await manager.inspect().activeMode == .harbor)
        #expect(try await manager.reconcileManagedConfiguration(
            helperExecutable: URL(fileURLWithPath: "/tmp/NewHarbor")
        ) == false)
    }

    @Test("Startup reconciliation ignores formatting-only rewrites")
    func ignoresFormattingOnlyRewrites() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.writeConfig("model = \"gpt-5.4\"\ncustom_setting = \"keep-me\"\n", permissions: 0o600)
        let manager = fixture.manager()
        let executable = URL(fileURLWithPath: "/tmp/CodexHarbor")
        _ = try await manager.deploy(.init(
            token: "token",
            apiBaseURL: URL(string: "https://gateway.example.com/v1")!,
            model: "gpt-5.4",
            helperExecutable: executable
        ))

        var rewritten = try String(contentsOf: fixture.paths.configURL, encoding: .utf8)
        rewritten = rewritten
            .replacingOccurrences(of: "model = \"gpt-5.4\"", with: "  model=\"gpt-5.4\"  ")
            .replacingOccurrences(of: "\n", with: "\r\n")
        try fixture.writeConfig(rewritten, permissions: 0o600)

        #expect(try await manager.reconcileManagedConfiguration(helperExecutable: executable) == false)
    }

    @Test("External Codex edits survive mode switching and uninstall")
    func preservesExternalEdits() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.writeConfig("model = \"gpt-5.6-sol\"\n", permissions: 0o600)
        let manager = fixture.manager()
        _ = try await manager.deploy(.init(
            token: "token",
            apiBaseURL: URL(string: "https://gateway.example.com/v1")!,
            model: "gpt-5.4",
            helperExecutable: URL(fileURLWithPath: "/tmp/CodexHarbor")
        ))
        var text = try String(contentsOf: fixture.paths.configURL, encoding: .utf8)
        text = text.replacingOccurrences(
            of: "model_provider = \"codex_harbor\"",
            with: "model_provider = \"another_provider\""
        )
        text += "\n[features]\nview_image = true\n"
        try fixture.writeConfig(text, permissions: 0o600)

        _ = try await manager.switchMode(.chatGPT, helperExecutable: URL(fileURLWithPath: "/tmp/CodexHarbor"))
        let accountText = try String(contentsOf: fixture.paths.configURL, encoding: .utf8)
        #expect(accountText.contains("view_image = true"))
        #expect(accountText.contains("model = \"gpt-5.6-sol\""))
        #expect(accountText.contains("CODEX HARBOR MANAGED CONFIG"))

        _ = try await manager.switchMode(.harbor, helperExecutable: URL(fileURLWithPath: "/tmp/CodexHarbor"))
        #expect(try String(contentsOf: fixture.paths.configURL, encoding: .utf8).contains("view_image = true"))
        _ = try await manager.uninstall()
        let uninstalledText = try String(contentsOf: fixture.paths.configURL, encoding: .utf8)
        #expect(uninstalledText.contains("view_image = true"))
        #expect(!uninstalledText.contains("CODEX HARBOR MANAGED CONFIG"))
    }

    @Test("Damaged managed markers still block switching")
    func rejectsDamagedManagedBlock() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let manager = fixture.manager()
        _ = try await manager.deploy(.init(
            token: "token",
            apiBaseURL: URL(string: "https://gateway.example.com/v1")!,
            model: "gpt-5.4",
            helperExecutable: URL(fileURLWithPath: "/tmp/CodexHarbor")
        ))
        var text = try String(contentsOf: fixture.paths.configURL, encoding: .utf8)
        text = text.replacingOccurrences(of: "# <<< CODEX HARBOR MANAGED CONFIG <<<", with: "")
        try fixture.writeConfig(text, permissions: 0o600)

        do {
            _ = try await manager.switchMode(.chatGPT, helperExecutable: URL(fileURLWithPath: "/tmp/CodexHarbor"))
            Issue.record("Expected damaged managed block to be rejected")
        } catch let error as HarborError {
            guard case .invalidConfiguration = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
        }
    }

    @Test("Switching to account mode upgrades legacy configuration and keeps the provider available")
    func acceptsAlreadyRestoredAccountConfiguration() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let original = "model = \"gpt-5.6-sol\"\napproval_policy = \"on-request\"\n"
        try fixture.writeConfig(original, permissions: 0o600)
        try fixture.writeAuth(try JSONSerialization.data(withJSONObject: [
            "tokens": ["account_id": "account", "access_token": "session"]
        ]))
        let executable = URL(fileURLWithPath: "/tmp/CodexHarbor")
        let manager = fixture.manager()
        _ = try await manager.deploy(.init(
            token: "token",
            apiBaseURL: URL(string: "https://gateway.example.com/v1")!,
            model: "gpt-5.4",
            helperExecutable: executable
        ))

        try fixture.writeConfig(original + "\n[features]\nview_image = true\n", permissions: 0o600)
        let switched = try await manager.switchMode(.chatGPT, helperExecutable: executable)

        #expect(switched.activeMode == .chatGPT)
        let accountText = try String(contentsOf: fixture.paths.configURL, encoding: .utf8)
        #expect(accountText.contains("model = \"gpt-5.6-sol\""))
        #expect(accountText.contains("view_image = true"))
        #expect(accountText.contains("CODEX HARBOR MANAGED CONFIG"))
    }

    @Test("Reserved provider namespace is never overwritten")
    func rejectsNamespaceCollision() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.writeConfig("[model_providers.codex_harbor]\nname = \"Mine\"\n", permissions: 0o600)
        let before = try Data(contentsOf: fixture.paths.configURL)
        let manager = fixture.manager()
        do {
            _ = try await manager.deploy(.init(
                token: "token",
                apiBaseURL: URL(string: "https://gateway.example.com/v1")!,
                model: "gpt-5.4",
                helperExecutable: URL(fileURLWithPath: "/tmp/CodexHarbor")
            ))
            Issue.record("Expected namespace collision")
        } catch let error as HarborError {
            #expect(error == .existingManagedNamespace)
        }
        #expect(try Data(contentsOf: fixture.paths.configURL) == before)
    }

    @Test("All persisted tasks migrate to the current provider with a rollback backup")
    func migratesAllPersistedTaskRouting() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let taskID = "01a00000-0000-7000-8000-000000000001"
        let rolloutURL = fixture.paths.sessionsURL
            .appendingPathComponent("2026/09/01", isDirectory: true)
            .appendingPathComponent("rollout-test.jsonl")
        try FileManager.default.createDirectory(
            at: rolloutURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let originalTail = #"{"type":"event_msg","payload":{"message":"keep-history"}}"# + "\n"
        let metadata: [String: Any] = [
            "type": "session_meta",
            "payload": [
                "id": taskID,
                "model_provider": "openai",
                "cwd": "/tmp/project"
            ]
        ]
        var rollout = try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys])
        rollout.append(0x0A)
        rollout.append(Data(originalTail.utf8))
        try rollout.write(to: rolloutURL)

        let databaseURL = fixture.paths.codexHome.appendingPathComponent("state_5.sqlite")
        try createThreadDatabase(
            at: databaseURL,
            taskID: taskID,
            provider: "openai",
            model: "gpt-5.6-sol"
        )

        let result = try CodexTaskConnectionMigrator(paths: fixture.paths).migrateAllTasks(
            toProvider: "codex_harbor",
            model: "gpt-5.6-terra"
        )

        #expect(result.inspectedTaskCount == 1)
        #expect(result.migratedTaskCount == 1)
        #expect(result.backupURL != nil)
        #expect(result.backupURL.map { FileManager.default.fileExists(atPath: $0.path) } == true)

        let migrated = try Data(contentsOf: rolloutURL)
        let firstLine = Data(migrated.prefix { $0 != 0x0A })
        let root = try #require(JSONSerialization.jsonObject(with: firstLine) as? [String: Any])
        let payload = try #require(root["payload"] as? [String: Any])
        #expect(payload["model_provider"] as? String == "codex_harbor")
        #expect(String(data: migrated, encoding: .utf8)?.hasSuffix(originalTail) == true)

        let routing = try threadRouting(in: databaseURL, taskID: taskID)
        #expect(routing.provider == "codex_harbor")
        #expect(routing.model == "gpt-5.6-terra")

        let backupRollout = try #require(result.backupURL)
            .appendingPathComponent("sessions/2026/09/01/rollout-test.jsonl")
        #expect(try Data(contentsOf: backupRollout) == rollout)

        let repeated = try CodexTaskConnectionMigrator(paths: fixture.paths).migrateAllTasks(
            toProvider: "codex_harbor",
            model: "gpt-5.6-terra"
        )
        #expect(repeated.migratedTaskCount == 0)
        #expect(repeated.backupURL == nil)
    }

    @Test("A malformed rollout stops migration before any task is changed")
    func validatesEveryRolloutBeforeMigration() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let validURL = fixture.paths.sessionsURL.appendingPathComponent("valid.jsonl")
        let invalidURL = fixture.paths.sessionsURL.appendingPathComponent("invalid.jsonl")
        try FileManager.default.createDirectory(at: fixture.paths.sessionsURL, withIntermediateDirectories: true)
        let valid = #"{"type":"session_meta","payload":{"id":"valid-task","model_provider":"openai"}}"#
            + "\n"
        try Data(valid.utf8).write(to: validURL)
        try Data("not-json\n".utf8).write(to: invalidURL)

        #expect(throws: (any Error).self) {
            _ = try CodexTaskConnectionMigrator(paths: fixture.paths).migrateAllTasks(
                toProvider: "codex_harbor",
                model: "gpt-5.6-terra"
            )
        }
        #expect(try String(contentsOf: validURL, encoding: .utf8) == valid)
        #expect(!FileManager.default.fileExists(atPath: fixture.paths.taskMigrationsURL.path))
    }
}

private func createThreadDatabase(
    at url: URL,
    taskID: String,
    provider: String,
    model: String
) throws {
    var database: OpaquePointer?
    guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
        throw HarborError.invalidConfiguration("测试数据库创建失败")
    }
    defer { sqlite3_close(database) }
    let escapedID = taskID.replacingOccurrences(of: "'", with: "''")
    let escapedProvider = provider.replacingOccurrences(of: "'", with: "''")
    let escapedModel = model.replacingOccurrences(of: "'", with: "''")
    let sql = """
    CREATE TABLE threads (
        id TEXT PRIMARY KEY,
        model_provider TEXT NOT NULL,
        model TEXT
    );
    INSERT INTO threads (id, model_provider, model)
    VALUES ('\(escapedID)', '\(escapedProvider)', '\(escapedModel)');
    """
    guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
        throw HarborError.invalidConfiguration("测试数据库写入失败")
    }
}

private func threadRouting(in url: URL, taskID: String) throws -> (provider: String, model: String?) {
    var database: OpaquePointer?
    guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
          let database else {
        throw HarborError.invalidConfiguration("测试数据库读取失败")
    }
    defer { sqlite3_close(database) }
    var statement: OpaquePointer?
    let sql = "SELECT model_provider, model FROM threads WHERE id = ?"
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
          let statement else {
        throw HarborError.invalidConfiguration("测试数据库查询失败")
    }
    defer { sqlite3_finalize(statement) }
    sqlite3_bind_text(statement, 1, taskID, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    guard sqlite3_step(statement) == SQLITE_ROW,
          let providerText = sqlite3_column_text(statement, 0) else {
        throw HarborError.invalidConfiguration("测试任务索引不存在")
    }
    let provider = String(cString: providerText)
    let model = sqlite3_column_text(statement, 1).map { String(cString: $0) }
    return (provider, model)
}

private final class MemorySecretStore: SecretStore, @unchecked Sendable {
    private var values: [HarborSecret: Data] = [:]
    private let lock = NSLock()

    func data(for secret: HarborSecret) throws -> Data? {
        lock.withLock { values[secret] }
    }

    func set(_ data: Data, for secret: HarborSecret) throws {
        lock.withLock { values[secret] = data }
    }

    func remove(_ secret: HarborSecret) throws {
        _ = lock.withLock { values.removeValue(forKey: secret) }
    }
}

private final class Fixture {
    let root: URL
    let paths: CodexPaths
    let store = MemorySecretStore()

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexHarborTests-\(UUID().uuidString)", isDirectory: true)
        paths = CodexPaths(
            codexHome: root.appendingPathComponent("home/.codex", isDirectory: true),
            appSupport: root.appendingPathComponent("support", isDirectory: true)
        )
        try FileManager.default.createDirectory(at: paths.codexHome, withIntermediateDirectories: true)
    }

    func manager() -> CodexConfigurationManager {
        CodexConfigurationManager(paths: paths, store: store)
    }

    func writeConfig(_ value: String, permissions: Int) throws {
        try Data(value.utf8).write(to: paths.configURL)
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: paths.configURL.path)
    }

    func writeAuth(_ data: Data) throws {
        try data.write(to: paths.authURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.authURL.path)
    }

    func permissions() throws -> Int {
        let value = try FileManager.default.attributesOfItem(atPath: paths.configURL.path)[.posixPermissions] as? NSNumber
        return value?.intValue ?? 0
    }

    func authPermissions() throws -> Int {
        let value = try FileManager.default.attributesOfItem(atPath: paths.authURL.path)[.posixPermissions] as? NSNumber
        return value?.intValue ?? 0
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}
