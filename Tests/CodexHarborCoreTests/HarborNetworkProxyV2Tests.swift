import Foundation
import Darwin
import Testing
@testable import CodexHarborCore

@Suite("Network Proxy 2.0 policies")
struct HarborNetworkProxyV2Tests {
    @Test("Heartbeat renewals preserve recovery ownership without holding it forever")
    func controllerLease() {
        let session = UUID()
        let start = ContinuousClock.now
        var lease = HarborProxyControllerLease()
        let acquired = lease.renew(session, now: start)
        let renewed = lease.renew(session, now: start + .seconds(5))
        #expect(acquired)
        #expect(!renewed)
        #expect(lease.liveCount(now: start + .seconds(24)) == 1)
        #expect(lease.liveCount(now: start + .seconds(25)) == 0)
        let reacquired = lease.renew(session, now: start + .seconds(26))
        #expect(reacquired)
        lease.disconnect(session)
        #expect(lease.liveCount(now: start + .seconds(26)) == 0)
    }

    @Test("A concurrent proxy edit stops networksetup before it overwrites the other client")
    func conditionalProxyWrites() throws {
        let original: [String: Any] = ["HTTPEnable": 0, "SOCKSEnable": 0,
                                       "ProxyAutoConfigURLString": "https://old.example.test/pac"]
        let desired = original.merging(["HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": 18080,
                                        "SOCKSEnable": 1, "SOCKSProxy": "127.0.0.1", "SOCKSPort": 18081]) { _, updated in updated }
        var current = original
        var commands: [String] = []
        var readCount = 0
        #expect(throws: HarborSystemProxyNetworkSetup.GuardedWriteFailure.self) {
            try HarborSystemProxyNetworkSetup.applyGuarded(expected: original, desired: desired, read: {
                readCount += 1
                if readCount == 3 {
                    current["SOCKSEnable"] = 1
                    current["SOCKSProxy"] = "other.example.test"
                    current["SOCKSPort"] = 1080
                }
                return current
            }, run: { command in
                commands.append(command[0])
                current["HTTPEnable"] = 1
                current["HTTPProxy"] = "127.0.0.1"
                current["HTTPPort"] = 18080
            })
        }
        #expect(commands == ["-setwebproxy"])
        #expect(current["SOCKSProxy"] as? String == "other.example.test")
        #expect(current["SOCKSPort"] as? Int == 1080)

        // Native rollback must preserve unowned keys like a newly edited PAC URL.
        current["ProxyAutoConfigURLString"] = "https://new.example.test/pac"
        let restored = HarborSystemProxyNetworkSetup.mergingManagedValues(original, into: current)
        #expect(restored["ProxyAutoConfigURLString"] as? String == "https://new.example.test/pac")
    }

    @Test("Latest intent, changed configuration, deadline and network epoch invalidate old work")
    func transactionFence() {
        var fence = HarborConnectionTransactionFence()
        let a = fence.begin(nodeID: "a", endpointSignature: "a1", timeout: .seconds(10))
        #expect(fence.accepts(a, endpointSignature: "a1"))
        #expect(!fence.accepts(a, endpointSignature: "a2"))
        #expect(!fence.accepts(a, endpointSignature: "a1", now: a.deadline))
        let b = fence.begin(nodeID: "b", endpointSignature: "b1", timeout: .seconds(10))
        #expect(!fence.accepts(a, endpointSignature: "a1"))
        fence.finish(a)
        #expect(fence.accepts(b, endpointSignature: "b1"))
        fence.networkChanged()
        #expect(!fence.accepts(b, endpointSignature: "b1"))
        let c = fence.begin(nodeID: "c", endpointSignature: "c1", timeout: .seconds(10))
        fence.invalidate()
        #expect(!fence.accepts(c, endpointSignature: "c1"))
    }

    @Test("Health failures have bounded retries and capped backoff")
    func healthRecovery() {
        var health = HarborProxyHealthPolicy()
        #expect(health.recordFailure() == .recheck(afterSeconds: 3))
        #expect(health.recordFailure() == .recheck(afterSeconds: 5))
        #expect(health.recordFailure() == .recover(afterSeconds: 10))
        let firstRecovery = health.beginRecovery()
        #expect(firstRecovery)
        #expect(health.recoveryFailed() == .recover(afterSeconds: 5))
        let secondRecovery = health.beginRecovery()
        #expect(secondRecovery)
        let beyondLimit = health.beginRecovery()
        #expect(!beyondLimit)
        #expect(health.recoveryFailed() == .cooldown(afterSeconds: 60))
        for delay in [120, 240, 300, 300] {
            health.cooldownElapsed()
            let first = health.beginRecovery()
            let second = health.beginRecovery()
            #expect(first)
            #expect(second)
            #expect(health.recoveryFailed() == .cooldown(afterSeconds: delay))
        }
        health.networkChanged(online: false)
        #expect(health.recordFailure(engineUnavailable: true) == .none)
        let offlineRecovery = health.beginRecovery()
        #expect(!offlineRecovery)
        health.networkChanged(online: true)
        #expect(health.recordFailure(engineUnavailable: true) == .recover(afterSeconds: 0))
        health.recordHealthy()
        #expect(health.failures == 0)
        #expect(health.recoveryAttempts == 0)
    }

    @Test("Process identity uses kernel start time and executable, not just PID")
    func processIdentity() throws {
        let identity = try #require(HarborProcessIdentity.capture(pid: getpid()))
        #expect(identity.isCurrent)
        #expect(!identity.executablePath.isEmpty)
        let encoded = try JSONEncoder().encode(identity)
        #expect(try JSONDecoder().decode(HarborProcessIdentity.self, from: encoded) == identity)
        #expect(HarborProcessIdentity.capture(pid: 1) == nil)
    }

    @Test("SOCKS5 rejects malformed control frames and unsafe UDP endpoints")
    func socks5Safety() {
        let local = Data([5, 0, 0, 1, 127, 0, 0, 1, 0x47, 0x20])
        #expect(HarborSOCKS5Frame.permitsUDPReply(local, forbiddenPorts: [18080, 18081]))
        #expect(!HarborSOCKS5Frame.permitsUDPReply(local, forbiddenPorts: [18208]))
        let external = Data([5, 0, 0, 1, 8, 8, 8, 8, 0, 53])
        #expect(!HarborSOCKS5Frame.permitsUDPReply(external, forbiddenPorts: []))
        let wildcard = Data([5, 0, 0, 1, 0, 0, 0, 0, 0, 53])
        #expect(!HarborSOCKS5Frame.permitsUDPReply(wildcard, forbiddenPorts: []))
        #expect(HarborSOCKS5Frame.parseAddress(Data([5, 1, 0, 3, 255, 65])) == nil)
        #expect(HarborSOCKS5Frame.command(Data([5, 3, 0, 1, 0, 0, 0, 0, 0, 0])) == .udpAssociate)
    }

    @Test("UDP frames reject fragmentation, malformed headers and zero destinations")
    func udpFrames() {
        let packet = Data([0, 0, 0, 1, 192, 0, 2, 9, 0, 53, 42])
        #expect(HarborSOCKS5Frame.udpDestination(packet)?.port == 53)
        #expect(HarborSOCKS5Frame.udpDestination(packet)?.host == "192.0.2.9")
        var fragmented = packet
        fragmented[2] = 1
        #expect(HarborSOCKS5Frame.udpDestination(fragmented) == nil)
        #expect(HarborSOCKS5Frame.udpDestination(Data([0, 0, 0, 3, 100, 65, 0])) == nil)
        #expect(HarborSOCKS5Frame.udpDestination(Data([0, 0, 0, 1, 127, 0, 0, 1, 0, 0])) == nil)
        #expect(HarborSOCKS5Frame.parseAddress(HarborSOCKS5Frame.loopbackReply(port: 49152))?.port == 49152)
    }

    @Test("Resident launch identity is stable across IPC and snapshots distinguish actual routing")
    func agentLaunchProtocol() throws {
        let id = UUID()
        let base = UUID()
        let configuration = Data("fixture".utf8)
        let request = HarborProxyAgentRequest(.startEngine(id: id, kind: .mihomo, port: 18200,
            configuration: configuration, dependencies: [base]))
        let decoded = try JSONDecoder().decode(HarborProxyAgentRequest.self, from: JSONEncoder().encode(request))
        guard case .startEngine(let actual, let kind, let port, let data, let dependencies) = decoded.command else {
            Issue.record("Unexpected decoded command"); return
        }
        #expect(actual == id)
        #expect(kind == .mihomo)
        #expect(port == 18200)
        #expect(data == configuration)
        #expect(dependencies == [base])
        let snapshot = HarborProxyAgentSnapshot(gateways: [
            .init(port: 18080, ready: true, route: nil, healthy: false, lastHealth: nil)
        ], engines: [], pendingLaunchPorts: [id: 18200], operationInProgress: true)
        let restored = try JSONDecoder().decode(HarborProxyAgentSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(restored.pendingLaunchPorts?[id] == 18200)
        #expect(restored.operationInProgress == true)
        #expect(restored.gateways.first?.routingBackendID == nil)
    }

    @Test("Agent protocol round-trips inspection commands without carrying raw proxy credentials")
    func agentProtocol() throws {
        let request = HarborProxyAgentRequest(.openGateway(port: 18080))
        let bytes = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(HarborProxyAgentRequest.self, from: bytes)
        #expect(decoded.version == HarborProxyAgentConstants.protocolVersion)
        guard case .openGateway(let port) = decoded.command else {
            Issue.record("Unexpected decoded command"); return
        }
        #expect(port == 18080)
    }

    @Test("Gateway rules reject loopback recursion without changing selected outbound")
    func configurationProtection() throws {
        #expect(HarborGatewayConfiguration.isLoopback("127.0.0.2"))
        #expect(HarborGatewayConfiguration.isLoopback("::1"))
        #expect(HarborGatewayConfiguration.isLoopback("LOCALHOST."))
        #expect(!HarborGatewayConfiguration.isLoopback("192.168.1.1"))
        let xray = Data(#"{"outbounds":[{"protocol":"vless","tag":"proxy"}],"routing":{"rules":[{"outboundTag":"direct"}]}}"#.utf8)
        let protected = try HarborGatewayConfiguration.protectXray(xray, ports: [18080, 18081])
        let config = try #require(JSONSerialization.jsonObject(with: protected) as? [String: Any])
        let outbounds = try #require(config["outbounds"] as? [[String: Any]])
        #expect(outbounds.first?["tag"] as? String == "proxy")
        #expect(outbounds.last?["protocol"] as? String == "blackhole")
        let routing = try #require(config["routing"] as? [String: Any])
        let rules = try #require(routing["rules"] as? [[String: Any]])
        #expect(rules.first?["port"] as? String == "18080,18081")
        #expect(rules.first?["outboundTag"] as? String == "codexharbor-gateway-denied")
        let mihomo = Data(#"{"rules":["MATCH,selected"]}"#.utf8)
        let protectedMihomo = try HarborGatewayConfiguration.protectMihomo(mihomo, ports: [18080, 18081])
        let document = try #require(JSONSerialization.jsonObject(with: protectedMihomo) as? [String: Any])
        let mihomoRules = try #require(document["rules"] as? [String])
        #expect(mihomoRules.first?.hasSuffix(",REJECT") == true)
        #expect(mihomoRules.last == "MATCH,selected")
    }
}
