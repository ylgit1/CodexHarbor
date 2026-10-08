import Foundation
import Testing
@testable import ChatGPTBridgeCore

/// Opt-in live check. Never runs during the normal test suite. Run only from
/// an independently supervised process: switching modes restarts the Agent.
@Suite("Live HTTPS transport field verification")
struct LiveTransportSwitchTests {
    @Test(
        "Switch to public HTTPS, probe remote MCP, and restore the original tunnel",
        .enabled(if: ProcessInfo.processInfo.environment["CODEX_HARBOR_LIVE_HTTPS_SWITCH"] == "1"),
        .timeLimit(.minutes(4))
    )
    func httpsRoundTrip() async throws {
        let paths = try BridgePaths.live()
        let store = BridgeConfigurationStore(paths: paths)
        let original = try store.load()
        guard original.enabled, original.transportMode == .secureTunnel,
              let https = original.httpsCompatibility, original.secureTunnel != nil else {
            Issue.record("Live test requires a running secure tunnel and saved HTTPS configuration")
            return
        }
        let manager = BridgeLifecycleManager(paths: paths)
        let executable = URL(fileURLWithPath: "/Applications/Codex Harbor.app/Contents/Helpers/HarborChatGPTAgent")
        var findings: [String] = []
        print("FIELD: initial transport secureTunnel")

        // The restore block is always reached after any ordinary HTTPS check
        // failure. An independent watchdog handles abrupt test-process loss.
        do {
            let snapshot = try await manager.switchTransport(
                to: .httpsCompatibility,
                configuration: original,
                agentExecutableURL: executable
            )
            print("FIELD: HTTPS localReady=\(snapshot.localReady)")
            if !snapshot.localReady { findings.append("HTTPS local MCP did not become ready") }

            let remoteReady = await waitForTransport(
                paths: paths, mode: .httpsCompatibility, timeout: 65
            )
            print("FIELD: HTTPS remoteReady=\(remoteReady)")
            if !remoteReady { findings.append("HTTPS remote transport not ready within 65s") }

            if remoteReady {
                do {
                    let token = try BridgeSecretStore(url: paths.credentialsURL)
                        .httpsCompatibilityAccessToken()
                    // Never print token, hostname or URL to the test log.
                    let url = URL(string: "https://\(https.hostname)/mcp/\(token)")!
                    let (getStatus, initializeStatus, listStatus, toolCount, calledWorkspace) = try await probeMCP(url: url)
                    print("FIELD: public GET=\(getStatus) initialize=\(initializeStatus) tools/list=\(listStatus) tools=\(toolCount) tools/call=\(calledWorkspace)")
                    if getStatus != 200 || initializeStatus != 200 ||
                        listStatus != 200 || toolCount != 30 || !calledWorkspace {
                        findings.append("Public HTTPS MCP protocol or read-only tool-call checks did not all succeed")
                    }
                } catch {
                    findings.append("Public HTTPS request failed: \(type(of: error))")
                }
            }
        } catch {
            findings.append("HTTPS switch failed: \(type(of: error))")
            print("FIELD: HTTPS switch error (details withheld)")
        }

        do {
            let current = try store.load()
            let restored = try await manager.switchTransport(
                to: original.transportMode,
                configuration: current,
                agentExecutableURL: executable
            )
            print("FIELD: restore localReady=\(restored.localReady)")
            if !restored.localReady { findings.append("Restored local MCP not ready") }
            let remoteReady = await waitForTransport(
                paths: paths, mode: original.transportMode, timeout: 65
            )
            print("FIELD: restored secureTunnel remoteReady=\(remoteReady)")
            if !remoteReady { findings.append("Original secure tunnel not recovered within 65s") }
        } catch {
            findings.append("RESTORE FAILED (watchdog will recover): \(type(of: error))")
            print("FIELD: restore failed; watchdog required")
        }

        for finding in findings { print("FIELD: \(finding)") }
        #expect(findings.isEmpty)
    }

    private func waitForTransport(
        paths: BridgePaths, mode: BridgeTransportMode, timeout: Int
    ) async -> Bool {
        for _ in 0..<timeout / 2 {
            if let data = try? Data(contentsOf: paths.runtimeURL) {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                if let state = try? decoder.decode(BridgeRuntimeState.self, from: data),
                   state.transportMode == mode,
                   state.agent == .running,
                   state.mcp == .ready,
                   state.remoteEndpointReady,
                   state.tunnel == .connected {
                    return true
                }
            }
            try? await Task.sleep(for: .seconds(2))
        }
        return false
    }

    private func probeMCP(url: URL) async throws -> (Int, Int, Int, Int, Bool) {
        var get = URLRequest(url: url)
        get.httpMethod = "GET"
        get.timeoutInterval = 8
        get.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let (_, getResponse) = try await URLSession.shared.data(for: get)
        let getStatus = (getResponse as? HTTPURLResponse)?.statusCode ?? 0

        func rpc(
            _ method: String, id: Int, session: String? = nil,
            params customParams: [String: Any]? = nil
        ) async throws -> (Int, Data, String?) {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.timeoutInterval = 8
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
            if let session { req.setValue(session, forHTTPHeaderField: "Mcp-Session-Id") }
            let params: [String: Any] = customParams ?? (method == "initialize"
                ? ["protocolVersion": "2026-07-28", "capabilities": [:],
                   "clientInfo": ["name": "CodexHarborFieldTest", "version": "1"]]
                : [:])
            req.httpBody = try JSONSerialization.data(withJSONObject: [
                "jsonrpc": "2.0", "id": id, "method": method, "params": params
            ])
            let (data, response) = try await URLSession.shared.data(for: req)
            let http = response as? HTTPURLResponse
            return (http?.statusCode ?? 0, data, http?.value(forHTTPHeaderField: "Mcp-Session-Id"))
        }

        let (initCode, _, session) = try await rpc("initialize", id: 1)
        let (listCode, listData, _) = try await rpc("tools/list", id: 2, session: session)
        let object = (try? JSONSerialization.jsonObject(with: listData)) as? [String: Any]
        let result = object?["result"] as? [String: Any]
        let count = (result?["tools"] as? [[String: Any]])?.count ?? 0

        // Probe actual public tool execution, not just discovery. Opening the
        // already-authorized workspace is read-only and changes no files.
        let (callCode, callData, _) = try await rpc(
            "tools/call", id: 3, session: session,
            params: [
                "name": "open_workspace",
                "arguments": ["path": FileManager.default.currentDirectoryPath]
            ]
        )
        let callObject = (try? JSONSerialization.jsonObject(with: callData)) as? [String: Any]
        let callResult = callObject?["result"] as? [String: Any]
        let workspaceID = (callResult?["structuredContent"] as? [String: Any])?["workspaceID"] as? String
        let calledWorkspace = callCode == 200 &&
            callResult?["isError"] as? Bool != true &&
            workspaceID != nil
        return (getStatus, initCode, listCode, count, calledWorkspace)
    }
}
