import Foundation
import Testing
@testable import CodexHarborCore

@Suite("Harbor Relay protocol compatibility")
struct HarborRelayTests {
    @Test("Relay binds only to loopback and returns a structured unavailable response")
    func startsLoopbackServer() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = CodexPaths(
            codexHome: root.appendingPathComponent(".codex", isDirectory: true),
            appSupport: root.appendingPathComponent("support", isDirectory: true)
        )
        let secretStore = LocalSecretStore(url: paths.credentialsURL)
        let testPort: UInt16 = 28473
        let server = HarborRelayServer(paths: paths, secretStore: secretStore, port: testPort)
        try server.start()
        defer { server.stop() }

        let testBaseURL = URL(string: "http://127.0.0.1:\(testPort)/v1")!
        let (data, response) = try await URLSession.shared.data(from: testBaseURL.appendingPathComponent("models"))
        #expect((response as? HTTPURLResponse)?.statusCode == 503)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect((object["error"] as? [String: Any])?["type"] as? String == "harbor_relay_error")
    }

    @Test("Managed provider accepts only the loopback HTTP relay")
    func acceptsLoopbackRelay() throws {
        let configured = try CodexTOMLEditor.applying(
            to: "",
            spec: CodexConfigurationSpec(
                apiBaseURL: RelayConfiguration.localBaseURL,
                model: "kimi-k2",
                helperExecutable: URL(fileURLWithPath: "/Applications/Codex Harbor.app/Contents/MacOS/CodexHarbor")
            )
        )
        #expect(configured.contains("base_url = \"http://127.0.0.1:18473/v1\""))
        #expect(throws: HarborError.invalidBaseURL) {
            _ = try CodexTOMLEditor.applying(
                to: "",
                spec: CodexConfigurationSpec(
                    apiBaseURL: URL(string: "http://example.com/v1")!,
                    model: "kimi-k2",
                    helperExecutable: URL(fileURLWithPath: "/tmp/helper")
                )
            )
        }
    }

    @Test("Relay starts only for an actively selected custom loopback configuration")
    func relayActivationIsIsolated() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = CodexPaths(codexHome: root.appendingPathComponent(".codex"), appSupport: root.appendingPathComponent("support"))
        try FileManager.default.createDirectory(at: paths.codexHome, withIntermediateDirectories: true)

        try Data("model_provider = \"openai\"\n".utf8).write(to: paths.configURL)
        #expect(HarborRelayProcess.shouldRun(paths: paths) == false)

        let local = try CodexTOMLEditor.applying(
            to: "",
            spec: CodexConfigurationSpec(
                apiBaseURL: RelayConfiguration.localBaseURL,
                model: "kimi-k2",
                helperExecutable: URL(fileURLWithPath: "/tmp/helper")
            )
        )
        try Data(local.utf8).write(to: paths.configURL)
        #expect(HarborRelayProcess.shouldRun(paths: paths) == true)

        let hosted = try CodexTOMLEditor.applying(
            to: local,
            spec: CodexConfigurationSpec(
                apiBaseURL: URL(string: "https://codex.ai02.cn/v1")!,
                model: "gpt-5.6-sol",
                helperExecutable: URL(fileURLWithPath: "/tmp/helper")
            )
        )
        try Data(hosted.utf8).write(to: paths.configURL)
        #expect(HarborRelayProcess.shouldRun(paths: paths) == false)
    }

    @Test("Responses usage is parsed without storing response content")
    func parsesResponsesUsage() throws {
        let data = Data(#"{"usage":{"input_tokens":120,"input_tokens_details":{"cached_tokens":20},"output_tokens":30,"output_tokens_details":{"reasoning_tokens":5},"total_tokens":150}}"#.utf8)
        let usage = RelayProtocolCodec.usage(fromResponses: data)
        #expect(usage.inputTokens == 120)
        #expect(usage.cachedInputTokens == 20)
        #expect(usage.outputTokens == 30)
        #expect(usage.reasoningOutputTokens == 5)
        #expect(usage.totalTokens == 150)
        #expect(usage.source == .responseUsage)
    }

    @Test("Native Responses forwarding uses the selected custom profile model")
    func replacesNativeResponsesModel() throws {
        let request = Data(#"{"model":"gpt-5.6-sol","input":"hello"}"#.utf8)
        let converted = try RelayProtocolCodec.responsesRequest(from: request, model: "moonshot-v1-128k")
        let object = try #require(JSONSerialization.jsonObject(with: converted) as? [String: Any])
        #expect(object["model"] as? String == "moonshot-v1-128k")
        #expect(object["input"] as? String == "hello")
    }

    @Test("Responses history becomes Chat Completions messages and drops provider-local reasoning IDs")
    func convertsResponsesRequest() throws {
        let source: [String: Any] = [
            "model": "kimi-k2",
            "instructions": "Be concise",
            "stream": true,
            "input": [
                ["type": "reasoning", "id": "rs_old", "encrypted_content": "secret"],
                ["type": "message", "role": "user", "content": [["type": "input_text", "text": "hello"]]],
                ["type": "function_call", "call_id": "call_1", "name": "shell", "arguments": "{\"cmd\":\"pwd\"}"],
                ["type": "function_call_output", "call_id": "call_1", "output": "/tmp"]
            ],
            "tools": [[
                "type": "function",
                "name": "shell",
                "description": "run",
                "parameters": ["type": "object"]
            ]]
        ]
        let converted = try RelayProtocolCodec.chatRequest(
            fromResponses: JSONSerialization.data(withJSONObject: source),
            defaultModel: "fallback"
        )
        let object = try #require(JSONSerialization.jsonObject(with: converted) as? [String: Any])
        let messages = try #require(object["messages"] as? [[String: Any]])
        #expect(messages.count == 4)
        #expect(messages.contains { ($0["role"] as? String) == "tool" })
        #expect(String(decoding: converted, as: UTF8.self).contains("rs_old") == false)
        #expect((object["stream_options"] as? [String: Any])?["include_usage"] as? Bool == true)
        #expect(object["model"] as? String == "fallback")
    }

    @Test("Chat Completions responses receive valid Responses IDs and usage")
    func convertsChatResponse() throws {
        let chat: [String: Any] = [
            "id": "chatcmpl_external",
            "model": "deepseek-chat",
            "choices": [["message": ["role": "assistant", "content": "done"], "finish_reason": "stop"]],
            "usage": ["prompt_tokens": 10, "completion_tokens": 4, "total_tokens": 14]
        ]
        let data = try RelayProtocolCodec.responsesBody(
            fromChatCompletions: JSONSerialization.data(withJSONObject: chat),
            model: "fallback"
        )
        let response = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect((response["id"] as? String)?.hasPrefix("resp_") == true)
        let output = try #require(response["output"] as? [[String: Any]])
        #expect((output.first?["id"] as? String)?.hasPrefix("msg_") == true)
        #expect((response["usage"] as? [String: Any])?["total_tokens"] as? Int == 14)
    }

    @Test("Chat streaming tool calls become Responses function-call events")
    func convertsStreamingToolCall() throws {
        let sse = """
        data: {"id":"chat","model":"qwen","choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_7","function":{"name":"shell","arguments":"{\\\"cmd\\\":"}}]}}]}

        data: {"id":"chat","model":"qwen","choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\\\"pwd\\\"}"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":8,"completion_tokens":3,"total_tokens":11}}

        data: [DONE]

        """
        let converted = try RelayProtocolCodec.responsesSSE(fromChatCompletions: Data(sse.utf8), model: "qwen")
        let text = String(decoding: converted, as: UTF8.self)
        #expect(text.contains("response.function_call_arguments.done"))
        #expect(text.contains("call_7"))
        #expect(text.contains("resp_"))
        #expect(text.contains("fc_"))
        #expect(text.contains("\"total_tokens\":11"))
    }

    @Test("Old profiles decode with a safe relay protocol default")
    func decodesOldProfile() throws {
        let json = #"{"id":"00000000-0000-0000-0000-000000000001","name":"old","keyFingerprint":"x","apiBaseURL":"https:\/\/api.moonshot.cn\/v1","model":"kimi-k2","kind":"customResponses","provider":"openAICompatible","models":[],"modelsVerified":false,"createdAt":0}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let profile = try decoder.decode(HarborProfile.self, from: Data(json.utf8))
        #expect(profile.relayProtocol == .automatic)
    }
}
