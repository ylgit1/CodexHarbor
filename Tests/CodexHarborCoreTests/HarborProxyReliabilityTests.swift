import CryptoKit
import Foundation
import Testing
@testable import CodexHarborCore

@Suite("Network proxy failure and recovery")
struct HarborProxyReliabilityTests {
    @Test("Child commands bound output, waiting time, and cancellation")
    func childProcessLimits() async throws {
        let yes = URL(fileURLWithPath: "/usr/bin/yes")
        let sleep = URL(fileURLWithPath: "/bin/sleep")
        let start = ContinuousClock.now
        await #expect(throws: HarborProxyError.self) {
            _ = try await HarborProxyCommand.run(yes, arguments: [], timeout: 3, outputLimit: 4_096)
        }
        await #expect(throws: HarborProxyError.self) {
            _ = try await HarborProxyCommand.run(sleep, arguments: ["10"], timeout: 0.1)
        }
        let command = Task { try await HarborProxyCommand.run(sleep, arguments: ["10"], timeout: 8) }
        try await Task.sleep(for: .milliseconds(100))
        command.cancel()
        await #expect(throws: CancellationError.self) { _ = try await command.value }
        #expect(start.duration(to: .now) < .seconds(5))
        let result = try await HarborProxyCommand.run(URL(fileURLWithPath: "/bin/echo"),
                                                     arguments: ["ready"], timeout: 2)
        #expect(result.status == 0)
        #expect(String(decoding: result.data, as: UTF8.self) == "ready\n")
    }

    @Test("HTTP rejects oversized streams and unexpected HTTP responses")
    func boundedHTTP() async throws {
        let data = try await fixture("success")
        #expect(data == Data("ready".utf8))
        for path in ["oversize-header", "oversize-stream", "invalid-status"] {
            await #expect(throws: HarborProxyError.self) { _ = try await fixture(path) }
        }
    }

    @Test("A stalled HTTP request finishes on time or when canceled")
    func boundedHTTPWaiting() async throws {
        let start = ContinuousClock.now
        let timed = await #expect(throws: URLError.self) { _ = try await fixture("stall", timeout: 0.15) }
        #expect(timed?.code == .timedOut)
        let pending = Task { try await fixture("stall", timeout: 8) }
        try await Task.sleep(for: .milliseconds(100))
        pending.cancel()
        await #expect(throws: CancellationError.self) { _ = try await pending.value }
        // Shared macOS CI runners can be delayed by concurrent tests; preserve
        // a finite wall-clock bound without assuming sub-3-second scheduling.
        #expect(start.duration(to: .now) < .seconds(8))
    }

    @Test("Denied decryption cannot make a saved configuration writable")
    func unreadableConfigurationRemainsIntact() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("harbor-state-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("state.enc")
        let key = SymmetricKey(size: .bits256)
        let first = HarborProxyStateFile(url: path, emptyState: [String](), legacyState: { nil }, keyProvider: { _ in key })
        #expect(try await first.load().isEmpty)
        try await first.save(["saved subscription"], generation: 2)
        try await first.save(["stale write"], generation: 1)
        let original = try Data(contentsOf: path)
        let denied = HarborProxyStateFile(url: path, emptyState: [String](), legacyState: { ["legacy"] }, keyProvider: { _ in
            throw HarborProxyError.invalid("key denied")
        })
        await #expect(throws: HarborProxyError.self) { _ = try await denied.load() }
        await #expect(throws: HarborProxyError.self) { try await denied.save([], generation: 1) }
        #expect(try Data(contentsOf: path) == original)
        let restored = HarborProxyStateFile(url: path, emptyState: [String](), legacyState: { nil }, keyProvider: { _ in key })
        #expect(try await restored.load() == ["saved subscription"])
    }

    @Test("Proxy restore preserves third-party endpoints, bypass edits and PAC")
    func selectiveRestore() {
        let original: [String: Any] = ["ExceptionsList": ["localhost", "*.example.test"]]
        let managed: [String: Any] = [
            "HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": 18080,
            "HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": 18080,
            "SOCKSEnable": 1, "SOCKSProxy": "127.0.0.1", "SOCKSPort": 18081,
            "ExceptionsList": ["localhost", "build.internal"]
        ]
        var current = managed
        current["HTTPProxy"] = "localhost"
        current["HTTPPort"] = 19080
        current["ProxyAutoConfigEnable"] = 1
        current["ProxyAutoConfigURLString"] = "https://settings.example.test/proxy.pac"
        current["ExceptionsList"] = ["build.internal", "new.internal"]
        let restored = HarborSystemProxyNetworkSetup.restoreValues(current: current, original: original, managed: managed)
        #expect(restored["HTTPPort"] as? Int == 19080)
        #expect(restored["HTTPSEnable"] == nil)
        #expect(restored["SOCKSEnable"] == nil)
        #expect(restored["ProxyAutoConfigEnable"] as? Int == 1)
        #expect(restored["ProxyAutoConfigURLString"] as? String == "https://settings.example.test/proxy.pac")
        #expect(restored["ExceptionsList"] as? [String] == ["new.internal", "*.example.test"])
        #expect(!HarborSystemProxyNetworkSetup.usesLoopback(restored, httpPort: 18080))
    }

    @Test("Hosts aliases only bypass private addresses and yield to forced proxy rules")
    func localAliases() {
        let hosts = """
            127.0.0.1 workspace.test # local site
            192.168.11.20 NAS.internal drive.home
            fd00::9 machine.internal
            ::1 localhost
            203.0.113.40 public.example.test
            10.1.1.8 api.example.test
            """
        let aliases = HarborProxyDomainRules.localHostAliases(in: hosts, forced: ["example.test"])
        #expect(Set(aliases) == ["workspace.test", "nas.internal", "drive.home", "machine.internal", "localhost"])
        let bypass = HarborSystemProxyNetworkSetup.desiredBypass(
            ["*", "*.example.test", "example.test", "private.test"], automatic: ["nas.internal", "NAS.internal"],
            forced: ["api.example.test"])
        #expect(bypass == ["example.test", "private.test", "nas.internal"])
    }

    @Test("Rotation preserves the running profile and transfers its favorite without reusing its ID")
    func rotatingCredentials() throws {
        var existing = HarborProxyNode(id: "active", name: "Old", protocolName: "trojan", host: "node.example.test",
                                       port: 443, credential: "old", security: "tls", subscriptionID: "source")
        existing.customName = "Main"
        var replacement = existing
        replacement.id = "incoming"
        replacement.credential = "new"
        replacement.customName = nil
        let result = HarborProxySubscriptionReconciler.replace(
            current: [existing], incoming: [replacement], subscriptionID: "source",
            selectedID: existing.id, keepActiveConnection: true, preferredNodeIDs: [existing.id])
        let updated = try #require(result.nodes.first { $0.subscriptionID == "source" })
        #expect(result.retainedActiveNode)
        #expect(result.selectedID == existing.id)
        #expect(result.nodes.first { $0.id == existing.id }?.credential == "old")
        #expect(updated.id != existing.id)
        #expect(updated.customName == existing.customName)
        #expect(result.rotatedFavoriteIDs[existing.id] == updated.id)
    }

    @Test("Packaged runtimes validate new proxy routing and hosts rules without opening listeners")
    func packagedRoutingConfig() throws {
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources")
        let xray = resources.appendingPathComponent("Xray/\(architecture)")
        let mihomo = resources.appendingPathComponent("Mihomo/\(architecture)/mihomo")
        guard FileManager.default.isExecutableFile(atPath: mihomo.path),
              FileManager.default.isExecutableFile(atPath: xray.appendingPathComponent("xray").path) else { return }
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent("harbor-routing-\(UUID().uuidString)")
        try fm.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: directory) }
        try fm.createSymbolicLink(at: directory.appendingPathComponent("GeoIP.dat"),
                                  withDestinationURL: xray.appendingPathComponent("geoip.dat"))
        try fm.createSymbolicLink(at: directory.appendingPathComponent("GeoSite.dat"),
                                  withDestinationURL: xray.appendingPathComponent("geosite.dat"))
        let file = directory.appendingPathComponent("dry-config.json")
        let certificate = directory.appendingPathComponent("fixture.crt")
        let privateKey = directory.appendingPathComponent("fixture.key")
        let openssl = try HarborProxyCommand.runBlocking(URL(fileURLWithPath: "/usr/bin/openssl"),
            arguments: ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
                        "-subj", "/CN=offline.test", "-out", certificate.path, "-keyout", privateKey.path],
            timeout: 6, outputLimit: 8_192, captureDiagnostics: true)
        try #require(openssl.status == 0)
        let pem = try String(contentsOf: certificate, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let key = try String(contentsOf: privateKey, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let profile = """
        client
        dev tun
        proto tcp
        remote 192.0.2.1 443
        <ca>
        \(pem)
        </ca>
        <cert>
        \(pem)
        </cert>
        <key>
        \(key)
        </key>
        """
        let node = HarborProxyNode(name: "test", protocolName: "openvpn", host: "192.0.2.1", port: 443,
                                  credential: Data(profile.utf8).base64EncodedString(), network: "tcp")
        let config = try HarborMihomoConfig.make(node: node, httpPort: 19200, ruleMode: true,
            forcedProxyDomains: ["proxy.example.test"], localHosts: ["nas.internal"],
            verificationHost: "health.example.test", localHostAddresses: ["nas.internal": ["192.168.1.2"]])
        #expect(HarborMihomoConfig.matches(configuration: config, node: node))
        try config.write(to: file)
        let openVPN = try HarborProxyCommand.runBlocking(
            mihomo, arguments: ["-t", "-d", directory.path, "-f", file.path], timeout: 8,
            outputLimit: 16_384, captureDiagnostics: true)
        #expect(openVPN.status == 0, Comment(rawValue: String(decoding: openVPN.data.prefix(800), as: UTF8.self)))

        let ordinary = HarborProxyNode(name: "test", protocolName: "vless", host: "192.0.2.2", port: 443,
                                      credential: "00000000-0000-0000-0000-000000000001")
        try HarborXrayConfig.make(node: ordinary, httpPort: 19202, ruleMode: true,
            forcedProxyDomains: ["proxy.example.test"], routeVerificationViaProxy: true,
            verificationHost: "health.example.test", localHosts: ["nas.internal"]).write(to: file)
        let check = try HarborProxyCommand.runBlocking(xray.appendingPathComponent("xray"),
            arguments: ["run", "-test", "-config", file.path], timeout: 8, outputLimit: 16_384,
            captureDiagnostics: true,
            environment: ProcessInfo.processInfo.environment.merging(["XRAY_LOCATION_ASSET": xray.path]) { _, new in new })
        #expect(check.status == 0, Comment(rawValue: String(decoding: check.data.prefix(800), as: UTF8.self)))
    }

    @Test("A partial or stale observation retains the IP without claiming a verified country")
    func observeIPWithoutGeolocation() {
        let node = HarborProxyNode(name: "fixture", protocolName: "trojan", host: "node.example.test", port: 443,
                                  credential: "example")
        let observation = HarborProxyExitLocation(location: .init(ip: "203.0.113.1", countryCode: "ZZ"),
                                                   endpointSignature: node.endpointSignature,
                                                   resolvedServerIP: "192.0.2.1")
        #expect(observation.verifiedLocation(for: node) == nil)
        #expect(observation.observedLocation(for: node)?.ip == "203.0.113.1")
        #expect(observation.observedLocation(for: node, resolvedServerIP: "192.0.2.2") == nil)
        #expect(observation.needsRefresh(for: node))
    }

    private func fixture(_ path: String, timeout: TimeInterval = 2) async throws -> Data {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HarborHTTPFixture.self]
        config.connectionProxyDictionary = [:]
        let url = URL(string: "https://harbor-fixture.test/\(path)")!
        return try await HarborProxyHTTPBody.data(for: URLRequest(url: url), configuration: config,
                                                  limit: 64, timeout: timeout, status: 200..<201).0
    }
}

private final class HarborHTTPFixture: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "harbor-fixture.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let client else { return }
        let scenario = url.lastPathComponent
        let headers = scenario == "oversize-header" ? ["Content-Length": "129"] : [:]
        let response = HTTPURLResponse(url: url, statusCode: scenario == "invalid-status" ? 503 : 200,
                                       httpVersion: "HTTP/1.1", headerFields: headers)!
        client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        switch scenario {
        case "stall": return
        case "oversize-stream":
            client.urlProtocol(self, didLoad: Data(repeating: 65, count: 32))
            client.urlProtocol(self, didLoad: Data(repeating: 66, count: 33))
        case "oversize-header": break
        default: client.urlProtocol(self, didLoad: Data("ready".utf8))
        }
        client.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
