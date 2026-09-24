import CryptoKit
import Foundation

public enum MCPToolCatalogMetadata {
    public static let toolCount = MCPToolCatalog.definitions.count
    public static let toolNames = MCPToolCatalog.definitions.map(\.name)

    public static let version: String = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(MCPToolCatalog.definitions)) ?? Data()
        let digest = SHA256.hash(data: data)
            .prefix(6)
            .map { String(format: "%02x", $0) }
            .joined()
        return "3.0-\(toolCount)-\(digest)"
    }()
}

enum MCPToolCatalog {
    static let definitions: [MCPToolDefinition] = [
        MCPToolDefinition(
            name: "open_workspace",
            title: "Open workspace",
            description: "Open a local project directory that is inside Codex Harbor's allowed roots.",
            inputSchema: objectSchema(
                properties: ["path": stringSchema(description: "Absolute local project path")],
                required: ["path"]
            ),
            outputSchema: objectSchema(
                properties: [
                    "workspaceID": stringSchema(description: "Workspace UUID"),
                    "name": stringSchema(description: "Workspace display name"),
                    "rootPath": stringSchema(description: "Absolute workspace root"),
                    "gitBranch": stringSchema(description: "Current Git branch"),
                    "isGitDirty": .object(["type": .string("boolean")])
                ],
                required: ["workspaceID", "name", "rootPath", "isGitDirty"]
            ),
            annotations: readOnlyAnnotations
        ),
        MCPToolDefinition(
            name: "read",
            title: "Read file",
            description: "Read UTF-8 text from a file inside an opened workspace.",
            inputSchema: objectSchema(
                properties: [
                    "workspaceId": stringSchema(description: "Optional workspace UUID; the active session workspace is used when omitted"),
                    "path": stringSchema(description: "Path relative to the workspace root"),
                    "offset": integerSchema(minimum: 1),
                    "limit": integerSchema(minimum: 1, maximum: ReadFileTool.maximumLineLimit)
                ],
                required: ["path"]
            ),
            outputSchema: objectSchema(
                properties: [
                    "path": stringSchema(description: "Relative file path"),
                    "startLine": integerSchema(minimum: 0),
                    "endLine": integerSchema(minimum: 0),
                    "totalLines": integerSchema(minimum: 0),
                    "content": stringSchema(description: "UTF-8 file content for the requested range"),
                    "truncated": .object(["type": .string("boolean")])
                ],
                required: ["path", "startLine", "endLine", "totalLines", "content", "truncated"]
            ),
            annotations: readOnlyAnnotations
        ),
        MCPToolDefinition(
            name: "search",
            title: "Search workspace",
            description: "Search UTF-8 project files inside an opened workspace.",
            inputSchema: objectSchema(
                properties: [
                    "workspaceId": stringSchema(description: "Optional workspace UUID; the active session workspace is used when omitted"),
                    "query": stringSchema(description: "Literal text to search for"),
                    "path": stringSchema(description: "Optional path relative to the workspace root")
                ],
                required: ["query"]
            ),
            outputSchema: objectSchema(
                properties: [
                    "query": stringSchema(description: "Normalized search query"),
                    "path": stringSchema(description: "Search root"),
                    "output": stringSchema(description: "Matched lines with file paths and line numbers"),
                    "matchLineCount": integerSchema(minimum: 0),
                    "truncated": .object(["type": .string("boolean")])
                ],
                required: ["query", "path", "output", "matchLineCount", "truncated"]
            ),
            annotations: readOnlyAnnotations
        ),
        MCPToolDefinition(
            name: "list_directory",
            title: "List directory",
            description: "List files and folders directly inside a workspace directory without invoking a shell.",
            inputSchema: objectSchema(
                properties: [
                    "workspaceId": stringSchema(description: "Optional workspace UUID; the active session workspace is used when omitted"),
                    "path": stringSchema(description: "Optional directory relative to workspace root; defaults to ."),
                    "includeHidden": .object(["type": .string("boolean"), "default": .bool(false)]),
                    "limit": integerSchema(minimum: 1, maximum: WorkspaceInspectionTool.maximumDirectoryEntries)
                ],
                required: []
            ),
            outputSchema: listDirectoryResultSchema,
            annotations: readOnlyAnnotations
        ),
        MCPToolDefinition(
            name: "workspace_tree",
            title: "Workspace tree",
            description: "Return a bounded project tree. Heavy generated directories such as .git, .build, node_modules, DerivedData, and target are not recursively expanded.",
            inputSchema: objectSchema(
                properties: [
                    "workspaceId": stringSchema(description: "Optional workspace UUID; the active session workspace is used when omitted"),
                    "path": stringSchema(description: "Optional directory relative to workspace root; defaults to ."),
                    "depth": integerSchema(minimum: 1, maximum: WorkspaceInspectionTool.maximumTreeDepth),
                    "includeHidden": .object(["type": .string("boolean"), "default": .bool(false)]),
                    "limit": integerSchema(minimum: 1, maximum: WorkspaceInspectionTool.maximumTreeEntries)
                ],
                required: []
            ),
            outputSchema: workspaceTreeResultSchema,
            annotations: readOnlyAnnotations
        ),
        MCPToolDefinition(
            name: "edit",
            title: "Edit file",
            description: "Replace one exact, unique text block in a workspace file.",
            inputSchema: objectSchema(
                properties: [
                    "workspaceId": stringSchema(description: "Optional workspace UUID; the active session workspace is used when omitted"),
                    "path": stringSchema(description: "Path relative to the workspace root"),
                    "oldText": stringSchema(description: "Exact text that must occur once"),
                    "newText": stringSchema(description: "Replacement text")
                ],
                required: ["path", "oldText", "newText"]
            ),
            outputSchema: objectSchema(
                properties: [
                    "path": stringSchema(description: "Edited file path"),
                    "replacedOccurrences": integerSchema(minimum: 0),
                    "bytesWritten": integerSchema(minimum: 0)
                ],
                required: ["path", "replacedOccurrences", "bytesWritten"]
            ),
            annotations: mutatingAnnotations
        ),
        MCPToolDefinition(
            name: "patch_file",
            title: "Patch file",
            description: "Apply a precise patch to a workspace file. Supports old_new, line_range, and context-checked unified_diff.",
            inputSchema: objectSchema(
                properties: [
                    "workspaceId": stringSchema(description: "Optional workspace UUID; the active session workspace is used when omitted"),
                    "path": stringSchema(description: "Path relative to workspace root"),
                    "mode": stringSchema(description: "Patch mode: old_new, line_range, or unified_diff"),
                    "oldText": stringSchema(description: "Existing exact text"),
                    "newText": stringSchema(description: "Replacement text"),
                    "startLine": integerSchema(minimum: 1),
                    "endLine": integerSchema(minimum: 1),
                    "content": stringSchema(description: "Replacement content for line range"),
                    "patch": stringSchema(description: "Unified diff text for unified_diff mode")
                ],
                required: ["path"]
            ),
            outputSchema: objectSchema(
                properties: [
                    "success": .object(["type": .string("boolean")]),
                    "path": stringSchema(description: "Changed file"),
                    "diff": stringSchema(description: "Generated diff"),
                    "mode": stringSchema(description: "Applied patch mode"),
                    "bytesWritten": integerSchema(minimum: 0)
                ],
                required: ["success", "path", "diff", "mode", "bytesWritten"]
            ),
            annotations: mutatingAnnotations
        ),
        MCPToolDefinition(
            name: "git_diff",
            title: "Git diff",
            description: "Return current git diff for the opened workspace.",
            inputSchema: objectSchema(
                properties: [
                    "workspaceId": stringSchema(description: "Optional workspace UUID; the active session workspace is used when omitted"),
                    "path": stringSchema(description: "Optional workspace-relative path")
                ],
                required: []
            ),
            outputSchema: objectSchema(
                properties: [
                    "diff": stringSchema(description: "Git diff output"),
                    "exitCode": .object(["type": .string("integer")]),
                    "files": .object([
                        "type": .string("array"),
                        "items": gitFileChangeSchema
                    ])
                ],
                required: ["diff", "exitCode", "files"]
            ),
            annotations: readOnlyAnnotations
        ),
        MCPToolDefinition(
            name: "git_status",
            title: "Git status",
            description: "Return the current branch and structured working-tree/index status for the opened workspace.",
            inputSchema: objectSchema(
                properties: [
                    "workspaceId": stringSchema(description: "Optional workspace UUID; the active session workspace is used when omitted")
                ],
                required: []
            ),
            outputSchema: gitStatusResultSchema,
            annotations: readOnlyAnnotations
        ),
        MCPToolDefinition(
            name: "write",
            title: "Write file",
            description: "Create a UTF-8 file, or overwrite it only when overwrite is explicitly true.",
            inputSchema: objectSchema(
                properties: [
                    "workspaceId": stringSchema(description: "Optional workspace UUID; the active session workspace is used when omitted"),
                    "path": stringSchema(description: "Path relative to the workspace root"),
                    "content": stringSchema(description: "Complete UTF-8 file content"),
                    "overwrite": .object(["type": .string("boolean"), "default": .bool(false)])
                ],
                required: ["path", "content"]
            ),
            outputSchema: objectSchema(
                properties: [
                    "path": stringSchema(description: "Written file path"),
                    "bytesWritten": integerSchema(minimum: 0),
                    "created": .object(["type": .string("boolean")])
                ],
                required: ["path", "bytesWritten", "created"]
            ),
            annotations: mutatingAnnotations
        ),
        MCPToolDefinition(
            name: "run_command",
            title: "Run command",
            description: "Run a command inside the opened workspace and return execution result.",
            inputSchema: objectSchema(
                properties: [
                    "workspaceId": stringSchema(description: "Optional workspace UUID; the active session workspace is used when omitted"),
                    "executable": stringSchema(description: "Executable name such as swift, git, or pwd"),
                    "arguments": .object(["type": .string("array"), "items": .object(["type": .string("string")])]),
                    "workingDirectory": stringSchema(description: "Workspace-relative working directory"),
                    "timeoutSeconds": integerSchema(minimum: 1, maximum: ShellTool.maximumTimeoutSeconds)
                ],
                required: ["executable"]
            ),
            outputSchema: objectSchema(
                properties: [
                    "executable": stringSchema(description: "Executed command"),
                    "arguments": .object(["type": .string("array"), "items": .object(["type": .string("string")])]),
                    "exitCode": .object(["type": .string("integer")]),
                    "stdout": stringSchema(description: "Redacted standard output"),
                    "stderr": stringSchema(description: "Redacted standard error"),
                    "durationMilliseconds": integerSchema(minimum: 0),
                    "truncated": .object(["type": .string("boolean")]),
                    "errors": .object(["type": .string("array"), "items": buildErrorSchema])
                ],
                required: ["executable", "arguments", "exitCode", "stdout", "stderr", "durationMilliseconds", "truncated", "errors"]
            ),
            annotations: mutatingAnnotations
        ),
        MCPToolDefinition(
            name: "bash",
            title: "Run command",
            description: "Run an executable with an argument array inside the opened workspace. Shell interpreters and scripts are allowed; explicit shell permission settings are still honored.",
            inputSchema: objectSchema(
                properties: [
                    "workspaceId": stringSchema(description: "Optional workspace UUID; the active session workspace is used when omitted"),
                    "executable": stringSchema(description: "Executable name such as swift, git, or pwd"),
                    "arguments": .object(["type": .string("array"), "items": .object(["type": .string("string")])]),
                    "workingDirectory": stringSchema(description: "Workspace-relative working directory"),
                    "timeoutSeconds": integerSchema(minimum: 1, maximum: ShellTool.maximumTimeoutSeconds)
                ],
                required: ["executable"]
            ),
            outputSchema: objectSchema(
                properties: [
                    "executable": stringSchema(description: "Executed command"),
                    "arguments": .object(["type": .string("array"), "items": .object(["type": .string("string")])]),
                    "exitCode": .object(["type": .string("integer")]),
                    "stdout": stringSchema(description: "Redacted standard output"),
                    "stderr": stringSchema(description: "Redacted standard error"),
                    "durationMilliseconds": integerSchema(minimum: 0),
                    "truncated": .object(["type": .string("boolean")]),
                    "errors": .object(["type": .string("array"), "items": buildErrorSchema])
                ],
                required: ["executable", "arguments", "exitCode", "stdout", "stderr", "durationMilliseconds", "truncated", "errors"]
            ),
            annotations: mutatingAnnotations
        ),
        MCPToolDefinition(
            name: "start_command",
            title: "Start long-running command",
            description: "Start a long-running command and return immediately with a command ID. Use command_status and command_output to follow progress.",
            inputSchema: objectSchema(
                properties: [
                    "workspaceId": stringSchema(description: "Optional workspace UUID; the active session workspace is used when omitted"),
                    "executable": stringSchema(description: "Executable name"),
                    "arguments": .object(["type": .string("array"), "items": .object(["type": .string("string")])]),
                    "workingDirectory": stringSchema(description: "Workspace-relative working directory"),
                    "timeoutSeconds": integerSchema(minimum: 1, maximum: ShellTool.maximumTimeoutSeconds)
                ],
                required: ["executable"]
            ),
            outputSchema: commandSessionStartedSchema,
            annotations: mutatingAnnotations
        ),
        MCPToolDefinition(
            name: "command_status",
            title: "Command status",
            description: "Inspect the state and exit code of a command started by start_command.",
            inputSchema: objectSchema(
                properties: [
                    "commandId": stringSchema(description: "Command session UUID")
                ],
                required: ["commandId"]
            ),
            outputSchema: commandSessionStatusSchema,
            annotations: readOnlyAnnotations
        ),
        MCPToolDefinition(
            name: "command_output",
            title: "Command output",
            description: "Read incremental stdout/stderr from a command session using byte offsets.",
            inputSchema: objectSchema(
                properties: [
                    "commandId": stringSchema(description: "Command session UUID"),
                    "stdoutOffset": integerSchema(minimum: 0),
                    "stderrOffset": integerSchema(minimum: 0),
                    "limitBytes": integerSchema(minimum: 1, maximum: CommandSessionManager.maximumOutputChunkBytes)
                ],
                required: ["commandId"]
            ),
            outputSchema: commandSessionOutputSchema,
            annotations: readOnlyAnnotations
        ),
        MCPToolDefinition(
            name: "cancel_command",
            title: "Cancel command",
            description: "Cancel a running command session without affecting unrelated processes.",
            inputSchema: objectSchema(
                properties: [
                    "commandId": stringSchema(description: "Command session UUID")
                ],
                required: ["commandId"]
            ),
            outputSchema: commandSessionStatusSchema,
            annotations: mutatingAnnotations
        ),
        MCPToolDefinition(
            name: "start_workflow",
            title: "Start project workflow",
            description: "Start an auto-detected project verification workflow and return immediately with a workflow ID. Use workflow_status and workflow_output to follow progress.",
            inputSchema: objectSchema(
                properties: [
                    "workspaceId": stringSchema(description: "Optional workspace UUID; the active session workspace is used when omitted"),
                    "includeTests": .object(["type": .string("boolean"), "default": .bool(true)]),
                    "includeBuild": .object(["type": .string("boolean"), "default": .bool(true)]),
                    "timeoutSeconds": integerSchema(minimum: 1, maximum: ShellTool.maximumTimeoutSeconds)
                ],
                required: []
            ),
            outputSchema: workflowSessionStartedSchema,
            annotations: mutatingAnnotations
        ),
        MCPToolDefinition(
            name: "workflow_status",
            title: "Workflow status",
            description: "Inspect the current step and per-step states for a workflow started by start_workflow.",
            inputSchema: objectSchema(
                properties: [
                    "workflowId": stringSchema(description: "Workflow session UUID")
                ],
                required: ["workflowId"]
            ),
            outputSchema: workflowSessionStatusSchema,
            annotations: readOnlyAnnotations
        ),
        MCPToolDefinition(
            name: "workflow_output",
            title: "Workflow output",
            description: "Read incremental stdout/stderr for the workflow's current step using byte offsets.",
            inputSchema: objectSchema(
                properties: [
                    "workflowId": stringSchema(description: "Workflow session UUID"),
                    "stdoutOffset": integerSchema(minimum: 0),
                    "stderrOffset": integerSchema(minimum: 0),
                    "limitBytes": integerSchema(minimum: 1, maximum: CommandSessionManager.maximumOutputChunkBytes)
                ],
                required: ["workflowId"]
            ),
            outputSchema: workflowSessionOutputSchema,
            annotations: readOnlyAnnotations
        ),
        MCPToolDefinition(
            name: "cancel_workflow",
            title: "Cancel workflow",
            description: "Cancel the current step of a running workflow and prevent remaining steps from starting.",
            inputSchema: objectSchema(
                properties: [
                    "workflowId": stringSchema(description: "Workflow session UUID")
                ],
                required: ["workflowId"]
            ),
            outputSchema: workflowSessionStatusSchema,
            annotations: mutatingAnnotations
        ),
        MCPToolDefinition(
            name: "run_workflow",
            title: "Run project workflow",
            description: "Auto-detect SwiftPM, Xcode, Node, Python, Maven, or Gradle and run the project's available test/build verification workflow.",
            inputSchema: objectSchema(
                properties: [
                    "workspaceId": stringSchema(description: "Optional workspace UUID; the active session workspace is used when omitted"),
                    "includeTests": .object(["type": .string("boolean"), "default": .bool(true)]),
                    "includeBuild": .object(["type": .string("boolean"), "default": .bool(true)]),
                    "timeoutSeconds": integerSchema(minimum: 1, maximum: ShellTool.maximumTimeoutSeconds)
                ],
                required: []
            ),
            outputSchema: projectWorkflowResultSchema,
            annotations: mutatingAnnotations
        ),
        MCPToolDefinition(
            name: "coding_task",
            title: "Coding Task",
            description: "Run a stateful coding task around one Task ID. Actions: start applies model-supplied precise changes then automatically diff/tests/builds/packages; status inspects progress; output reads current command output; repair applies a repair patch to the same task and automatically re-verifies; cancel stops the active command. Harbor owns orchestration and verification while the model remains responsible for understanding requirements and generating code changes.",
            inputSchema: objectSchema(
                properties: [
                    "action": stringSchema(description: "start, status, output, repair, or cancel; defaults to start"),
                    "workspaceId": stringSchema(description: "Optional workspace UUID; the active session workspace is used for start"),
                    "taskId": stringSchema(description: "Coding Task UUID for status/output/repair/cancel"),
                    "requirement": stringSchema(description: "User requirement recorded with a start action"),
                    "changes": arraySchema(items: codingTaskChangeSchema),
                    "includeTests": .object(["type": .string("boolean"), "default": .bool(true)]),
                    "includeBuild": .object(["type": .string("boolean"), "default": .bool(true)]),
                    "includePackage": .object(["type": .string("boolean"), "default": .bool(true)]),
                    "maxRepairAttempts": integerSchema(minimum: 0, maximum: 5),
                    "timeoutSeconds": integerSchema(minimum: 1, maximum: ShellTool.maximumTimeoutSeconds),
                    "stdoutOffset": integerSchema(minimum: 0),
                    "stderrOffset": integerSchema(minimum: 0),
                    "limitBytes": integerSchema(minimum: 1, maximum: CommandSessionManager.maximumOutputChunkBytes)
                ],
                required: []
            ),
            outputSchema: codingTaskResponseSchema,
            annotations: mutatingAnnotations
        ),
        MCPToolDefinition(
            name: "repair_project",
            title: "Repair Swift project",
            description: "Run a permission-aware Swift repair workflow: inspect Git, test, optionally apply a reviewed unified diff, retest, and build.",
            inputSchema: objectSchema(
                properties: [
                    "workspaceId": stringSchema(description: "Optional workspace UUID; the active session workspace is used when omitted"),
                    "path": stringSchema(description: "File path for an optional reviewed patch"),
                    "patch": stringSchema(description: "Optional reviewed unified diff"),
                    "timeoutSeconds": integerSchema(minimum: 1, maximum: ShellTool.maximumTimeoutSeconds)
                ],
                required: []
            ),
            outputSchema: repairAgentResultSchema,
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

    private static let buildErrorSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "file": stringSchema(description: "Source file"),
            "line": integerSchema(minimum: 1),
            "column": integerSchema(minimum: 1),
            "message": stringSchema(description: "Compiler error message")
        ]),
        "required": .array(["file", "line", "column", "message"].map(JSONValue.string))
    ])

    private static let gitFileChangeSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "path": stringSchema(description: "Changed path"),
            "additions": integerSchema(minimum: 0),
            "deletions": integerSchema(minimum: 0),
            "status": stringSchema(description: "Optional porcelain status")
        ]),
        "required": .array(["path", "additions", "deletions"].map(JSONValue.string))
    ])

    private static let workspaceDirectoryEntrySchema = objectSchema(
        properties: [
            "name": stringSchema(description: "Entry name"),
            "path": stringSchema(description: "Workspace-relative path"),
            "kind": stringSchema(description: "Entry kind: file, directory, symlink, or other"),
            "size": integerSchema(minimum: 0),
            "isHidden": booleanSchema(description: "Whether the entry is hidden")
        ],
        required: ["name", "path", "kind", "isHidden"]
    )

    private static let listDirectoryResultSchema = objectSchema(
        properties: [
            "path": stringSchema(description: "Listed workspace-relative directory"),
            "entries": arraySchema(items: workspaceDirectoryEntrySchema),
            "truncated": booleanSchema(description: "Whether more entries were available")
        ],
        required: ["path", "entries", "truncated"]
    )

    private static let workspaceTreeEntrySchema = objectSchema(
        properties: [
            "path": stringSchema(description: "Workspace-relative path"),
            "kind": stringSchema(description: "Entry kind: file, directory, symlink, or other"),
            "depth": integerSchema(minimum: 0)
        ],
        required: ["path", "kind", "depth"]
    )

    private static let workspaceTreeResultSchema = objectSchema(
        properties: [
            "path": stringSchema(description: "Tree root"),
            "entries": arraySchema(items: workspaceTreeEntrySchema),
            "maxDepth": integerSchema(minimum: 0),
            "truncated": booleanSchema(description: "Whether the tree hit the entry limit")
        ],
        required: ["path", "entries", "maxDepth", "truncated"]
    )

    private static let gitStatusEntrySchema = objectSchema(
        properties: [
            "path": stringSchema(description: "Changed path"),
            "indexStatus": stringSchema(description: "Git index status code"),
            "workTreeStatus": stringSchema(description: "Git working-tree status code")
        ],
        required: ["path", "indexStatus", "workTreeStatus"]
    )

    private static let gitStatusResultSchema = objectSchema(
        properties: [
            "branch": stringSchema(description: "Current Git branch when available"),
            "isClean": booleanSchema(description: "Whether the working tree is clean"),
            "entries": arraySchema(items: gitStatusEntrySchema)
        ],
        required: ["isClean", "entries"]
    )

    private static let commandSessionStartedSchema = objectSchema(
        properties: [
            "commandID": stringSchema(description: "Command session UUID"),
            "state": stringSchema(description: "Command state"),
            "processIdentifier": integerSchema(minimum: 0),
            "startedAt": dateValueSchema
        ],
        required: ["commandID", "state", "processIdentifier", "startedAt"]
    )

    private static let commandSessionStatusSchema = objectSchema(
        properties: [
            "commandID": stringSchema(description: "Command session UUID"),
            "state": stringSchema(description: "Command state"),
            "processIdentifier": integerSchema(minimum: 0),
            "exitCode": signedIntegerSchema,
            "startedAt": dateValueSchema,
            "finishedAt": dateValueSchema,
            "durationMilliseconds": integerSchema(minimum: 0),
            "errors": arraySchema(items: buildErrorSchema)
        ],
        required: ["commandID", "state", "startedAt", "durationMilliseconds", "errors"]
    )

    private static let commandSessionOutputSchema = objectSchema(
        properties: [
            "commandID": stringSchema(description: "Command session UUID"),
            "state": stringSchema(description: "Command state"),
            "stdout": stringSchema(description: "Incremental standard output"),
            "stderr": stringSchema(description: "Incremental standard error"),
            "stdoutOffset": integerSchema(minimum: 0),
            "stderrOffset": integerSchema(minimum: 0),
            "nextStdoutOffset": integerSchema(minimum: 0),
            "nextStderrOffset": integerSchema(minimum: 0),
            "stdoutHasMore": booleanSchema(description: "Whether more stdout is available"),
            "stderrHasMore": booleanSchema(description: "Whether more stderr is available")
        ],
        required: [
            "commandID", "state", "stdout", "stderr", "stdoutOffset", "stderrOffset",
            "nextStdoutOffset", "nextStderrOffset", "stdoutHasMore", "stderrHasMore"
        ]
    )

    private static let workflowSessionStartedSchema = objectSchema(
        properties: [
            "workflowID": stringSchema(description: "Workflow session UUID"),
            "kind": stringSchema(description: "Detected project workflow kind"),
            "state": stringSchema(description: "Workflow state"),
            "message": stringSchema(description: "Workflow status message"),
            "startedAt": dateValueSchema
        ],
        required: ["workflowID", "kind", "state", "message", "startedAt"]
    )

    private static let workflowStepStatusSchema = objectSchema(
        properties: [
            "index": integerSchema(minimum: 0),
            "name": stringSchema(description: "Workflow step name"),
            "executable": stringSchema(description: "Step executable"),
            "arguments": stringArraySchema,
            "state": stringSchema(description: "Workflow step state"),
            "commandID": stringSchema(description: "Backing command session UUID when started"),
            "exitCode": signedIntegerSchema,
            "errors": arraySchema(items: buildErrorSchema)
        ],
        required: ["index", "name", "executable", "arguments", "state", "errors"]
    )

    private static let workflowSessionStatusSchema = objectSchema(
        properties: [
            "workflowID": stringSchema(description: "Workflow session UUID"),
            "kind": stringSchema(description: "Detected project workflow kind"),
            "state": stringSchema(description: "Workflow state"),
            "message": stringSchema(description: "Workflow status message"),
            "startedAt": dateValueSchema,
            "finishedAt": dateValueSchema,
            "durationMilliseconds": integerSchema(minimum: 0),
            "currentStepIndex": integerSchema(minimum: 0),
            "steps": arraySchema(items: workflowStepStatusSchema)
        ],
        required: ["workflowID", "kind", "state", "message", "startedAt", "durationMilliseconds", "steps"]
    )

    private static let workflowSessionOutputSchema = objectSchema(
        properties: [
            "workflowID": stringSchema(description: "Workflow session UUID"),
            "state": stringSchema(description: "Workflow state"),
            "currentStepIndex": integerSchema(minimum: 0),
            "currentStepName": stringSchema(description: "Current workflow step name"),
            "commandID": stringSchema(description: "Current command session UUID"),
            "stdout": stringSchema(description: "Incremental standard output"),
            "stderr": stringSchema(description: "Incremental standard error"),
            "stdoutOffset": integerSchema(minimum: 0),
            "stderrOffset": integerSchema(minimum: 0),
            "nextStdoutOffset": integerSchema(minimum: 0),
            "nextStderrOffset": integerSchema(minimum: 0),
            "stdoutHasMore": booleanSchema(description: "Whether more stdout is available"),
            "stderrHasMore": booleanSchema(description: "Whether more stderr is available")
        ],
        required: [
            "workflowID", "state", "stdout", "stderr", "stdoutOffset", "stderrOffset",
            "nextStdoutOffset", "nextStderrOffset", "stdoutHasMore", "stderrHasMore"
        ]
    )

    private static let projectWorkflowCommandSchema = objectSchema(
        properties: [
            "name": stringSchema(description: "Workflow command name"),
            "executable": stringSchema(description: "Executable"),
            "arguments": stringArraySchema,
            "workingDirectory": stringSchema(description: "Workspace-relative working directory")
        ],
        required: ["name", "executable", "arguments", "workingDirectory"]
    )

    private static let shellResultSchema = objectSchema(
        properties: [
            "executable": stringSchema(description: "Executed command"),
            "arguments": stringArraySchema,
            "exitCode": signedIntegerSchema,
            "stdout": stringSchema(description: "Redacted standard output"),
            "stderr": stringSchema(description: "Redacted standard error"),
            "durationMilliseconds": integerSchema(minimum: 0),
            "truncated": booleanSchema(description: "Whether output was truncated"),
            "errors": arraySchema(items: buildErrorSchema)
        ],
        required: [
            "executable", "arguments", "exitCode", "stdout", "stderr",
            "durationMilliseconds", "truncated", "errors"
        ]
    )

    private static let projectWorkflowStepResultSchema = objectSchema(
        properties: [
            "name": stringSchema(description: "Workflow step name"),
            "command": projectWorkflowCommandSchema,
            "result": shellResultSchema
        ],
        required: ["name", "command", "result"]
    )

    private static let projectWorkflowResultSchema = objectSchema(
        properties: [
            "kind": stringSchema(description: "Detected project workflow kind"),
            "state": stringSchema(description: "Workflow result state"),
            "message": stringSchema(description: "Workflow result message"),
            "steps": arraySchema(items: projectWorkflowStepResultSchema)
        ],
        required: ["kind", "state", "message", "steps"]
    )

    private static let codingTaskChangeSchema = objectSchema(
        properties: [
            "path": stringSchema(description: "Workspace-relative file path"),
            "mode": stringSchema(description: "old_new, line_range, or unified_diff"),
            "oldText": stringSchema(description: "Exact existing text for old_new"),
            "newText": stringSchema(description: "Replacement text for old_new"),
            "startLine": integerSchema(minimum: 1),
            "endLine": integerSchema(minimum: 1),
            "content": stringSchema(description: "Replacement content for line_range"),
            "patch": stringSchema(description: "Unified diff for unified_diff")
        ],
        required: ["path"]
    )

    private static let codingTaskStepSchema = objectSchema(
        properties: [
            "index": integerSchema(minimum: 0),
            "name": stringSchema(description: "Verification/package step name"),
            "executable": stringSchema(description: "Step executable"),
            "arguments": stringArraySchema,
            "state": stringSchema(description: "pending, running, completed, failed, cancelled, or timedOut"),
            "commandID": stringSchema(description: "Backing command session UUID"),
            "exitCode": signedIntegerSchema,
            "errors": arraySchema(items: buildErrorSchema)
        ],
        required: ["index", "name", "executable", "arguments", "state", "errors"]
    )

    private static let codingTaskResponseSchema = objectSchema(
        properties: [
            "taskID": stringSchema(description: "Persistent Coding Task UUID"),
            "workspaceID": stringSchema(description: "Workspace UUID owned by this task"),
            "requirement": stringSchema(description: "Original user requirement"),
            "state": stringSchema(description: "planned, running, needsRepair, completed, failed, cancelled, timedOut, or unsupported"),
            "phase": stringSchema(description: "analyzing, modifying, diffing, testing, building, packaging, repairing, or complete"),
            "message": stringSchema(description: "Current task message"),
            "startedAt": dateValueSchema,
            "finishedAt": dateValueSchema,
            "durationMilliseconds": integerSchema(minimum: 0),
            "repairAttempt": integerSchema(minimum: 0),
            "maximumRepairAttempts": integerSchema(minimum: 0),
            "appliedChanges": stringArraySchema,
            "changedFiles": arraySchema(items: gitFileChangeSchema),
            "errors": arraySchema(items: buildErrorSchema),
            "currentCommandID": stringSchema(description: "Current or most recent command session UUID"),
            "steps": arraySchema(items: codingTaskStepSchema),
            "stdout": stringSchema(description: "Current command output for action=output"),
            "stderr": stringSchema(description: "Current command error output for action=output"),
            "stdoutOffset": integerSchema(minimum: 0),
            "stderrOffset": integerSchema(minimum: 0),
            "nextStdoutOffset": integerSchema(minimum: 0),
            "nextStderrOffset": integerSchema(minimum: 0),
            "stdoutHasMore": booleanSchema(description: "Whether more stdout is available"),
            "stderrHasMore": booleanSchema(description: "Whether more stderr is available")
        ],
        required: [
            "taskID", "workspaceID", "requirement", "state", "phase", "message",
            "startedAt", "durationMilliseconds", "repairAttempt", "maximumRepairAttempts",
            "appliedChanges", "changedFiles", "errors", "steps", "stdout", "stderr",
            "stdoutOffset", "stderrOffset", "nextStdoutOffset", "nextStderrOffset",
            "stdoutHasMore", "stderrHasMore"
        ]
    )

    private static let patchFileResultSchema = objectSchema(
        properties: [
            "success": booleanSchema(description: "Whether the patch was applied"),
            "path": stringSchema(description: "Changed file"),
            "diff": stringSchema(description: "Generated diff"),
            "bytesWritten": integerSchema(minimum: 0),
            "mode": stringSchema(description: "Applied patch mode")
        ],
        required: ["success", "path", "diff", "bytesWritten", "mode"]
    )

    private static let repairWorkflowStepSchema = objectSchema(
        properties: [
            "state": stringSchema(description: "Repair workflow state"),
            "succeeded": booleanSchema(description: "Whether the step succeeded"),
            "message": stringSchema(description: "Repair step message")
        ],
        required: ["state", "succeeded", "message"]
    )

    private static let repairAgentResultSchema = objectSchema(
        properties: [
            "state": stringSchema(description: "Repair workflow state"),
            "gitStatus": gitStatusResultSchema,
            "errors": arraySchema(items: buildErrorSchema),
            "patch": patchFileResultSchema,
            "test": shellResultSchema,
            "build": shellResultSchema,
            "steps": arraySchema(items: repairWorkflowStepSchema)
        ],
        required: ["state", "gitStatus", "errors", "test", "steps"]
    )

    private static let stringArraySchema: JSONValue = .object([
        "type": .string("array"),
        "items": .object(["type": .string("string")])
    ])

    private static let signedIntegerSchema: JSONValue = .object([
        "type": .string("integer")
    ])

    private static let dateValueSchema: JSONValue = .object([
        "type": .string("number"),
        "description": .string("Foundation Date encoded by JSONEncoder as seconds since the reference date")
    ])

    private static func arraySchema(items: JSONValue) -> JSONValue {
        .object([
            "type": .string("array"),
            "items": items
        ])
    }

    private static func booleanSchema(description: String) -> JSONValue {
        .object([
            "type": .string("boolean"),
            "description": .string(description)
        ])
    }

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
