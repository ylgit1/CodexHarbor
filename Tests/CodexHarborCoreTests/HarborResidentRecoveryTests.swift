import Darwin
import Foundation
import Testing
import CodexHarborCore
@testable import HarborProxyRuntime

@Suite("Resident runtime recovery", .serialized)
@MainActor
struct HarborResidentRecoveryTests {
    private enum FixtureError: Error { case missingBinary, noPort, runtime(String) }

    private func freePair(_ range: ClosedRange<Int>) throws -> Int {
        for port in stride(from: range.lowerBound, through: range.upperBound, by: 2).shuffled() {
            if !HarborLoopbackTCP.isListening(port) && !HarborLoopbackTCP.isListening(port + 1) {
                return port
            }
        }
        throw FixtureError.noPort
    }

    private func call(_ runtime: HarborProxyAgentRuntime, _ command: HarborProxyAgentCommand) async throws -> HarborProxyAgentSnapshot {
        let reply = await runtime.handle(.init(command), peerPID: getpid())
        if let error = reply.errorCode { throw FixtureError.runtime(error) }
        return try #require(reply.snapshot)
    }

    @Test("Resident reopens fixed listeners, revalidates, and rebuilds a killed real engine")
    func journalAndEngineRecovery() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("harbor-resident-test-\(UUID())")
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let binary = repository.appendingPathComponent("Resources/Xray/arm64/xray")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else { throw FixtureError.missingBinary }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try FileManager.default.copyItem(at: binary, to: root.appendingPathComponent("xray"))
        let port = try freePair(18200...19398)
        let entry = try freePair(28000...28998)
        let id = UUID()
        var identities: [HarborProcessIdentity] = []
        let verify: @MainActor (Int) async -> Bool = { p in
            HarborLoopbackTCP.isListening(p) && HarborLoopbackTCP.isListening(p + 1)
        }
        let original = HarborProxyAgentRuntime(isolatedRoot: root, verification: verify)
        let restored = HarborProxyAgentRuntime(isolatedRoot: root, verification: verify)
        // Emergency cleanup is limited to identities observed from this fixture.
        defer {
            original.releaseListenersForTesting()
            restored.releaseListenersForTesting()
            for identity in identities where identity.isCurrent && identity.matchesExecutable(at: root.appendingPathComponent("xray")) {
                _ = Darwin.kill(identity.pid, SIGTERM)
            }
            if !identities.contains(where: { $0.isCurrent }) {
                try? FileManager.default.removeItem(at: root)
            }
        }
        await original.start()
        _ = try await call(original, .openGateway(port: entry))
        let config = try JSONSerialization.data(withJSONObject: [
            "log": ["loglevel": "warning"],
            "inbounds": [
                ["listen": "127.0.0.1", "port": port, "protocol": "http"],
                ["listen": "127.0.0.1", "port": port + 1, "protocol": "socks", "settings": ["udp": true]]
            ],
            "outbounds": [["protocol": "freedom", "tag": "fixture"]]
        ] as [String: Any])
        let started = try await call(original, .startEngine(id: id, kind: .xray, port: port, configuration: config, dependencies: []))
        let record = try #require(started.engines.first(where: { $0.id == id }))
        identities.append(record.identity)
        let route = HarborProxyAgentRoute(nodeID: "fixture", endpointSignature: String(repeating: "a", count: 64),
            primaryID: id, underlayID: nil, underlayNodeID: nil, warpEndpoint: nil, ruleMode: false,
            forcedDomains: [], localHostAddresses: [:], observedExitIP: nil, engines: [record])
        let committed = try await call(original, .commit(port: entry, route: route, closeOld: false))
        #expect(committed.gateways.first?.routingBackendID == id)
        original.releaseListenersForTesting()
        try await Task.sleep(for: .milliseconds(200))
        await restored.start()
        let before = try await call(restored, .inspect)
        #expect(before.gateways.first?.ready == true)
        #expect(before.gateways.first?.healthy == false)
        #expect(before.gateways.first?.routingBackendID == nil)
        await restored.recoveryCycleForTesting()
        let after = try await call(restored, .inspect)
        #expect(after.gateways.first?.routingBackendID == id)
        #expect(after.gateways.first?.healthy == true)
        #expect(after.engines.first?.identity == record.identity)
        // Kill only the fixture process captured from the isolated runtime.
        try #require(record.identity.isCurrent)
        _ = Darwin.kill(record.identity.pid, SIGKILL)
        for _ in 0..<60 where record.identity.isCurrent {
            try await Task.sleep(for: .milliseconds(50))
        }
        try #require(!record.identity.isCurrent)
        let ui = UUID()
        restored.clientConnected(ui)
        await restored.recoveryCycleForTesting()
        let whileResponsive = try await call(restored, .inspect)
        #expect(whileResponsive.engines.first?.identity == record.identity)
        // The authenticated connection stays attached, but the UI stopped
        // sending heartbeats. Recovery must not wait for an XPC disconnect.
        restored.clientConnected(ui, now: .now - .seconds(21))
        await restored.recoveryCycleForTesting()
        var rebuilt = try await call(restored, .inspect)
        // Recovery has a real retry/backoff policy. Do not require an
        // immediate successful bind when the kernel is still releasing
        // sockets; require fail-closed state until a verified rebuild.
        let deadline = ContinuousClock.now + .seconds(25)
        while rebuilt.gateways.first?.healthy != true && ContinuousClock.now < deadline {
            #expect(rebuilt.gateways.first?.routingBackendID == nil)
            try await Task.sleep(for: .milliseconds(500))
            await restored.recoveryCycleForTesting()
            rebuilt = try await call(restored, .inspect)
        }
        let replacement = try #require(rebuilt.engines.first(where: { $0.id == id }))
        identities.append(replacement.identity)
        #expect(replacement.identity != record.identity)
        #expect(replacement.identity.isCurrent)
        #expect(replacement.configurationDigest == record.configurationDigest)
        #expect(replacement.port == record.port)
        #expect(rebuilt.gateways.first?.routingBackendID == id)
        #expect(rebuilt.gateways.first?.healthy == true)
        _ = try await call(restored, .stopGateway(port: entry))
        let stopped = try await call(restored, .stopEngine(id: id))
        #expect(stopped.engines.isEmpty)
        #expect(stopped.gateways.isEmpty)
        #expect(!replacement.identity.isCurrent)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("proxy-agent-active").path))
    }

    @Test("A failed fixed-entry trial rolls back even if the old route has no connections")
    func rollsBackBeforeRetiringOldEngine() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("harbor-switch-test-\(UUID())")
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let binary = repo.appendingPathComponent("Resources/Xray/arm64/xray")
        let engine = root.appendingPathComponent("xray")
        try fm.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try fm.copyItem(at: binary, to: engine)
        let entry = try freePair(28200...28498)
        let oldID = UUID(), candidateID = UUID()
        var observedEntry: Int?
        var finishTrial: CheckedContinuation<Bool, Never>?
        let runtime = HarborProxyAgentRuntime(isolatedRoot: root, verification: { _ in true },
            switchVerification: { port, id in
                guard id == candidateID else { return true }
                observedEntry = port
                return await withCheckedContinuation { finishTrial = $0 }
            })
        var identities: [HarborProcessIdentity] = []
        defer {
            finishTrial?.resume(returning: false)
            runtime.releaseListenersForTesting()
            for identity in identities where identity.isCurrent && identity.matchesExecutable(at: engine) {
                _ = Darwin.kill(identity.pid, SIGTERM)
            }
            if !identities.contains(where: { $0.isCurrent }) { try? fm.removeItem(at: root) }
        }
        func prepare(_ id: UUID, in ports: ClosedRange<Int>) async throws -> HarborProxyAgentRoute {
            let port = try freePair(ports)
            let config = try JSONSerialization.data(withJSONObject: [
                "log": ["loglevel": "warning"],
                "inbounds": [
                    ["listen": "127.0.0.1", "port": port, "protocol": "http"],
                    ["listen": "127.0.0.1", "port": port + 1, "protocol": "socks", "settings": ["udp": true]]
                ],
                "outbounds": [["protocol": "freedom"]]
            ] as [String: Any])
            let started = try await call(runtime, .startEngine(id: id, kind: .xray, port: port,
                                                              configuration: config, dependencies: []))
            let record = try #require(started.engines.first(where: { $0.id == id }))
            identities.append(record.identity)
            return .init(nodeID: id.uuidString, endpointSignature: String(repeating: "a", count: 64),
                         primaryID: id, underlayID: nil, underlayNodeID: nil, warpEndpoint: nil, ruleMode: false,
                         forcedDomains: [], localHostAddresses: [:], observedExitIP: nil, engines: [record])
        }
        await runtime.start()
        _ = try await call(runtime, .openGateway(port: entry))
        let old = try await prepare(oldID, in: 18300...18598)
        // A usable ordinary route may not have an exit IP observation yet.
        let connected = try await call(runtime, .commit(port: entry, route: old, closeOld: false))
        #expect(connected.gateways.first?.healthy == true)
        #expect(connected.gateways.first?.route?.observedExitIP == nil)
        let candidate = try await prepare(candidateID, in: 18600...18898)
        let transaction = Task { await runtime.handle(.init(.commit(port: entry, route: candidate, closeOld: false)),
                                                      peerPID: getpid()) }
        let deadline = ContinuousClock.now + .seconds(5)
        while finishTrial == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let complete = try #require(finishTrial)
        #expect(observedEntry == entry)
        let trial = try await call(runtime, .inspect)
        #expect(trial.gateways.first?.route?.primaryID == oldID)
        #expect(trial.gateways.first?.routingBackendID == candidateID)
        let prematureStop = await runtime.handle(.init(.stopEngine(id: oldID)), peerPID: getpid())
        #expect(prematureStop.errorCode == "RUNTIME_BUSY")
        finishTrial = nil
        complete.resume(returning: false)
        let rejected = await transaction.value
        #expect(rejected.errorCode == "SWITCH_VERIFICATION_FAILED")
        #expect(rejected.snapshot?.gateways.first?.routingBackendID == oldID)
        #expect(rejected.snapshot?.gateways.first?.healthy == true)
        #expect(old.engines.first?.identity.isCurrent == true)
        let staleExit = await runtime.handle(.init(.recordExit(port: entry, backendID: candidateID, ip: "203.0.113.2")),
                                             peerPID: getpid())
        #expect(staleExit.errorCode != nil)
        let exit = try await call(runtime, .recordExit(port: entry, backendID: oldID, ip: "203.0.113.1"))
        #expect(exit.gateways.first?.route?.observedExitIP == "203.0.113.1")
        _ = try await call(runtime, .stopEngine(id: candidateID))
        _ = try await call(runtime, .stopGateway(port: entry))
        _ = try await call(runtime, .stopEngine(id: oldID))
    }

    @Test("Corrupt journal fails closed without deleting the evidence")
    func damagedJournal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("harbor-resident-test-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("proxy-agent-journal.json")
        let broken = Data("not-json".utf8)
        try broken.write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        let runtime = HarborProxyAgentRuntime(isolatedRoot: root, verification: { _ in true })
        await runtime.start()
        let reply = await runtime.handle(.init(.inspect), peerPID: getpid())
        #expect(reply.errorCode == "JOURNAL_RECOVERY_FAILED")
        #expect(reply.snapshot?.gateways.isEmpty == true)
        #expect(try Data(contentsOf: path) == broken)
    }
}
