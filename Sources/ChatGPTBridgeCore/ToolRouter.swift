import Foundation

public indirect enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    public var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    public var intValue: Int? {
        guard case .number(let value) = self,
              value.rounded(.towardZero) == value,
              value >= Double(Int.min), value <= Double(Int.max) else { return nil }
        return Int(value)
    }

    public var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }

    public var objectValue: [String: JSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    public var arrayValue: [JSONValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    public static func encoded<T: Encodable>(_ value: T) throws -> JSONValue {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }
}

public struct MCPToolDefinition: Codable, Equatable, Sendable {
    public let name: String
    public let title: String
    public let description: String
    public let inputSchema: JSONValue
    public let annotations: JSONValue?

    public init(
        name: String,
        title: String,
        description: String,
        inputSchema: JSONValue,
        annotations: JSONValue? = nil
    ) {
        self.name = name
        self.title = title
        self.description = description
        self.inputSchema = inputSchema
        self.annotations = annotations
    }
}

public enum ToolRouterError: Error, LocalizedError, Sendable {
    case unknownTool(String)
    case invalidArguments(String)

    public var errorDescription: String? {
        switch self {
        case .unknownTool(let name): return "未知工具：\(name)"
        case .invalidArguments(let message): return "工具参数无效：\(message)"
        }
    }
}

public struct ToolExecutionContext: Sendable {
    public let approvalGranted: Bool

    public init(approvalGranted: Bool = false) {
        self.approvalGranted = approvalGranted
    }
}

public actor ToolRouter {
    private let workspaceManager: WorkspaceManager
    private let openWorkspaceTool: OpenWorkspaceTool
    private let readTool: ReadFileTool
    private let searchTool: SearchTool
    private let editTool: EditFileTool
    private let writeTool: WriteFileTool
    private let shellTool: ShellTool
    private let auditLogger: AuditLogger

    public init(
        workspaceManager: WorkspaceManager,
        configuration: BridgeConfiguration,
        auditLogger: AuditLogger
    ) {
        self.workspaceManager = workspaceManager
        self.auditLogger = auditLogger
        let permissions = PermissionEngine(configuration: configuration)
        self.openWorkspaceTool = OpenWorkspaceTool(workspaceManager: workspaceManager)
        self.readTool = ReadFileTool(workspaceManager: workspaceManager)
        self.searchTool = SearchTool(workspaceManager: workspaceManager)
        self.editTool = EditFileTool(
            workspaceManager: workspaceManager,
            permissionEngine: permissions,
            auditLogger: auditLogger
        )
        self.writeTool = WriteFileTool(
            workspaceManager: workspaceManager,
            permissionEngine: permissions,
            auditLogger: auditLogger
        )
        self.shellTool = ShellTool(
            workspaceManager: workspaceManager,
            permissionEngine: permissions,
            auditLogger: auditLogger
        )
    }

    public func definitions() -> [MCPToolDefinition] {
        Self.toolDefinitions
    }

    public func execute(
        name: String,
        arguments: [String: JSONValue],
        context: ToolExecutionContext = ToolExecutionContext()
    ) async throws -> JSONValue {
        let startedAt = Date()
        do {
            switch name {
            case "open_workspace":
                let path = try requiredString("path", in: arguments)
                let result = try await openWorkspaceTool.execute(path: path)
                await recordReadOnlyAudit(
                    tool: name,
                    workspaceID: result.workspaceID,
                    target: path,
                    status: .success,
                    startedAt: startedAt,
                    summary: "workspace opened"
                )
                return try JSONValue.encoded(result)

            case "read":
                let workspaceID = try workspaceID(in: arguments)
                let path = try requiredString("path", in: arguments)
                let result = try await readTool.execute(
                    workspaceID: workspaceID,
                    path: path,
                    offset: try optionalInt("offset", in: arguments) ?? 1,
                    limit: try optionalInt("limit", in: arguments) ?? ReadFileTool.defaultLineLimit
                )
                await recordReadOnlyAudit(
                    tool: name,
                    workspaceID: workspaceID,
                    target: path,
                    status: .success,
                    startedAt: startedAt,
                    summary: "read lines \(result.startLine)-\(result.endLine)"
                )
                return try JSONValue.encoded(result)

            case "search":
                let workspaceID = try workspaceID(in: arguments)
                let query = try requiredString("query", in: arguments)
                let path = optionalString("path", in: arguments) ?? "."
                let result = try await searchTool.execute(
                    workspaceID: workspaceID,
                    query: query,
                    path: path
                )
                await recordReadOnlyAudit(
                    tool: name,
                    workspaceID: workspaceID,
                    target: path,
                    status: .success,
                    startedAt: startedAt,
                    summary: "\(result.matchLineCount) matches"
                )
                return try JSONValue.encoded(result)

            case "edit":
                let result = try await editTool.execute(
                    workspaceID: try workspaceID(in: arguments),
                    path: try requiredString("path", in: arguments),
                    oldText: try requiredString("oldText", in: arguments),
                    newText: try requiredString("newText", in: arguments),
                    approvalGranted: context.approvalGranted
                )
                return try JSONValue.encoded(result)

            case "write":
                let result = try await writeTool.execute(
                    workspaceID: try workspaceID(in: arguments),
                    path: try requiredString("path", in: arguments),
                    content: try requiredString("content", in: arguments),
                    overwrite: optionalBool("overwrite", in: arguments) ?? false,
                    approvalGranted: context.approvalGranted
                )
                return try JSONValue.encoded(result)

            case "bash":
                let executable = try requiredString("executable", in: arguments)
                let rawArguments = arguments["arguments"]?.arrayValue ?? []
                let commandArguments = try rawArguments.map { value -> String in
                    guard let string = value.stringValue else {
                        throw ToolRouterError.invalidArguments("arguments 必须是字符串数组")
                    }
                    return string
                }
                let result = try await shellTool.execute(
                    workspaceID: try workspaceID(in: arguments),
                    request: CommandRequest(
                        executable: executable,
                        arguments: commandArguments,
                        workingDirectory: optionalString("workingDirectory", in: arguments) ?? ".",
                        timeoutSeconds: try optionalInt("timeoutSeconds", in: arguments) ?? 30
                    ),
                    approvalGranted: context.approvalGranted
                )
                return try JSONValue.encoded(result)

            default:
                throw ToolRouterError.unknownTool(name)
            }
        } catch {
            if ["open_workspace", "read", "search"].contains(name) {
                await recordReadOnlyAudit(
                    tool: name,
                    workspaceID: try? workspaceID(in: arguments),
                    target: arguments["path"]?.stringValue,
                    status: .failure,
                    startedAt: startedAt,
                    summary: error.localizedDescription
                )
            }
            throw error
        }
    }

    private func recordReadOnlyAudit(
        tool: String,
        workspaceID: UUID?,
        target: String?,
        status: AuditStatus,
        startedAt: Date,
        summary: String
    ) async {
        try? await auditLogger.record(AuditEntry(
            tool: tool,
            workspaceID: workspaceID,
            target: target,
            status: status,
            durationMilliseconds: max(0, Int(Date().timeIntervalSince(startedAt) * 1_000)),
            summary: summary
        ))
    }

    private func workspaceID(in arguments: [String: JSONValue]) throws -> UUID {
        let raw = try requiredString("workspaceId", in: arguments)
        guard let id = UUID(uuidString: raw) else {
            throw ToolRouterError.invalidArguments("workspaceId 不是有效 UUID")
        }
        return id
    }

    private func requiredString(_ key: String, in arguments: [String: JSONValue]) throws -> String {
        guard let value = arguments[key]?.stringValue else {
            throw ToolRouterError.invalidArguments("缺少字符串参数 \(key)")
        }
        return value
    }

    private func optionalString(_ key: String, in arguments: [String: JSONValue]) -> String? {
        arguments[key]?.stringValue
    }

    private func optionalBool(_ key: String, in arguments: [String: JSONValue]) -> Bool? {
        arguments[key]?.boolValue
    }

    private func optionalInt(_ key: String, in arguments: [String: JSONValue]) throws -> Int? {
        guard let value = arguments[key] else { return nil }
        guard let integer = value.intValue else {
            throw ToolRouterError.invalidArguments("参数 \(key) 必须是整数")
        }
        return integer
    }

    private static let toolDefinitions: [MCPToolDefinition] = [
        MCPToolDefinition(
            name: "open_workspace",
            title: "Open workspace",
            description: "Open a local project directory that is inside Codex Harbor's allowed roots.",
            inputSchema: objectSchema(
                properties: ["path": stringSchema(description: "Absolute local project path")],
                required: ["path"]
            ),
            annotations: readOnlyAnnotations
        ),
        MCPToolDefinition(
            name: "read",
            title: "Read file",
            description: "Read UTF-8 text from a file inside an opened workspace.",
            inputSchema: objectSchema(
                properties: [
                    "workspaceId": stringSchema(description: "Workspace UUID"),
                    "path": stringSchema(description: "Path relative to the workspace root"),
                    "offset": integerSchema(minimum: 1),
                    "limit": integerSchema(minimum: 1, maximum: ReadFileTool.maximumLineLimit)
                ],
                required: ["workspaceId", "path"]
            ),
            annotations: readOnlyAnnotations
        ),
        MCPToolDefinition(
            name: "search",
            title: "Search workspace",
            description: "Search UTF-8 project files inside an opened workspace.",
            inputSchema: objectSchema(
                properties: [
                    "workspaceId": stringSchema(description: "Workspace UUID"),
                    "query": stringSchema(description: "Literal text to search for"),
                    "path": stringSchema(description: "Optional path relative to the workspace root")
                ],
                required: ["workspaceId", "query"]
            ),
            annotations: readOnlyAnnotations
        ),
        MCPToolDefinition(
            name: "edit",
            title: "Edit file",
            description: "Replace one exact, unique text block in a workspace file.",
            inputSchema: objectSchema(
                properties: [
                    "workspaceId": stringSchema(description: "Workspace UUID"),
                    "path": stringSchema(description: "Path relative to the workspace root"),
                    "oldText": stringSchema(description: "Exact text that must occur once"),
                    "newText": stringSchema(description: "Replacement text")
                ],
                required: ["workspaceId", "path", "oldText", "newText"]
            ),
            annotations: mutatingAnnotations
        ),
        MCPToolDefinition(
            name: "write",
            title: "Write file",
            description: "Create a UTF-8 file, or overwrite it only when overwrite is explicitly true.",
            inputSchema: objectSchema(
                properties: [
                    "workspaceId": stringSchema(description: "Workspace UUID"),
                    "path": stringSchema(description: "Path relative to the workspace root"),
                    "content": stringSchema(description: "Complete UTF-8 file content"),
                    "overwrite": .object(["type": .string("boolean"), "default": .bool(false)])
                ],
                required: ["workspaceId", "path", "content"]
            ),
            annotations: mutatingAnnotations
        ),
        MCPToolDefinition(
            name: "bash",
            title: "Run command",
            description: "Run a policy-checked executable with an argument array inside the workspace. Shell interpreters and dangerous commands are blocked.",
            inputSchema: objectSchema(
                properties: [
                    "workspaceId": stringSchema(description: "Workspace UUID"),
                    "executable": stringSchema(description: "Executable name such as swift, git, or pwd"),
                    "arguments": .object(["type": .string("array"), "items": .object(["type": .string("string")])]),
                    "workingDirectory": stringSchema(description: "Workspace-relative working directory"),
                    "timeoutSeconds": integerSchema(minimum: 1, maximum: ShellTool.maximumTimeoutSeconds)
                ],
                required: ["workspaceId", "executable"]
            ),
            annotations: mutatingAnnotations
        )
    ]

    private static let readOnlyAnnotations: JSONValue = .object([
        "readOnlyHint": .bool(true),
        "destructiveHint": .bool(false),
        "idempotentHint": .bool(true),
        "openWorldHint": .bool(false)
    ])

    private static let mutatingAnnotations: JSONValue = .object([
        "readOnlyHint": .bool(false),
        "destructiveHint": .bool(false),
        "idempotentHint": .bool(false),
        "openWorldHint": .bool(false)
    ])

    private static func objectSchema(
        properties: [String: JSONValue],
        required: [String]
    ) -> JSONValue {
        .object([
            "$schema": .string("https://json-schema.org/draft/2020-12/schema"),
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array(required.map(JSONValue.string)),
            "additionalProperties": .bool(false)
        ])
    }

    private static func stringSchema(description: String) -> JSONValue {
        .object(["type": .string("string"), "description": .string(description)])
    }

    private static func integerSchema(minimum: Int, maximum: Int? = nil) -> JSONValue {
        var value: [String: JSONValue] = [
            "type": .string("integer"),
            "minimum": .number(Double(minimum))
        ]
        if let maximum { value["maximum"] = .number(Double(maximum)) }
        return .object(value)
    }
}
