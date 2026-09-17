import Foundation

public enum MCPProtocolVersion {
    public static let modern = "2026-07-28"
    public static let supported = [modern]
}

public struct MCPJSONRPCRequest: Codable, Equatable, Sendable {
    public let jsonrpc: String
    public let id: JSONValue?
    public let method: String
    public let params: [String: JSONValue]?

    public init(
        jsonrpc: String = "2.0",
        id: JSONValue?,
        method: String,
        params: [String: JSONValue]? = nil
    ) {
        self.jsonrpc = jsonrpc
        self.id = id
        self.method = method
        self.params = params
    }
}

public struct MCPJSONRPCError: Codable, Equatable, Sendable {
    public let code: Int
    public let message: String
    public let data: JSONValue?

    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }
}

public struct MCPJSONRPCResponse: Codable, Equatable, Sendable {
    public let jsonrpc: String
    public let id: JSONValue?
    public let result: JSONValue?
    public let error: MCPJSONRPCError?

    public init(id: JSONValue?, result: JSONValue) {
        self.jsonrpc = "2.0"
        self.id = id
        self.result = result
        self.error = nil
    }

    public init(id: JSONValue?, error: MCPJSONRPCError) {
        self.jsonrpc = "2.0"
        self.id = id
        self.result = nil
        self.error = error
    }
}

public struct MCPRequestContext: Sendable {
    public let protocolVersion: String?
    public let methodHeader: String?
    public let nameHeader: String?
    public let approvalGranted: Bool

    public init(
        protocolVersion: String? = MCPProtocolVersion.modern,
        methodHeader: String? = nil,
        nameHeader: String? = nil,
        approvalGranted: Bool = false
    ) {
        self.protocolVersion = protocolVersion
        self.methodHeader = methodHeader
        self.nameHeader = nameHeader
        self.approvalGranted = approvalGranted
    }
}

public actor MCPServer {
    public static let serverName = "Codex Harbor Local"
    public static let serverVersion = "0.1.0"

    private let router: ToolRouter
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(router: ToolRouter) {
        self.router = router
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
    }

    public func handle(
        data: Data,
        context: MCPRequestContext = MCPRequestContext()
    ) async -> Data {
        let response: MCPJSONRPCResponse
        do {
            let request = try decoder.decode(MCPJSONRPCRequest.self, from: data)
            response = await handle(request: request, context: context)
        } catch {
            response = MCPJSONRPCResponse(
                id: nil,
                error: MCPJSONRPCError(code: -32700, message: "Parse error")
            )
        }

        do {
            return try encoder.encode(response)
        } catch {
            return Data(#"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"Internal error"}}"#.utf8)
        }
    }

    public func handle(
        request: MCPJSONRPCRequest,
        context: MCPRequestContext = MCPRequestContext()
    ) async -> MCPJSONRPCResponse {
        guard request.jsonrpc == "2.0" else {
            return errorResponse(id: request.id, code: -32600, message: "Invalid Request")
        }

        if let methodHeader = context.methodHeader, methodHeader != request.method {
            return errorResponse(id: request.id, code: -32600, message: "Mcp-Method header does not match JSON-RPC method")
        }

        if request.method == "server/discover" {
            return MCPJSONRPCResponse(id: request.id, result: discoverResult())
        }

        guard context.protocolVersion == MCPProtocolVersion.modern else {
            return errorResponse(
                id: request.id,
                code: -32600,
                message: "Unsupported MCP protocol version"
            )
        }

        switch request.method {
        case "tools/list":
            return MCPJSONRPCResponse(id: request.id, result: await listToolsResult())

        case "tools/call":
            return await callTool(request: request, context: context)

        default:
            return errorResponse(id: request.id, code: -32601, message: "Method not found")
        }
    }

    private func discoverResult() -> JSONValue {
        completeResult([
            "supportedVersions": .array(MCPProtocolVersion.supported.map(JSONValue.string)),
            "capabilities": .object([
                "tools": .object([:])
            ]),
            "instructions": .string("Use Codex Harbor Local tools to work only inside user-approved local workspace roots."),
            "ttlMs": .number(60_000),
            "cacheScope": .string("private")
        ])
    }

    private func listToolsResult() async -> JSONValue {
        let definitions = await router.definitions()
        let tools = definitions.compactMap { try? JSONValue.encoded($0) }
        return completeResult([
            "tools": .array(tools),
            "ttlMs": .number(60_000),
            "cacheScope": .string("private")
        ])
    }

    private func callTool(
        request: MCPJSONRPCRequest,
        context: MCPRequestContext
    ) async -> MCPJSONRPCResponse {
        let params = request.params ?? [:]
        guard let name = params["name"]?.stringValue else {
            return errorResponse(id: request.id, code: -32602, message: "Missing tool name")
        }
        if let nameHeader = context.nameHeader, nameHeader != name {
            return errorResponse(id: request.id, code: -32600, message: "Mcp-Name header does not match tool name")
        }
        let arguments: [String: JSONValue]
        if let rawArguments = params["arguments"] {
            guard let object = rawArguments.objectValue else {
                return errorResponse(id: request.id, code: -32602, message: "Tool arguments must be an object")
            }
            arguments = object
        } else {
            arguments = [:]
        }

        do {
            let value = try await router.execute(
                name: name,
                arguments: arguments,
                context: ToolExecutionContext(approvalGranted: context.approvalGranted)
            )
            return MCPJSONRPCResponse(
                id: request.id,
                result: completeResult([
                    "content": .array([
                        .object([
                            "type": .string("text"),
                            "text": .string(Self.textRepresentation(of: value))
                        ])
                    ]),
                    "structuredContent": value,
                    "isError": .bool(false)
                ])
            )
        } catch let error as ToolRouterError {
            return errorResponse(id: request.id, code: -32602, message: error.localizedDescription)
        } catch {
            return MCPJSONRPCResponse(
                id: request.id,
                result: completeResult([
                    "content": .array([
                        .object([
                            "type": .string("text"),
                            "text": .string(error.localizedDescription)
                        ])
                    ]),
                    "isError": .bool(true)
                ])
            )
        }
    }

    private func completeResult(_ values: [String: JSONValue]) -> JSONValue {
        var result = values
        result["resultType"] = .string("complete")
        result["_meta"] = .object([
            "io.modelcontextprotocol/serverInfo": .object([
                "name": .string(Self.serverName),
                "version": .string(Self.serverVersion)
            ])
        ])
        return .object(result)
    }

    private func errorResponse(id: JSONValue?, code: Int, message: String) -> MCPJSONRPCResponse {
        MCPJSONRPCResponse(id: id, error: MCPJSONRPCError(code: code, message: message))
    }

    private static func textRepresentation(of value: JSONValue) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else {
            return "Tool completed"
        }
        return String(decoding: pretty, as: UTF8.self)
    }
}
