import Darwin
import Foundation
import Network

public enum RelayTokenSource: String, Codable, Sendable {
    case responseUsage
    case providerBilling
    case unavailable
}

public struct RelayUsage: Codable, Equatable, Sendable {
    public var inputTokens: Int
    public var cachedInputTokens: Int
    public var outputTokens: Int
    public var reasoningOutputTokens: Int
    public var totalTokens: Int
    public var billedTokens: Int?
    public var source: RelayTokenSource

    public init(
        inputTokens: Int = 0,
        cachedInputTokens: Int = 0,
        outputTokens: Int = 0,
        reasoningOutputTokens: Int = 0,
        totalTokens: Int = 0,
        billedTokens: Int? = nil,
        source: RelayTokenSource = .unavailable
    ) {
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.outputTokens = outputTokens
        self.reasoningOutputTokens = reasoningOutputTokens
        self.totalTokens = totalTokens
        self.billedTokens = billedTokens
        self.source = source
    }
}

public struct RelayRequestRecord: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let profileID: UUID
    public let startedAt: Date
    public let completedAt: Date
    public let durationMilliseconds: Int
    public let succeeded: Bool
    public let statusCode: Int
    public let model: String?
    public let upstreamProtocol: HarborRelayProtocol
    public let usage: RelayUsage
    public let error: String?

    public init(
        id: String,
        profileID: UUID,
        startedAt: Date,
        completedAt: Date,
        durationMilliseconds: Int,
        succeeded: Bool,
        statusCode: Int,
        model: String?,
        upstreamProtocol: HarborRelayProtocol,
        usage: RelayUsage,
        error: String? = nil
    ) {
        self.id = id
        self.profileID = profileID
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.durationMilliseconds = durationMilliseconds
        self.succeeded = succeeded
        self.statusCode = statusCode
        self.model = model
        self.upstreamProtocol = upstreamProtocol
        self.usage = usage
        self.error = error
    }
}

public struct RelayConfiguration: Codable, Equatable, Sendable {
    public static let host = "127.0.0.1"
    public static let port: UInt16 = 18473
    public static let localBaseURL = URL(string: "http://\(host):\(port)/v1")!

    public let profileID: UUID
    public let upstreamBaseURL: URL
    public let model: String
    public let upstreamProtocol: HarborRelayProtocol

    public init(profileID: UUID, upstreamBaseURL: URL, model: String, upstreamProtocol: HarborRelayProtocol) {
        self.profileID = profileID
        self.upstreamBaseURL = upstreamBaseURL
        self.model = model
        self.upstreamProtocol = upstreamProtocol
    }
}

public struct RelayConfigurationStore {
    private let paths: CodexPaths
    private let fileManager: FileManager

    public init(paths: CodexPaths = .live(), fileManager: FileManager = .default) {
        self.paths = paths
        self.fileManager = fileManager
    }

    public func load() throws -> RelayConfiguration {
        try JSONDecoder().decode(RelayConfiguration.self, from: Data(contentsOf: paths.relayConfigurationURL))
    }

    public func save(_ configuration: RelayConfiguration) throws {
        try fileManager.createDirectory(at: paths.appSupport, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(configuration).write(to: paths.relayConfigurationURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.relayConfigurationURL.path)
    }

    public func clear() throws {
        guard fileManager.fileExists(atPath: paths.relayConfigurationURL.path) else { return }
        try fileManager.removeItem(at: paths.relayConfigurationURL)
    }
}

public struct RelayActivityStore {
    private let paths: CodexPaths
    private let fileManager: FileManager

    public init(paths: CodexPaths = .live(), fileManager: FileManager = .default) {
        self.paths = paths
        self.fileManager = fileManager
    }

    public func load() throws -> [RelayRequestRecord] {
        guard fileManager.fileExists(atPath: paths.relayEventsURL.path) else { return [] }
        return try JSONDecoder().decode([RelayRequestRecord].self, from: Data(contentsOf: paths.relayEventsURL))
    }

    public func append(_ record: RelayRequestRecord, now: Date = Date()) throws {
        let cutoff = now.addingTimeInterval(-30 * 24 * 60 * 60)
        let existing = (try? load()) ?? []
        let records = Array((existing.filter { $0.startedAt >= cutoff && $0.id != record.id } + [record]).suffix(5_000))
        try fileManager.createDirectory(at: paths.appSupport, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(records).write(to: paths.relayEventsURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.relayEventsURL.path)
    }
}

public enum RelayProtocolCodec {
    public static func responsesRequest(from data: Data, model: String) throws -> Data {
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HarborError.invalidConfiguration("Responses 请求不是有效 JSON")
        }
        object["model"] = model
        return try JSONSerialization.data(withJSONObject: object)
    }

    public static func usage(fromResponses data: Data) -> RelayUsage {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return usageFromResponsesSSE(data)
        }
        return usage(from: object["usage"] as? [String: Any])
    }

    public static func usageFromResponsesSSE(_ data: Data) -> RelayUsage {
        var latest = RelayUsage()
        for object in sseObjects(data) {
            let response = object["response"] as? [String: Any]
            let parsed = usage(from: (response?["usage"] ?? object["usage"]) as? [String: Any])
            if parsed.source != .unavailable { latest = parsed }
        }
        return latest
    }

    public static func usage(fromChatCompletions data: Data) -> RelayUsage {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return chatUsage(from: object["usage"] as? [String: Any])
        }
        var latest = RelayUsage()
        for object in sseObjects(data) {
            let parsed = chatUsage(from: object["usage"] as? [String: Any])
            if parsed.source != .unavailable { latest = parsed }
        }
        return latest
    }

    public static func chatRequest(fromResponses data: Data, defaultModel: String) throws -> Data {
        guard var source = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HarborError.invalidConfiguration("Responses 请求不是有效 JSON")
        }
        // Codex's global model can still contain an OpenAI default. The
        // selected custom profile is the source of truth for its upstream
        // model, so never leak that unrelated model ID to the provider.
        source["model"] = defaultModel
        var messages: [[String: Any]] = []
        if let instructions = source["instructions"] as? String, !instructions.isEmpty {
            messages.append(["role": "system", "content": instructions])
        }
        if let input = source["input"] as? String {
            messages.append(["role": "user", "content": input])
        } else if let items = source["input"] as? [[String: Any]] {
            for item in items {
                guard let type = item["type"] as? String else { continue }
                switch type {
                case "message":
                    let role = (item["role"] as? String) ?? "user"
                    messages.append(["role": role, "content": chatContent(item["content"])])
                case "function_call":
                    let callID = (item["call_id"] as? String) ?? "call_\(UUID().uuidString.lowercased())"
                    let toolCall: [String: Any] = [
                        "id": callID,
                        "type": "function",
                        "function": [
                            "name": (item["name"] as? String) ?? "tool",
                            "arguments": (item["arguments"] as? String) ?? "{}"
                        ]
                    ]
                    messages.append(["role": "assistant", "content": NSNull(), "tool_calls": [toolCall]])
                case "function_call_output":
                    messages.append([
                        "role": "tool",
                        "tool_call_id": (item["call_id"] as? String) ?? "call_unknown",
                        "content": stringContent(item["output"])
                    ])
                case "reasoning":
                    // Reasoning IDs and encrypted reasoning are provider-local.
                    // They must never be sent to a Chat Completions endpoint.
                    continue
                default:
                    continue
                }
            }
        }

        var target: [String: Any] = [
            "model": (source["model"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? defaultModel,
            "messages": messages,
            "stream": (source["stream"] as? Bool) ?? false
        ]
        if target["stream"] as? Bool == true {
            target["stream_options"] = ["include_usage": true]
        }
        if let maxTokens = source["max_output_tokens"] { target["max_tokens"] = maxTokens }
        if let temperature = source["temperature"] { target["temperature"] = temperature }
        if let toolChoice = source["tool_choice"] { target["tool_choice"] = toolChoice }
        if let tools = source["tools"] as? [[String: Any]] {
            target["tools"] = tools.compactMap { tool -> [String: Any]? in
                guard (tool["type"] as? String) == "function", let name = tool["name"] as? String else { return nil }
                var function: [String: Any] = ["name": name]
                if let description = tool["description"] { function["description"] = description }
                if let parameters = tool["parameters"] { function["parameters"] = parameters }
                return ["type": "function", "function": function]
            }
        }
        return try JSONSerialization.data(withJSONObject: target)
    }

    public static func responsesBody(fromChatCompletions data: Data, model: String) throws -> Data {
        guard let source = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HarborError.invalidServerResponse
        }
        let choice = (source["choices"] as? [[String: Any]])?.first
        let message = choice?["message"] as? [String: Any]
        let text = stringContent(message?["content"])
        let responseID = normalizedID(source["id"] as? String, prefix: "resp")
        let messageID = normalizedID(nil, prefix: "msg")
        var output: [[String: Any]] = [[
            "id": messageID,
            "type": "message",
            "status": "completed",
            "role": "assistant",
            "content": [["type": "output_text", "text": text, "annotations": []]]
        ]]
        if let calls = message?["tool_calls"] as? [[String: Any]] {
            output.append(contentsOf: calls.compactMap { call in
                guard let function = call["function"] as? [String: Any] else { return nil }
                return [
                    "id": normalizedID(nil, prefix: "fc"),
                    "type": "function_call",
                    "call_id": (call["id"] as? String) ?? "call_\(UUID().uuidString.lowercased())",
                    "name": (function["name"] as? String) ?? "tool",
                    "arguments": (function["arguments"] as? String) ?? "{}",
                    "status": "completed"
                ]
            })
        }
        let usage = chatUsage(from: source["usage"] as? [String: Any])
        let response: [String: Any] = [
            "id": responseID,
            "object": "response",
            "created_at": Int(Date().timeIntervalSince1970),
            "status": "completed",
            "model": (source["model"] as? String) ?? model,
            "output": output,
            "parallel_tool_calls": true,
            "usage": responsesUsageDictionary(usage)
        ]
        return try JSONSerialization.data(withJSONObject: response)
    }

    public static func responsesSSE(fromChatCompletions data: Data, model: String) throws -> Data {
        let chunks = sseObjects(data)
        var text = ""
        var finishReason: String?
        var usage = RelayUsage()
        var resolvedModel = model
        var toolCalls: [Int: (callID: String, name: String, arguments: String)] = [:]
        for chunk in chunks {
            if let value = chunk["model"] as? String { resolvedModel = value }
            if let parsed = chunk["usage"] as? [String: Any] {
                let candidate = chatUsage(from: parsed)
                if candidate.source != .unavailable { usage = candidate }
            }
            guard let choice = (chunk["choices"] as? [[String: Any]])?.first else { continue }
            if let delta = choice["delta"] as? [String: Any] {
                if let fragment = delta["content"] as? String { text += fragment }
                for call in delta["tool_calls"] as? [[String: Any]] ?? [] {
                    let index = (call["index"] as? NSNumber)?.intValue ?? toolCalls.count
                    let function = call["function"] as? [String: Any]
                    let previous = toolCalls[index] ?? ("call_\(UUID().uuidString.lowercased())", "tool", "")
                    toolCalls[index] = (
                        (call["id"] as? String) ?? previous.callID,
                        (function?["name"] as? String) ?? previous.name,
                        previous.arguments + ((function?["arguments"] as? String) ?? "")
                    )
                }
            }
            if let value = choice["finish_reason"] as? String { finishReason = value }
        }
        let responseID = normalizedID(nil, prefix: "resp")
        let baseResponse: [String: Any] = [
            "id": responseID, "object": "response", "created_at": Int(Date().timeIntervalSince1970),
            "status": "in_progress", "model": resolvedModel, "output": []
        ]
        var sequence = 0
        var events: [[String: Any]] = [["type": "response.created", "sequence_number": sequence, "response": baseResponse]]
        sequence += 1
        var completedOutput: [[String: Any]] = []
        if !text.isEmpty || toolCalls.isEmpty {
            let messageID = normalizedID(nil, prefix: "msg")
            let item: [String: Any] = ["id": messageID, "type": "message", "status": "in_progress", "role": "assistant", "content": []]
            let outputIndex = completedOutput.count
            events.append(["type": "response.output_item.added", "sequence_number": sequence, "output_index": outputIndex, "item": item]); sequence += 1
            events.append(["type": "response.content_part.added", "sequence_number": sequence, "item_id": messageID, "output_index": outputIndex, "content_index": 0, "part": ["type": "output_text", "text": "", "annotations": []]]); sequence += 1
            events.append(["type": "response.output_text.delta", "sequence_number": sequence, "item_id": messageID, "output_index": outputIndex, "content_index": 0, "delta": text]); sequence += 1
            events.append(["type": "response.output_text.done", "sequence_number": sequence, "item_id": messageID, "output_index": outputIndex, "content_index": 0, "text": text]); sequence += 1
            events.append(["type": "response.content_part.done", "sequence_number": sequence, "item_id": messageID, "output_index": outputIndex, "content_index": 0, "part": ["type": "output_text", "text": text, "annotations": []]]); sequence += 1
            let completedItem: [String: Any] = ["id": messageID, "type": "message", "status": "completed", "role": "assistant", "content": [["type": "output_text", "text": text, "annotations": []]]]
            events.append(["type": "response.output_item.done", "sequence_number": sequence, "output_index": outputIndex, "item": completedItem]); sequence += 1
            completedOutput.append(completedItem)
        }
        for (_, call) in toolCalls.sorted(by: { $0.key < $1.key }) {
            let outputIndex = completedOutput.count
            let itemID = normalizedID(nil, prefix: "fc")
            let pending: [String: Any] = ["id": itemID, "type": "function_call", "status": "in_progress", "arguments": "", "call_id": call.callID, "name": call.name]
            events.append(["type": "response.output_item.added", "sequence_number": sequence, "output_index": outputIndex, "item": pending]); sequence += 1
            events.append(["type": "response.function_call_arguments.delta", "sequence_number": sequence, "item_id": itemID, "output_index": outputIndex, "delta": call.arguments]); sequence += 1
            events.append(["type": "response.function_call_arguments.done", "sequence_number": sequence, "item_id": itemID, "output_index": outputIndex, "arguments": call.arguments]); sequence += 1
            let completed: [String: Any] = ["id": itemID, "type": "function_call", "status": "completed", "arguments": call.arguments, "call_id": call.callID, "name": call.name]
            events.append(["type": "response.output_item.done", "sequence_number": sequence, "output_index": outputIndex, "item": completed]); sequence += 1
            completedOutput.append(completed)
        }
        let completedResponse: [String: Any] = [
            "id": responseID, "object": "response", "created_at": Int(Date().timeIntervalSince1970),
            "status": finishReason == "length" ? "incomplete" : "completed", "model": resolvedModel,
            "output": completedOutput, "parallel_tool_calls": true, "usage": responsesUsageDictionary(usage)
        ]
        events.append(["type": "response.completed", "sequence_number": sequence, "response": completedResponse])
        let lines = try events.map { object -> String in
            let payload = try JSONSerialization.data(withJSONObject: object)
            let json = String(decoding: payload, as: UTF8.self)
            return "event: \(object["type"] as? String ?? "message")\ndata: \(json)\n\n"
        }.joined()
        return Data(lines.utf8)
    }

    private static func usage(from object: [String: Any]?) -> RelayUsage {
        guard let object else { return RelayUsage() }
        let input = integer(object["input_tokens"])
        let output = integer(object["output_tokens"])
        let total = object["total_tokens"] == nil ? input + output : integer(object["total_tokens"])
        let inputDetails = object["input_tokens_details"] as? [String: Any]
        let outputDetails = object["output_tokens_details"] as? [String: Any]
        return RelayUsage(
            inputTokens: input,
            cachedInputTokens: integer(inputDetails?["cached_tokens"]),
            outputTokens: output,
            reasoningOutputTokens: integer(outputDetails?["reasoning_tokens"]),
            totalTokens: total,
            billedTokens: object["billed_tokens"].map(integer),
            source: (input > 0 || output > 0 || total > 0) ? .responseUsage : .unavailable
        )
    }

    private static func chatUsage(from object: [String: Any]?) -> RelayUsage {
        guard let object else { return RelayUsage() }
        let input = integer(object["prompt_tokens"] ?? object["input_tokens"])
        let output = integer(object["completion_tokens"] ?? object["output_tokens"])
        let total = object["total_tokens"] == nil ? input + output : integer(object["total_tokens"])
        let promptDetails = object["prompt_tokens_details"] as? [String: Any]
        let completionDetails = object["completion_tokens_details"] as? [String: Any]
        return RelayUsage(
            inputTokens: input,
            cachedInputTokens: integer(promptDetails?["cached_tokens"]),
            outputTokens: output,
            reasoningOutputTokens: integer(completionDetails?["reasoning_tokens"]),
            totalTokens: total,
            billedTokens: object["billed_tokens"].map(integer),
            source: (input > 0 || output > 0 || total > 0) ? .responseUsage : .unavailable
        )
    }

    private static func responsesUsageDictionary(_ usage: RelayUsage) -> [String: Any] {
        [
            "input_tokens": usage.inputTokens,
            "input_tokens_details": ["cached_tokens": usage.cachedInputTokens],
            "output_tokens": usage.outputTokens,
            "output_tokens_details": ["reasoning_tokens": usage.reasoningOutputTokens],
            "total_tokens": usage.totalTokens
        ]
    }

    private static func sseObjects(_ data: Data) -> [[String: Any]] {
        String(decoding: data, as: UTF8.self)
            .components(separatedBy: "\n")
            .compactMap { line -> [String: Any]? in
                guard line.hasPrefix("data:") else { return nil }
                let json = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                guard json != "[DONE]", let bytes = json.data(using: .utf8) else { return nil }
                return try? JSONSerialization.jsonObject(with: bytes) as? [String: Any]
            }
    }

    private static func chatContent(_ value: Any?) -> Any {
        if let string = value as? String { return string }
        guard let parts = value as? [[String: Any]] else { return "" }
        let mapped: [[String: Any]] = parts.compactMap { part in
            switch part["type"] as? String {
            case "input_text", "output_text":
                return ["type": "text", "text": (part["text"] as? String) ?? ""]
            case "input_image":
                if let url = part["image_url"] { return ["type": "image_url", "image_url": ["url": url]] }
                return nil
            default: return nil
            }
        }
        return mapped.isEmpty ? "" : mapped
    }

    private static func stringContent(_ value: Any?) -> String {
        if let string = value as? String { return string }
        if let parts = value as? [[String: Any]] {
            return parts.compactMap { ($0["text"] as? String) ?? ($0["content"] as? String) }.joined()
        }
        return ""
    }

    private static func integer(_ value: Any?) -> Int {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) ?? 0 }
        return 0
    }

    private static func normalizedID(_ value: String?, prefix: String) -> String {
        if let value, value.hasPrefix("\(prefix)_") { return value }
        return "\(prefix)_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
    }
}

private struct RelayHTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
}

private struct RelayHTTPResponse {
    let statusCode: Int
    let headers: [String: String]
    let body: Data
}

/// A small loopback-only HTTP server. It never persists prompts or response
/// bodies; only request metadata and usage totals are written to disk.
public final class HarborRelayServer: @unchecked Sendable {
    private let paths: CodexPaths
    private let secretStore: SecretStore
    private let configurationStore: RelayConfigurationStore
    private let activityStore: RelayActivityStore
    private let port: UInt16
    private let queue = DispatchQueue(label: "com.codexharbor.relay", qos: .userInitiated)
    private var listener: NWListener?

    public init(
        paths: CodexPaths = .live(),
        secretStore: SecretStore = LocalSecretStore.liveMigratingLegacyKeychain(),
        port: UInt16 = RelayConfiguration.port
    ) {
        self.paths = paths
        self.secretStore = secretStore
        self.configurationStore = RelayConfigurationStore(paths: paths)
        self.activityStore = RelayActivityStore(paths: paths)
        self.port = port
    }

    public func start() throws {
        guard listener == nil else { return }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let listenerPort = NWEndpoint.Port(rawValue: port)!
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(RelayConfiguration.host), port: listenerPort)
        let listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        let state = RelayListenerStartState()
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.stateUpdateHandler = { listenerState in
            switch listenerState {
            case .ready:
                ready.signal()
            case let .failed(error):
                state.set(error)
                ready.signal()
            default:
                break
            }
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 2) == .success else {
            listener.cancel()
            throw HarborError.invalidConfiguration("Harbor Relay 启动超时")
        }
        if let error = state.error {
            listener.cancel()
            throw HarborError.invalidConfiguration("Harbor Relay 端口不可用：\(error.localizedDescription)")
        }
        self.listener = listener
        try FileManager.default.createDirectory(at: paths.appSupport, withIntermediateDirectories: true)
        try Data("\(ProcessInfo.processInfo.processIdentifier)".utf8).write(to: paths.relayPIDURL, options: .atomic)
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        try? FileManager.default.removeItem(at: paths.relayPIDURL)
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { [weak self] data, _, complete, error in
            guard let self else { return }
            var next = buffer
            if let data { next.append(data) }
            if let request = Self.parseRequest(next) {
                Task {
                    let response = await self.handle(request)
                    self.send(response, on: connection)
                }
            } else if !complete && error == nil && next.count < 8_388_608 {
                self.receive(on: connection, buffer: next)
            } else {
                self.send(Self.errorResponse(400, "请求格式无效"), on: connection)
            }
        }
    }

    private func handle(_ request: RelayHTTPRequest) async -> RelayHTTPResponse {
        guard let configuration = try? configurationStore.load(),
              let token = try? secretStore.string(for: .profileToken(configuration.profileID)),
              !token.isEmpty else {
            return Self.errorResponse(503, "Relay 没有可用连接")
        }
        if request.method == "GET", request.path.hasSuffix("/models") {
            return await forward(request: request, configuration: configuration, token: token, protocol: .responses, record: false)
        }
        guard request.method == "POST", request.path.hasSuffix("/responses") else {
            return Self.errorResponse(404, "Relay 仅支持 /v1/responses 和 /v1/models")
        }
        let protocolToUse: HarborRelayProtocol
        switch configuration.upstreamProtocol {
        case .automatic:
            let direct = await forward(request: request, configuration: configuration, token: token, protocol: .responses, record: false)
            if direct.statusCode != 404 && direct.statusCode != 405 { return record(direct, request: request, configuration: configuration, protocol: .responses) }
            protocolToUse = .chatCompletions
        case let value:
            protocolToUse = value
        }
        let response = await forward(request: request, configuration: configuration, token: token, protocol: protocolToUse, record: false)
        return record(response, request: request, configuration: configuration, protocol: protocolToUse)
    }

    private func forward(
        request: RelayHTTPRequest,
        configuration: RelayConfiguration,
        token: String,
        protocol relayProtocol: HarborRelayProtocol,
        record: Bool
    ) async -> RelayHTTPResponse {
        let endpoint = request.path.hasSuffix("/models") ? "models" : (relayProtocol == .chatCompletions ? "chat/completions" : "responses")
        let url = Self.endpointURL(base: configuration.upstreamBaseURL, endpoint: endpoint)
        var upstream = URLRequest(url: url)
        upstream.httpMethod = request.method
        upstream.timeoutInterval = 300
        upstream.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        upstream.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if request.method == "POST" {
            do {
                upstream.httpBody = relayProtocol == .chatCompletions
                    ? try RelayProtocolCodec.chatRequest(fromResponses: request.body, defaultModel: configuration.model)
                    : try RelayProtocolCodec.responsesRequest(from: request.body, model: configuration.model)
            } catch {
                return Self.errorResponse(400, error.localizedDescription)
            }
        }
        do {
            let (data, rawResponse) = try await URLSession.shared.data(for: upstream)
            guard let response = rawResponse as? HTTPURLResponse else { return Self.errorResponse(502, "上游响应无效") }
            var body = data
            var contentType = response.value(forHTTPHeaderField: "Content-Type") ?? "application/json"
            if relayProtocol == .chatCompletions, response.statusCode < 400, endpoint != "models" {
                let streaming = (try? JSONSerialization.jsonObject(with: request.body) as? [String: Any])?["stream"] as? Bool == true
                body = streaming
                    ? (try RelayProtocolCodec.responsesSSE(fromChatCompletions: data, model: configuration.model))
                    : (try RelayProtocolCodec.responsesBody(fromChatCompletions: data, model: configuration.model))
                contentType = streaming ? "text/event-stream" : "application/json"
            }
            return RelayHTTPResponse(statusCode: response.statusCode, headers: ["Content-Type": contentType], body: body)
        } catch {
            return Self.errorResponse(502, "上游请求失败：\(error.localizedDescription)")
        }
    }

    private func record(
        _ response: RelayHTTPResponse,
        request: RelayHTTPRequest,
        configuration: RelayConfiguration,
        protocol relayProtocol: HarborRelayProtocol
    ) -> RelayHTTPResponse {
        let completedAt = Date()
        let startedAt = request.headers["x-harbor-started-at"].flatMap(Double.init).map(Date.init(timeIntervalSince1970:)) ?? completedAt
        let usage = relayProtocol == .chatCompletions
            ? RelayProtocolCodec.usage(fromResponses: response.body)
            : RelayProtocolCodec.usage(fromResponses: response.body)
        let model = (try? JSONSerialization.jsonObject(with: request.body) as? [String: Any])?["model"] as? String
        let errorText: String? = response.statusCode >= 400 ? Self.safeErrorMessage(response.body) : nil
        let entry = RelayRequestRecord(
            id: "relay:\(UUID().uuidString.lowercased())",
            profileID: configuration.profileID,
            startedAt: startedAt,
            completedAt: completedAt,
            durationMilliseconds: max(0, Int(completedAt.timeIntervalSince(startedAt) * 1000)),
            succeeded: (200..<400).contains(response.statusCode),
            statusCode: response.statusCode,
            model: model ?? configuration.model,
            upstreamProtocol: relayProtocol,
            usage: usage,
            error: errorText
        )
        try? activityStore.append(entry)
        return response
    }

    private func send(_ response: RelayHTTPResponse, on connection: NWConnection) {
        let reason = HTTPURLResponse.localizedString(forStatusCode: response.statusCode)
        var headers = response.headers
        headers["Content-Length"] = "\(response.body.count)"
        headers["Connection"] = "close"
        headers["Access-Control-Allow-Origin"] = "*"
        let head = (["HTTP/1.1 \(response.statusCode) \(reason)"] + headers.map { "\($0.key): \($0.value)" } + ["", ""]).joined(separator: "\r\n")
        var bytes = Data(head.utf8)
        bytes.append(response.body)
        connection.send(content: bytes, completion: .contentProcessed { _ in connection.cancel() })
    }

    private static func parseRequest(_ data: Data) -> RelayHTTPRequest? {
        let separator = Data("\r\n\r\n".utf8)
        guard let range = data.range(of: separator) else { return nil }
        let headerData = data[..<range.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let first = lines.first else { return nil }
        let parts = first.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let headers = lines.dropFirst().reduce(into: [String: String]()) { result, line in
            guard let colon = line.firstIndex(of: ":") else { return }
            result[String(line[..<colon]).lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = range.upperBound
        guard data.count >= bodyStart + contentLength else { return nil }
        var taggedHeaders = headers
        taggedHeaders["x-harbor-started-at"] = "\(Date().timeIntervalSince1970)"
        return RelayHTTPRequest(
            method: String(parts[0]),
            path: String(parts[1]),
            headers: taggedHeaders,
            body: data.subdata(in: bodyStart..<(bodyStart + contentLength))
        )
    }

    private static func endpointURL(base: URL, endpoint: String) -> URL {
        var value = base.absoluteString
        while value.hasSuffix("/") { value.removeLast() }
        if value.hasSuffix("/responses") { value.removeLast("/responses".count) }
        if value.hasSuffix("/chat/completions") { value.removeLast("/chat/completions".count) }
        return URL(string: "\(value)/\(endpoint)")!
    }

    private static func errorResponse(_ code: Int, _ message: String) -> RelayHTTPResponse {
        let body = (try? JSONSerialization.data(withJSONObject: ["error": ["message": message, "type": "harbor_relay_error"]])) ?? Data()
        return RelayHTTPResponse(statusCode: code, headers: ["Content-Type": "application/json"], body: body)
    }

    private static func safeErrorMessage(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let error = object["error"] as? [String: Any], let message = error["message"] as? String { return String(message.prefix(300)) }
        return nil
    }
}

private final class RelayListenerStartState: @unchecked Sendable {
    private let lock = NSLock()
    private var storedError: NWError?

    var error: NWError? {
        lock.withLock { storedError }
    }

    func set(_ error: NWError) {
        lock.withLock { storedError = error }
    }
}

public enum HarborRelayProcess {
    public static func shouldRun(paths: CodexPaths = .live()) -> Bool {
        guard let text = try? String(contentsOf: paths.configURL, encoding: .utf8),
              CodexTOMLEditor.topLevelString(key: "model_provider", in: text) == CodexConfigurationSpec.provider,
              let value = CodexTOMLEditor.string(
                key: "base_url",
                inTable: "model_providers.\(CodexConfigurationSpec.provider)",
                source: text
              ),
              let url = URL(string: value) else { return false }
        return url == RelayConfiguration.localBaseURL
    }

    public static func ensureRunning(executable: URL, paths: CodexPaths = .live()) throws {
        if let data = try? Data(contentsOf: paths.relayPIDURL),
           let text = String(data: data, encoding: .utf8),
           let pid = Int32(text), pid > 1, kill(pid, 0) == 0 {
            return
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["serve-relay"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        for _ in 0..<20 {
            if FileManager.default.fileExists(atPath: paths.relayPIDURL.path) { return }
            Thread.sleep(forTimeInterval: 0.025)
        }
        throw HarborError.invalidConfiguration("Harbor Relay 启动失败")
    }

    public static func stopIfRunning(paths: CodexPaths = .live()) {
        guard let data = try? Data(contentsOf: paths.relayPIDURL),
              let text = String(data: data, encoding: .utf8),
              let pid = Int32(text), pid > 1 else { return }
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", "\(pid)", "-o", "command="]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        let command = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        if command.contains("CodexHarbor"), command.contains("serve-relay") {
            _ = kill(pid, SIGTERM)
        }
        try? FileManager.default.removeItem(at: paths.relayPIDURL)
    }
}
