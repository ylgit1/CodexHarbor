import Foundation
import Testing
@testable import ChatGPTBridgeCore

@Suite("Bridge health policy")
struct BridgeHealthPolicyTests {
    @Test("Healthy checks use five minutes and recovery checks use ten seconds")
    func adaptiveHealthIntervals() {
        let healthy = BridgePipelineDiagnostics(nodes: [
            BridgeNodeDiagnostic(id: "agent", title: "Agent", state: .ready, message: "已运行")
        ])
        let recovering = BridgePipelineDiagnostics(nodes: [
            BridgeNodeDiagnostic(id: "tunnel", title: "Tunnel", state: .recovering, message: "正在恢复")
        ])

        #expect(BridgeHealthPolicy.healthInterval(for: healthy) == 300)
        #expect(BridgeHealthPolicy.healthInterval(for: recovering) == 10)
    }

    @Test("Runtime Key refresh remains recoverable while authorization errors fail")
    func runtimeKeyTransientClassification() {
        #expect(BridgeHealthPolicy.isTerminalAuthenticationFailure("Runtime Key 刷新中") == false)
        #expect(BridgeHealthPolicy.isTerminalAuthenticationFailure("控制面暂未成功，正在恢复") == false)
        #expect(BridgeHealthPolicy.isTerminalAuthenticationFailure("OpenAI Tunnel 鉴权失败") == true)
        #expect(BridgeHealthPolicy.isTerminalAuthenticationFailure("HTTP 401 unauthorized") == true)
    }

    @Test("Pipeline diagnostics preserve node health in runtime JSON")
    func pipelineDiagnosticsRoundTrip() throws {
        let checkedAt = Date(timeIntervalSince1970: 12_345)
        let diagnostics = BridgePipelineDiagnostics(nodes: [
            BridgeNodeDiagnostic(
                id: "openai-tunnel",
                title: "OpenAI Tunnel",
                state: .recovering,
                message: "Runtime Key 刷新中",
                lastCheckAt: checkedAt,
                latency: 42,
                details: ["Control Plane：恢复中"]
            )
        ])
        let runtime = BridgeRuntimeState(
            transportProcessRunning: true,
            transportProcessIdentifier: 321,
            health: BridgeHealthSnapshot(
                tunnel: BridgeTunnelHealth(
                    process: BridgeServiceHealth(state: .ready, processIdentifier: 321),
                    runtimeKey: .checking,
                    controlPlane: .recovering,
                    endpoint: .recovering
                )
            ),
            pipelineDiagnostics: diagnostics
        )

        let data = try JSONEncoder().encode(runtime)
        let decoded = try JSONDecoder().decode(BridgeRuntimeState.self, from: data)
        #expect(decoded.transportProcessIdentifier == 321)
        #expect(decoded.health.tunnel.runtimeKey == .checking)
        #expect(decoded.pipelineDiagnostics.nodes.first?.state == .recovering)
        #expect(decoded.pipelineDiagnostics.nodes.first?.message == "Runtime Key 刷新中")
    }

    @Test("Tunnel self-healing restarts after progressive delays")
    func progressiveTunnelRestartDelay() {
        let now = Date(timeIntervalSince1970: 10_000)

        #expect(BridgeHealthPolicy.tunnelSelfHealDelay(for: 0) == 90)
        #expect(BridgeHealthPolicy.tunnelSelfHealDelay(for: 1) == 180)
        #expect(BridgeHealthPolicy.tunnelSelfHealDelay(for: 2) == 300)
        #expect(BridgeHealthPolicy.tunnelSelfHealDelay(for: 20) == 600)

        #expect(BridgeHealthPolicy.shouldRestartTunnel(
            notReadySince: now.addingTimeInterval(-89),
            attempt: 0,
            recoverable: true,
            now: now
        ) == false)
        #expect(BridgeHealthPolicy.shouldRestartTunnel(
            notReadySince: now.addingTimeInterval(-90),
            attempt: 0,
            recoverable: true,
            now: now
        ))
        #expect(BridgeHealthPolicy.shouldRestartTunnel(
            notReadySince: now.addingTimeInterval(-1_000),
            attempt: 0,
            recoverable: false,
            now: now
        ) == false)
    }
}
