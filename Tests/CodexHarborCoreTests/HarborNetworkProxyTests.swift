import Foundation
import SQLite3
import Testing
@testable import CodexHarborCore

@Suite("Independent network proxy")
struct HarborNetworkProxyTests {
    @Test("Runtime outbound must match complete node identity, not UI selection")
    func runtimeOutboundVerification() throws {
        let node = HarborProxyNode(
            name: "test", protocolName: "vless", host: "198.51.100.15",
            port: 2096, credential: "00000000-0000-0000-0000-000000000001",
            network: "ws", security: "tls", sni: "example.org",
            headerHost: "cdn.example.org", path: "/ws", fingerprint: "chrome"
        )
        let config = try HarborXrayConfig.make(
            node: node, httpPort: 18080, ruleMode: true, routeVerificationViaProxy: true
        )
        #expect(HarborProxyRuntimeIdentity.matches(configuration: config, node: node))
        var changed = node
        changed.id = "another-local-id"
        changed.name = "Renamed profile"
        #expect(HarborProxyRuntimeIdentity.matches(configuration: config, node: changed))
        changed = node
        changed.host = "198.51.100.20"
        #expect(!HarborProxyRuntimeIdentity.matches(configuration: config, node: changed))
        changed = node
        changed.credential = "00000000-0000-0000-0000-000000000002"
        #expect(!HarborProxyRuntimeIdentity.matches(configuration: config, node: changed))
        changed = node
        changed.sni = "different.example.org"
        #expect(!HarborProxyRuntimeIdentity.matches(configuration: config, node: changed))
        changed = node
        changed.headerHost = "different.example.org"
        #expect(!HarborProxyRuntimeIdentity.matches(configuration: config, node: changed))
        changed = node
        changed.path = "/changed"
        #expect(!HarborProxyRuntimeIdentity.matches(configuration: config, node: changed))
        #expect(!HarborProxyRuntimeIdentity.matches(configuration: Data("{}".utf8), node: node))
    }

    @Test("A real-proxy failure retains its safe diagnostic reason")
    func failedRealProbeReason() {
        let result = HarborProxyProbeResult(
            milliseconds: nil, realTested: true,
            realFailureReason: "HTTPS 超时（TLS / WebSocket / 上游网络）"
        )
        #expect(!result.succeeded)
        #expect(result.realFailureReason?.contains("超时") == true)
    }
    @Test("A single transient failure is pending rather than unavailable")
    func realLatencyAvailabilityStates() {
        let untested = HarborProxyProbeResult(milliseconds: nil, realTested: false)
        let pending = HarborProxyProbeResult(milliseconds: nil, realTested: true,
            consecutiveRealFailures: 1)
        let unavailable = HarborProxyProbeResult(milliseconds: nil, realTested: true,
            consecutiveRealFailures: 2)
        let recovered = HarborProxyProbeResult(milliseconds: 184, realTested: true,
            consecutiveRealFailures: 0)
        #expect(!untested.isConfirmedUnavailable && !untested.isAwaitingRetry)
        #expect(pending.isAwaitingRetry && !pending.isConfirmedUnavailable)
        #expect(unavailable.isConfirmedUnavailable && !unavailable.isAwaitingRetry)
        #expect(recovered.succeeded && !recovered.isConfirmedUnavailable)
    }

    @Test("Failed exit IP lookups back off instead of blocking for one hour")
    func exitGeoIPRetryBackoff() {
        #expect(HarborProxyGeoIPPolicy.retryInterval(afterFailures: 1) == 10)
        #expect(HarborProxyGeoIPPolicy.retryInterval(afterFailures: 2) == 60)
        #expect(HarborProxyGeoIPPolicy.retryInterval(afterFailures: 3) == 600)
        #expect(HarborProxyGeoIPPolicy.retryInterval(afterFailures: 4) == 3600)
        #expect(HarborProxyGeoIPPolicy.retryInterval(afterFailures: 99) == 3600)
    }

    @Test("Workbench fits the minimum-height desktop window without clipping")
    func compactDashboardLayout() {
        let compact = HarborDashboardSizing.resolve(width: 805, height: 585)
        #expect(compact.compact)
        #expect(compact.requiredHeight <= 585)
        #expect(compact.flowHeight >= 208)
        #expect(compact.cardHeight >= 228)
        let regular = HarborDashboardSizing.resolve(width: 1300, height: 900)
        #expect(!regular.compact)
        #expect(regular.cardHeight == 270)
        #expect(regular.requiredHeight <= 900)
    }

    @Test("Compact node rows keep the node name readable at minimum window size")
    func proxyTableAdaptsToWindow() {
        #expect(HarborProxyTableSizing.usesCompactRows(workspaceWidth: 764))
        #expect(HarborProxyTableSizing.usesCompactRows(workspaceWidth: 949))
        #expect(!HarborProxyTableSizing.usesCompactRows(workspaceWidth: 950))
        #expect(!HarborProxyTableSizing.usesCompactRows(workspaceWidth: 1080))
    }

    @Test("Real proxy delay has bounded concurrency and request timeouts")
    func measuredProxyDurationLabel() {
        #expect(HarborProxyMeasurementLabel.measured(197) == "197 ms")
        #expect(HarborProxyMeasurementLabel.explanation.contains("SOCKS5"))
        #expect(HarborProxyMeasurementLabel.explanation.contains("v2rayN"))
        #expect(HarborProxyLatencyPolicy.parallelCount == 4)
        #expect(HarborProxyLatencyPolicy.requestTimeoutSeconds == 5)
        #expect(HarborProxyLatencyPolicy.realPingRequestCount == 2)
        #expect(HarborProxyLatencyPolicy.realPingPauseMilliseconds == 100)
        #expect(HarborProxyLatencyPolicy.listenerStartupTimeoutMilliseconds == 3_000)
        #expect(HarborProxyLatencyPolicy.goodUpperBoundMilliseconds == 1_500)
        #expect(HarborProxyLatencyPolicy.warningUpperBoundMilliseconds == 2_000)
        let result = HarborProxyProbeResult(milliseconds: 1_650)
        #expect(result.milliseconds == 1_650)
        #expect(result.succeeded)
    }

    @Test("Real ping uses v2rayN's selected URL and its default on invalid configuration")
    func v2rayNRealPingTarget() {
        let configured = Data(#"{"SpeedTestItem":{"SpeedPingTestUrl":"http://www.msftconnecttest.com/connecttest.txt"}}"#.utf8)
        #expect(HarborProxyRealPingTarget.resolve(v2rayNConfigurationData: configured).absoluteString
                == "http://www.msftconnecttest.com/connecttest.txt")
        #expect(HarborProxyRealPingTarget.resolve(v2rayNConfigurationData: nil)
                == HarborProxyRealPingTarget.defaultURL)
        let invalid = Data(#"{"SpeedTestItem":{"SpeedPingTestUrl":"file:///etc/passwd"}}"#.utf8)
        #expect(HarborProxyRealPingTarget.resolve(v2rayNConfigurationData: invalid)
                == HarborProxyRealPingTarget.defaultURL)
    }

    @Test("Isolated real ping does not let routing rules bypass the node")
    func realPingRoutesAllViaNode() throws {
        let node = HarborProxyNode(name: "test", protocolName: "vless",
            host: "node.example.com", port: 443,
            credential: "00000000-0000-0000-0000-000000000001")
        let data = try HarborXrayConfig.make(node: node, httpPort: 18080,
            ruleMode: true, routeAllViaProxy: true)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let routing = try #require(json["routing"] as? [String: Any])
        #expect((routing["rules"] as? [[String: Any]])?.isEmpty == true)
    }

    @Test("Real ping batch uses one mixed inbound and matching outbound per node")
    func realPingBatchConfiguration() throws {
        let nodes = ["192.0.2.1", "192.0.2.2"].map { host in
            HarborProxyNode(name: host, protocolName: "vless", host: host,
                port: 443, credential: "00000000-0000-0000-0000-000000000001")
        }
        let data = try HarborXrayConfig.makeRealPingBatch(nodes: nodes, basePort: 18200)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let inbounds = try #require(json["inbounds"] as? [[String: Any]])
        let outbounds = try #require(json["outbounds"] as? [[String: Any]])
        let routing = try #require(json["routing"] as? [String: Any])
        let rules = try #require(routing["rules"] as? [[String: Any]])
        #expect(inbounds.map { $0["port"] as? Int } == [18200, 18201])
        #expect(inbounds.allSatisfy { $0["protocol"] as? String == "mixed" })
        #expect(outbounds.map { $0["tag"] as? String } == ["proxy18200", "proxy18201"])
        #expect(rules.map { $0["inboundTag"] as? [String] } == [["mixed18200"], ["mixed18201"]])
        #expect(rules.map { $0["outboundTag"] as? String } == ["proxy18200", "proxy18201"])
        #expect(HarborProxyLatencyPolicy.realPingBatchSize == 1_000)
    }

    @Test("Failed real probes use bounded retry backoff")
    func failedProbeRetryPolicy() {
        let now = Date(timeIntervalSince1970: 100_000)
        let firstFailure = HarborProxyProbeResult(
            milliseconds: nil, checkedAt: now,
            realTested: true, realCheckedAt: now, consecutiveRealFailures: 1
        )
        #expect(!firstFailure.shouldRetryFailure(now: now.addingTimeInterval(599)))
        #expect(firstFailure.shouldRetryFailure(now: now.addingTimeInterval(600)))
        #expect(firstFailure.effectiveRealCheckedAt == now)
        let repeated = HarborProxyProbeResult(
            milliseconds: nil, checkedAt: now, realTested: true,
            consecutiveRealFailures: 4
        )
        #expect(!repeated.shouldRetryFailure(now: now.addingTimeInterval(86_399)))
        #expect(repeated.shouldRetryFailure(now: now.addingTimeInterval(86_400)))
    }

    @Test("Server GeoIP cache stays valid only for the unchanged resolved IP")
    func serverGeoIPCache() {
        let stored = HarborProxyIPLocation(ip: "8.8.8.8", countryCode: "us")
        #expect(stored.matches("8.8.8.8"))
        #expect(!stored.matches("8.8.4.4"))
        #expect(stored.countryCode == "US")
        #expect(stored.countryName == "美国")
        #expect(stored.flag == "🇺🇸")
        #expect(HarborProxyIPLocation(ip: "1.1.1.1", countryCode: "AU").countryName != "其他")
        let encoded = try? JSONEncoder().encode(stored)
        #expect(encoded != nil)
        #expect((try? JSONDecoder().decode(HarborProxyIPLocation.self, from: encoded!)) == stored)
    }

    @Test("Observed exit country has a stable per-outbound identity and expiry")
    func exitLocationIsNodeBound() throws {
        let node = HarborProxyNode(name: "A", protocolName: "vless",
            host: "172.64.155.175", port: 443, credential: "first")
        var renamed = node
        renamed.id = "renumbered"
        renamed.name = "renamed"
        renamed.customName = "user alias"
        renamed.automaticName = "地区-高速-可用"
        #expect(renamed.endpointSignature == node.endpointSignature)

        let observation = HarborProxyExitLocation(
            location: HarborProxyIPLocation(ip: "104.28.156.124", countryCode: "SG"),
            endpointSignature: node.endpointSignature,
            observedAt: Date(timeIntervalSince1970: 100_000)
        )
        let now = Date(timeIntervalSince1970: 100_050)
        #expect(observation.verifiedLocation(for: renamed, now: now)?.countryCode == "SG")
        var changed = node
        changed.credential = "different"
        #expect(changed.endpointSignature != node.endpointSignature)
        #expect(observation.verifiedLocation(for: changed, now: now) == nil)
        #expect(observation.verifiedLocation(for: node,
            now: now.addingTimeInterval(86_401))?.countryCode == "SG")
        #expect(observation.needsRefresh(for: node,
            now: now.addingTimeInterval(HarborProxyGeoIPPolicy.exitRefreshInterval + 1)))
        let invalid = HarborProxyExitLocation(
            location: HarborProxyIPLocation(ip: "104.28.156.124", countryCode: "ZZ"),
            endpointSignature: node.endpointSignature, observedAt: now
        )
        #expect(invalid.verifiedLocation(for: node, now: now) == nil)
        let encoded = try JSONEncoder().encode(observation)
        #expect(try JSONDecoder().decode(HarborProxyExitLocation.self,
            from: encoded) == observation)
    }

    @Test("Automatic names use each node's observed exit over shared server geography")
    func exitRegionOverridesServerWithoutCrossNodeLeakage() {
        let first = HarborProxyNode(name: "first", protocolName: "vless",
            host: "172.64.155.175", port: 443, credential: "first", subscriptionID: "sub")
        let second = HarborProxyNode(name: "second", protocolName: "vless",
            host: "172.64.155.175", port: 443, credential: "second", subscriptionID: "sub")
        let results = [
            first.id: HarborProxyProbeResult(milliseconds: 100, realTested: true),
            second.id: HarborProxyProbeResult(milliseconds: 100, realTested: true)
        ]
        let names = HarborProxyAutomaticName.refreshed([first, second],
            results: results,
            locations: ["172.64.155.175": HarborProxyIPLocation(
                ip: "172.64.155.175", countryCode: "US")],
            exitLocationsByNodeID: [first.id: HarborProxyIPLocation(
                ip: "104.28.156.124", countryCode: "SG")])
        #expect(names[0].automaticName?.hasPrefix("新加坡-") == true)
        #expect(names[1].automaticName?.hasPrefix("美国-") == true)
    }

    @Test("IPv6 normalization handles brackets, compression and equivalent GeoIP responses")
    func normalizedIPv6ServerAddress() {
        let literal = "2400:cb00:2049:2fac:7a0:eb35:352c:78a5"
        #expect(HarborIPAddress.normalizedLiteral("[\(literal)]") == literal)
        #expect(HarborIPAddress.socketHost("[\(literal)]") == literal)
        #expect(HarborIPAddress.normalizedLiteral("2001:0DB8:0000:0000:0000:0000:0000:0001") == "2001:db8::1")
        #expect(HarborIPAddress.equivalent("[2001:db8::1]", "2001:0db8:0:0:0:0:0:1"))
        #expect(!HarborIPAddress.equivalent("2001:db8::1", "2001:db8::2"))
        #expect(!HarborIPAddress.equivalent("1.1.1.1", "::ffff:1.1.1.1"))
        #expect(HarborIPAddress.socketHost("node.example.com") == "node.example.com")
        #expect(HarborIPAddress.normalizedLiteral("not-an-ip") == nil)
        #expect(HarborIPAddress.normalizedLiteral("[not-an-ip]") == nil)
        #expect(HarborIPAddress.equivalent("[172.64.155.175]", "172.64.155.175"))
    }

    @Test("An unknown GeoIP country never counts as a reusable result")
    func unknownGeoIPCannotBeReused() {
        let unresolved = HarborProxyIPLocation(ip: "2606:4700::1", countryCode: "ZZ")
        #expect(unresolved.matches("[2606:4700:0:0:0:0:0:1]"))
        #expect(unresolved.verifiedCountryCode == nil)
        #expect(unresolved.displayRegion == HarborProxyAutomaticName.unresolvedRegion)
        let verified = HarborProxyIPLocation(ip: "2606:4700:0:0:0:0:0:1", countryCode: "US")
        #expect(verified.matches("[2606:4700::1]"))
        #expect(verified.verifiedCountryCode == "US")
        #expect(!verified.matches("2606:4700::2"))
    }

    @Test("Intentional proxy stop is not confused with an unexpected crash")
    func unexpectedExitDecision() {
        #expect(HarborProxyLivenessPolicy.shouldHandleUnexpectedExit(
            running: true, intentionallyStopping: false,
            processMatches: true, coreAlive: false
        ))
        #expect(!HarborProxyLivenessPolicy.shouldHandleUnexpectedExit(
            running: true, intentionallyStopping: true,
            processMatches: true, coreAlive: false
        ))
        #expect(!HarborProxyLivenessPolicy.shouldHandleUnexpectedExit(
            running: true, intentionallyStopping: false,
            processMatches: false, coreAlive: false
        ))
        #expect(!HarborProxyLivenessPolicy.shouldHandleUnexpectedExit(
            running: true, intentionallyStopping: false,
            processMatches: true, coreAlive: true
        ))
    }

    @Test("Workbench readiness requires a recent successful active-profile check")
    func workbenchReadiness() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(HarborConnectionReadiness.recentlyVerified(
            health: .available("ok"), checkedAt: now.addingTimeInterval(-20), now: now
        ))
        #expect(!HarborConnectionReadiness.recentlyVerified(
            health: .available("ok"), checkedAt: nil, now: now
        ))
        #expect(!HarborConnectionReadiness.recentlyVerified(
            health: .available("ok"), checkedAt: now.addingTimeInterval(-901), now: now
        ))
        #expect(!HarborConnectionReadiness.recentlyVerified(
            health: .unavailable("offline"), checkedAt: now, now: now
        ))
        #expect(!HarborConnectionReadiness.recentlyVerified(
            health: .checking, checkedAt: now, now: now
        ))
    }

    @Test("Editing subscription retains ID and validates name and HTTPS URL")
    func editingSubscription() throws {
        let original = HarborProxySubscription(
            id: "stable-subscription-id", name: "原始订阅",
            url: "https://old.example.com/list?token=old"
        )
        let updated = try original.updated(
            name: "  新订阅名称  ",
            url: "  https://new.example.com/sub?token=secret  "
        )
        #expect(updated.id == original.id)
        #expect(updated.name == "新订阅名称")
        #expect(updated.url == "https://new.example.com/sub?token=secret")
        #expect(original.name == "原始订阅")
        #expect(throws: HarborProxyError.self) {
            try original.updated(name: "  ", url: "https://valid.example.com/sub")
        }
        #expect(throws: HarborProxyError.self) {
            try original.updated(name: "有效名称", url: "http://insecure.example.com/sub")
        }
        #expect(throws: HarborProxyError.self) {
            try original.updated(name: "有效名称", url: "https://")
        }
    }

    @Test("Subscription update preserves matching IDs, favorites, and aliases")
    func stableSubscriptionRefresh() {
        let source = HarborProxyNode(id: "fav-active", name: "old", customName: "我的节点",
            protocolName: "vless", host: "stable.example.com", port: 443,
            credential: "credential", security: "tls", subscriptionID: "group")
        let obsolete = HarborProxyNode(id: "expired", name: "expired",
            protocolName: "vless", host: "expired.example.com", port: 443,
            credential: "old", security: "tls", subscriptionID: "group")
        let unrelated = HarborProxyNode(id: "manual", name: "manual",
            protocolName: "vless", host: "manual.example.com", port: 443,
            credential: "manual", subscriptionID: "")
        let refreshed = HarborProxyNode(id: "generated-id", name: "provider changed name",
            protocolName: "vless", host: "stable.example.com", port: 443,
            credential: "credential", security: "tls", subscriptionID: "group")
        let newNode = HarborProxyNode(id: "new-id", name: "new",
            protocolName: "vless", host: "new.example.com", port: 443,
            credential: "new", subscriptionID: "group")
        let result = HarborProxySubscriptionReconciler.replace(
            current: [source, obsolete, unrelated], incoming: [refreshed, newNode],
            subscriptionID: "group", selectedID: "fav-active", keepActiveConnection: true)
        #expect(result.nodes.count == 3)
        #expect(result.selectedID == "fav-active")
        #expect(!result.retainedActiveNode)
        let stable = result.nodes.first { $0.id == "fav-active" }
        #expect(stable?.name == "provider changed name")
        #expect(stable?.customName == "我的节点")
        #expect(result.nodes.contains { $0.id == "new-id" })
        #expect(result.nodes.contains { $0.id == "manual" })
        #expect(!result.nodes.contains { $0.id == "expired" })
    }

    @Test("Subscription refresh preserves measured order and probes only new or IP-changed nodes")
    func stableMeasuredSubscriptionOrder() {
        let first = HarborProxyNode(id: "first", name: "A", automaticName: "美国-高速-可用-001",
            protocolName: "vless", host: "a.example.com", port: 443, credential: "a",
            subscriptionID: "group")
        let second = HarborProxyNode(id: "second", name: "B", automaticName: "新加坡-中速-可用-001",
            protocolName: "vless", host: "b.example.com", port: 443, credential: "b",
            subscriptionID: "group")
        let reorderedSecond = HarborProxyNode(id: "generated-b", name: "B2", protocolName: "vless",
            host: "b.example.com", port: 443, credential: "b", subscriptionID: "group")
        let reorderedFirst = HarborProxyNode(id: "generated-a", name: "A2", protocolName: "vless",
            host: "a.example.com", port: 443, credential: "a", subscriptionID: "group")
        let added = HarborProxyNode(id: "new", name: "C", protocolName: "vless",
            host: "c.example.com", port: 443, credential: "c", subscriptionID: "group")

        let merged = HarborProxySubscriptionReconciler.replace(
            current: [first, second], incoming: [reorderedSecond, added, reorderedFirst],
            subscriptionID: "group", selectedID: nil, keepActiveConnection: false
        )
        #expect(merged.nodes.map(\.id) == ["first", "second", "new"])
        #expect(merged.nodes[0].automaticName == "美国-高速-可用-001")
        #expect(merged.nodes[1].automaticName == "新加坡-中速-可用-001")

        let requiringProbe = HarborProxySubscriptionRefreshPolicy.nodesRequiringProbe(
            previousNodeIDs: ["first", "second"], refreshedNodes: merged.nodes,
            previousResolvedIPs: ["a.example.com": "192.0.2.1", "b.example.com": "192.0.2.2"],
            currentResolvedIPs: ["a.example.com": "192.0.2.9", "b.example.com": "192.0.2.2",
                                 "c.example.com": "192.0.2.3"]
        )
        #expect(requiringProbe == ["first", "new"])
    }

    @Test("Initial real delay order is fast-first and automatic names use fixed metadata")
    func initialLatencyOrderAndNaming() {
        let slow = HarborProxyNode(id: "slow", name: "slow", protocolName: "vless",
            host: "slow.example.com", port: 443, credential: "slow")
        let failed = HarborProxyNode(id: "failed", name: "failed", protocolName: "vless",
            host: "failed.example.com", port: 443, credential: "failed")
        let fast = HarborProxyNode(id: "fast", name: "fast", protocolName: "vless",
            host: "fast.example.com", port: 443, credential: "fast")
        let results = [
            "slow": HarborProxyProbeResult(milliseconds: 1_740, realTested: true),
            "failed": HarborProxyProbeResult(milliseconds: nil, realTested: true),
            "fast": HarborProxyProbeResult(milliseconds: 596, realTested: true)
        ]
        #expect(HarborProxySubscriptionRefreshPolicy.initialLatencyOrder(
            [slow, failed, fast], results: results
        ).map(\.id) == ["fast", "slow", "failed"])
        #expect(HarborProxyAutomaticName.make(region: "美国", protocolName: "vless", sequence: 1)
                == "美国-VLESS-001")
        #expect(HarborProxyAutomaticName.make(region: "新加坡", protocolName: "trojan", sequence: 2)
                == "新加坡-TROJAN-002")
        #expect(HarborProxyAutomaticName.sequence(from: "美国-高速-可用-017") == 17)
    }

    @Test("Every probe refreshes names from server IP country, never provider remarks")
    func automaticNamesUseServerLocation() {
        let first = HarborProxyNode(id: "first", name: "SIN-SG-old",
            customName: "新加坡-高速-可用-001", protocolName: "vless",
            host: "172.64.155.175", port: 2096, credential: "one", subscriptionID: "group")
        let second = HarborProxyNode(id: "second", name: "NRT-JP-original",
            protocolName: "vless", host: "172.64.229.213", port: 443,
            credential: "two", subscriptionID: "group")
        let results = [
            "first": HarborProxyProbeResult(milliseconds: 609, realTested: true),
            "second": HarborProxyProbeResult(milliseconds: 209, realTested: true)
        ]
        let locations = [
            first.host: HarborProxyIPLocation(ip: first.host, countryCode: "US"),
            second.host: HarborProxyIPLocation(ip: second.host, countryCode: "US")
        ]
        let renamed = HarborProxyAutomaticName.refreshed(
            [first, second], results: results, locations: locations
        )
        #expect(renamed.map(\.automaticName) == ["美国-VLESS-001", "美国-VLESS-002"])
        #expect(renamed[0].displayName == "新加坡-高速-可用-001")
        #expect(renamed[0].customName == "新加坡-高速-可用-001")
        #expect(renamed.map(\.name) == ["SIN-SG-old", "NRT-JP-original"])

        let unknown = HarborProxyAutomaticName.refreshed(
            [first], results: results, locations: [:]
        )
        #expect(unknown[0].automaticName == "待识别-VLESS-001")
        #expect(HarborProxyIPLocation(ip: first.host, countryCode: "ZZ").flag == "🌐")
    }

    @Test("Removed active subscription node stays selected until user switches")
    func retiredActiveSubscriptionNode() {
        let active = HarborProxyNode(id: "active", name: "old",
            protocolName: "vless", host: "old.example.com", port: 443,
            credential: "old", subscriptionID: "group")
        let current = HarborProxyNode(id: "new", name: "new",
            protocolName: "vless", host: "new.example.com", port: 443,
            credential: "new", subscriptionID: "group")
        let running = HarborProxySubscriptionReconciler.replace(
            current: [active], incoming: [current],
            subscriptionID: "group", selectedID: "active", keepActiveConnection: true)
        #expect(running.retainedActiveNode)
        #expect(running.selectedID == "active")
        #expect(running.nodes.first(where: { $0.id == "active" })?.subscriptionID == "")
        #expect(running.nodes.filter { $0.subscriptionID == "group" }.map(\.id) == ["new"])
        let stopped = HarborProxySubscriptionReconciler.replace(
            current: [active], incoming: [current],
            subscriptionID: "group", selectedID: "active", keepActiveConnection: false)
        #expect(!stopped.retainedActiveNode)
        #expect(stopped.selectedID == "new")
        #expect(stopped.nodes.count == 1)
    }

    @Test("Custom node names are validated and survive subscription replacement")
    func customNodeNames() throws {
        let original = HarborProxyNode(
            id: "old", name: "订阅原名", customName: "我的美国节点",
            protocolName: "vless", host: "node.example.com", port: 443,
            credential: "credential", security: "tls"
        )
        let refreshed = HarborProxyNode(
            id: "new", name: "供应商新名称", protocolName: "vless",
            host: "node.example.com", port: 443,
            credential: "credential", security: "tls"
        )
        let result = HarborProxyNodeNaming.preservingCustomNames(
            from: [original], in: [refreshed]
        )
        #expect(result.first?.name == "供应商新名称")
        #expect(result.first?.displayName == "我的美国节点")
        #expect(try HarborProxyNodeNaming.customName("  新名称  ", sourceName: "原名") == "新名称")
        #expect(try HarborProxyNodeNaming.customName("原名", sourceName: "原名") == nil)
        #expect(throws: HarborProxyError.self) {
            try HarborProxyNodeNaming.customName("   ", sourceName: "原名")
        }
    }

    @Test("Local listeners report ready without waiting for outbound HTTPS probes")
    func localStartupReadiness() {
        #expect(HarborProxyStartupPolicy.canPublishListenerReady(xrayRunning: true, portsListening: true))
        #expect(!HarborProxyStartupPolicy.canPublishListenerReady(xrayRunning: false, portsListening: true))
        #expect(!HarborProxyStartupPolicy.canPublishListenerReady(xrayRunning: true, portsListening: false))
    }

    @Test("Node clicks remain selectable and the last click wins during a switch")
    func queuedActivation() {
        var queue = HarborProxyActivationQueue()
        #expect(queue.takeNext() == nil)

        // A first connection must be selectable even when it differs from
        // the saved last node; later clicks overwrite only pending requests.
        queue.enqueue("new-node", restart: false, userInitiated: true)
        #expect(queue.takeNext()?.nodeID == "new-node")
        #expect(queue.takeNext() == nil)

        queue.enqueue("old-node", restart: false, userInitiated: false)
        queue.enqueue("new-node", restart: false, userInitiated: true)
        queue.enqueue("last-clicked-node", restart: true, userInitiated: true)
        let last = queue.takeNext()
        #expect(last?.nodeID == "last-clicked-node")
        #expect(last?.restart == true)
        #expect(last?.userInitiated == true)
        #expect(queue.takeNext() == nil)
    }

    @Test("A node click resumes system proxy takeover after clear")
    func explicitConnectionIntent() {
        #expect(HarborProxyConnectionIntent.shouldManageSystemProxy(
            persistedPreference: false, userInitiated: true
        ))
        #expect(HarborProxyConnectionIntent.shouldManageSystemProxy(
            persistedPreference: true, userInitiated: false
        ))
        #expect(!HarborProxyConnectionIntent.shouldManageSystemProxy(
            persistedPreference: false, userInitiated: false
        ))
    }

    @Test("Local proxy ports are stable and user-configurable")
    func stableListenerPorts() throws {
        #expect(HarborProxyPortPolicy.defaultHTTPPort == 18080)
        #expect(HarborProxyPortPolicy.defaultSOCKSPort == 18081)
        #expect(try HarborProxyPortPolicy.validate(httpPort: 18080) == 18080)
        #expect(try HarborProxyPortPolicy.validate(httpPort: 18082) == 18082)
        #expect(HarborProxyPortPolicy.socksPort(for: 18082) == 18083)
        #expect(throws: HarborProxyError.self) {
            try HarborProxyPortPolicy.validate(httpPort: 1023)
        }
        #expect(throws: HarborProxyError.self) {
            try HarborProxyPortPolicy.validate(httpPort: 65535)
        }
        let node = HarborProxyNode(name: "test", protocolName: "vless",
            host: "node.example.com", port: 443,
            credential: "00000000-0000-0000-0000-000000000001")
        let config = try HarborXrayConfig.make(node: node, httpPort: 18082, ruleMode: false)
        let json = try #require(JSONSerialization.jsonObject(with: config) as? [String: Any])
        let listeners = try #require(json["inbounds"] as? [[String: Any]])
        #expect(listeners.compactMap { $0["port"] as? Int } == [18082, 18083])
    }

    @Test("Xray creates loopback listeners and isolated routing")
    func xrayConfiguration() throws {
        let node = HarborProxyNode(name: "test", protocolName: "vless",
            host: "node.example.com", port: 443,
            credential: "00000000-0000-0000-0000-000000000001",
            network: "ws", security: "tls", sni: "example.com",
            headerHost: "host.example.com", path: "/proxy")
        let bytes = try HarborXrayConfig.make(node: node, httpPort: 18080, ruleMode: true)
        let object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let outbounds = try #require(object["outbounds"] as? [[String: Any]])
        let stream = try #require(outbounds[0]["streamSettings"] as? [String: Any])
        let ws = try #require(stream["wsSettings"] as? [String: Any])
        #expect(ws["host"] as? String == "host.example.com")
        #expect(ws["path"] as? String == "/proxy")
        #expect(ws["headers"] == nil) // Xray deprecates headers.Host for WebSocket.
        let listeners = try #require(object["inbounds"] as? [[String: Any]])
        #expect(listeners.count == 2)
        #expect(listeners.allSatisfy { ($0["listen"] as? String) == "127.0.0.1" })
        #expect(listeners.compactMap { $0["port"] as? Int } == [18080, 18081])
        let rules = try #require(object["routing"] as? [String: Any])
        let entries = try #require(rules["rules"] as? [[String: Any]])
        #expect(entries.count == 4)
        #expect(entries[0]["outboundTag"] as? String == "proxy")
        #expect(entries[0]["domain"] as? [String] == ["domain:gitee.com", "domain:gitee.io"])
        #expect(entries[1]["ip"] as? [String] == ["geoip:private"])
        #expect(entries[2]["domain"] as? [String] == ["geosite:cn"])
        #expect(entries[3]["ip"] as? [String] == ["geoip:cn"])
        let all = try HarborXrayConfig.make(node: node, httpPort: 18080, ruleMode: false)
        let other = try #require(JSONSerialization.jsonObject(with: all) as? [String: Any])
        let allRules = try #require(other["routing"] as? [String: Any])
        #expect((allRules["rules"] as? [[String: Any]])?.count == 2)
        #expect((allRules["rules"] as? [[String: Any]])?.first?["outboundTag"] as? String == "proxy")
    }

    @Test("Health verification domains always use proxy before regional direct routes")
    func healthVerificationRouting() throws {
        let node = HarborProxyNode(name: "test", protocolName: "vless",
            host: "test.example.com", port: 443,
            credential: "00000000-0000-0000-0000-000000000001")
        let data = try HarborXrayConfig.make(
            node: node, httpPort: 18080, ruleMode: true,
            routeVerificationViaProxy: true
        )
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let routing = try #require(json["routing"] as? [String: Any])
        let rules = try #require(routing["rules"] as? [[String: Any]])
        #expect(rules.first?["outboundTag"] as? String == "proxy")
        #expect(rules.first?["domain"] as? [String] == HarborXrayConfig.verificationHosts)
        #expect(HarborXrayConfig.verificationHosts == ["full:www.msftconnecttest.com"])
        let custom = try HarborXrayConfig.make(
            node: node, httpPort: 18080, ruleMode: true,
            routeVerificationViaProxy: true, verificationHost: "www.example.com")
        let customJSON = try #require(JSONSerialization.jsonObject(with: custom) as? [String: Any])
        let customRouting = try #require(customJSON["routing"] as? [String: Any])
        let customRules = try #require(customRouting["rules"] as? [[String: Any]])
        #expect(customRules.first?["domain"] as? [String] == ["full:www.example.com"])
        #expect(rules.dropFirst().contains { $0["domain"] as? [String] == ["geosite:cn"] })
    }

    @Test("Custom forced domains are validated and precede all direct routes")
    func forcedDomainConfiguration() throws {
        let node = HarborProxyNode(name: "fixture", protocolName: "vless",
            host: "proxy.example.net", port: 443,
            credential: "00000000-0000-0000-0000-000000000001")
        let normalized = try HarborProxyDomainRules.normalized(
            ["GITEE.COM", "*.gitee.com", "git.example.com", "Git.Example.com"]
        )
        #expect(normalized == ["gitee.com", "git.example.com"])
        let config = try HarborXrayConfig.make(node: node, httpPort: 18080, ruleMode: true,
                                              forcedProxyDomains: normalized)
        let json = try #require(JSONSerialization.jsonObject(with: config) as? [String: Any])
        let routing = try #require(json["routing"] as? [String: Any])
        let rules = try #require(routing["rules"] as? [[String: Any]])
        #expect(rules.first?["domain"] as? [String] == [
            "domain:gitee.com", "domain:git.example.com"
        ])
        #expect(throws: HarborProxyError.self) {
            try HarborProxyDomainRules.normalized(["https://gitee.com/owner/repo"])
        }
        #expect(throws: HarborProxyError.self) {
            try HarborProxyDomainRules.normalized(["example.com", "geosite:cn"])
        }
        let disabled = try HarborXrayConfig.make(node: node, httpPort: 18080,
                                                  ruleMode: true, forcedProxyDomains: [])
        let disabledJSON = try #require(JSONSerialization.jsonObject(with: disabled) as? [String: Any])
        let disabledRouting = try #require(disabledJSON["routing"] as? [String: Any])
        #expect((disabledRouting["rules"] as? [[String: Any]])?.count == 3)
    }

    @Test("Installed Xray accepts generated rule-mode configuration when available")
    func validatesActualXray() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let bundled = home.appendingPathComponent("Library/Application Support/CodexHarbor/NetworkProxy")
        let legacy = home.appendingPathComponent("Library/Application Support/v2rayN/bin")
        let candidates = [
            (directory: bundled, binary: bundled.appendingPathComponent("xray")),
            (directory: legacy, binary: legacy.appendingPathComponent("xray/xray"))
        ]
        guard let installed = candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0.binary.path)
                && FileManager.default.fileExists(atPath: $0.directory.appendingPathComponent("geosite.dat").path)
                && FileManager.default.fileExists(atPath: $0.directory.appendingPathComponent("geoip.dat").path)
        }) else { return }
        let source = installed.directory
        let binary = installed.binary
        let node = HarborProxyNode(name: "fixture", protocolName: "vless",
            host: "node.example.com", port: 443,
            credential: "00000000-0000-0000-0000-000000000001",
            network: "ws", security: "tls", sni: "node.example.com",
            headerHost: "node.example.com", path: "/")
        let config = try HarborXrayConfig.make(node: node, httpPort: 18080,
                                              ruleMode: true, routeVerificationViaProxy: true)
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: destination) }
        try config.write(to: destination)
        let process = Process()
        process.executableURL = binary
        process.arguments = ["run", "-test", "-config", destination.path]
        process.currentDirectoryURL = source
        process.environment = ProcessInfo.processInfo.environment.merging(["XRAY_LOCATION_ASSET": source.path]) { _, newer in newer }
        let errorOutput = Pipe()
        process.standardOutput = errorOutput
        process.standardError = errorOutput
        try process.run()
        process.waitUntilExit()
        let errorText = String(decoding: errorOutput.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(process.terminationStatus == 0, "Xray load issue: \(errorText)")
    }

    @Test("VLESS share link carries websocket and TLS settings")
    func linkParsing() throws {
        let url = "vless://00000000-0000-0000-0000-000000000001@example.com:443?type=ws&security=tls&path=%2Fsome&host=host.example.com#Test"
        let node = try #require(HarborProxyLinks.parse(url).first)
        #expect(node.protocolName == "vless")
        #expect(node.network == "ws")
        #expect(node.security == "tls")
        #expect(node.path == "/some")
        #expect(node.headerHost == "host.example.com")
    }

    @Test("Optional live selected v2rayN node remains isolated from the macOS proxy")
    func liveSelectedNode() throws {
        guard ProcessInfo.processInfo.environment["HARBOR_LIVE_PROXY_SMOKE"] == "1" else { return }
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/v2rayN")
        let imported = try HarborV2rayNReader.read(at: base)
        guard let selected = imported.nodes.first(where: { $0.id == imported.selectedID }) else {
            Issue.record("当前 v2rayN 节点不存在或不是受支持格式")
            return
        }
        let native = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CodexHarbor/Proxy/xray/xray")
        let embedded = base.appendingPathComponent("bin/xray/xray")
        let binary = FileManager.default.isExecutableFile(atPath: native.path) ? native : embedded
        let config = try HarborXrayConfig.make(node: selected, httpPort: 18150, ruleMode: true)
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("harbor-proxy-smoke-" + UUID().uuidString + ".json")
        try config.write(to: path, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        defer { try? FileManager.default.removeItem(at: path) }

        let xray = Process()
        xray.executableURL = binary
        xray.arguments = ["run", "-config", path.path]
        xray.environment = ProcessInfo.processInfo.environment.merging([
            "XRAY_LOCATION_ASSET": base.appendingPathComponent("bin").path
        ]) { _, new in new }
        xray.standardOutput = FileHandle.nullDevice
        xray.standardError = FileHandle.nullDevice
        try xray.run()
        defer { if xray.isRunning { xray.terminate() } }
        Thread.sleep(forTimeInterval: 1.5)
        #expect(xray.isRunning)
        let curl = Process()
        curl.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        curl.arguments = ["-q", "--fail", "--silent", "--noproxy", "",
                          "--proxy", "http://127.0.0.1:18150",
                          "--connect-timeout", "3", "--max-time", "9",
                          "--output", "/dev/null",
                          "https://www.apple.com/library/test/success.html"]
        curl.standardError = FileHandle.nullDevice
        curl.standardOutput = FileHandle.nullDevice
        try curl.run()
        curl.waitUntilExit()
        #expect(curl.terminationStatus == 0, "选中节点无法完成独立代理联网；macOS 系统代理未更改")
    }

    @Test("v2rayN SQLite reader imports supported nodes read-only, preserving source")
    func sqliteMigration() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let gui = root.appendingPathComponent("guiConfigs")
        try FileManager.default.createDirectory(at: gui, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(#"{"IndexId":"profile-1"}"#.utf8)
            .write(to: gui.appendingPathComponent("guiNConfig.json"))
        var db: OpaquePointer?
        let dbURL = gui.appendingPathComponent("guiNDB.db")
        #expect(sqlite3_open(dbURL.path, &db) == SQLITE_OK)
        let dbValue = try #require(db)
        defer { sqlite3_close(dbValue) }
        let sql = """
        CREATE TABLE ProfileItem (IndexId TEXT,ConfigType TEXT,Address TEXT,Port INTEGER,
          Id TEXT,AlterId INTEGER,Security TEXT,Network TEXT,Remarks TEXT,RequestHost TEXT,
          Path TEXT,StreamSecurity TEXT,Subid TEXT,Flow TEXT,Sni TEXT,
          Fingerprint TEXT,PublicKey TEXT,ShortId TEXT);
        CREATE TABLE SubItem (Id TEXT,Remarks TEXT,Url TEXT);
        INSERT INTO ProfileItem VALUES ('profile-1','5','edge.example.com',443,
          'dummy-uuid',0,'none','ws','Example Node','host.example.com',
          '/demo','tls','subscription-1','','edge.example.com','chrome','','');
        INSERT INTO ProfileItem VALUES ('unsupported','11','other.example.com',443,
          'secret',0,'none','tcp','unsupported','','','tls','','','','','','');
        INSERT INTO SubItem VALUES ('subscription-1','Example','https://example.com/subscribe');
        """
        #expect(sqlite3_exec(dbValue, sql, nil, nil, nil) == SQLITE_OK)
        let before = try Data(contentsOf: dbURL)
        let result = try HarborV2rayNReader.read(at: root)
        #expect(result.nodes.count == 1)
        #expect(result.subscriptions.count == 1)
        #expect(result.selectedID == "profile-1")
        #expect(result.nodes[0].network == "ws")
        #expect(result.nodes[0].subscriptionID == "subscription-1")
        #expect(result.unsupportedCount == 1)
        #expect(try Data(contentsOf: dbURL) == before)
    }
}
