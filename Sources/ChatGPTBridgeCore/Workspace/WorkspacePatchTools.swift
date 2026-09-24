import Foundation

public struct PatchFileResult: Codable, Equatable, Sendable {
    public let success: Bool
    public let path: String
    public let diff: String
    public let bytesWritten: Int
    public let mode: String
}

public struct GitDiffResult: Codable, Equatable, Sendable {
    public let diff: String
    public let exitCode: Int32
    public let files: [GitFileChange]
}

public struct PatchFileTool: Sendable {
    private let workspaceManager: WorkspaceManager
    private let permissionEngine: PermissionEngine
    private let auditLogger: AuditLogger
    private let validator: PathValidator
    private let parser: UnifiedDiffParser
    private let applier: PatchApplier
    private let diffGenerator: DiffGenerator

    public init(
        workspaceManager: WorkspaceManager,
        permissionEngine: PermissionEngine,
        auditLogger: AuditLogger,
        validator: PathValidator = PathValidator(),
        parser: UnifiedDiffParser = UnifiedDiffParser(),
        applier: PatchApplier = PatchApplier(),
        diffGenerator: DiffGenerator = DiffGenerator()
    ) {
        self.workspaceManager = workspaceManager
        self.permissionEngine = permissionEngine
        self.auditLogger = auditLogger
        self.validator = validator
        self.parser = parser
        self.applier = applier
        self.diffGenerator = diffGenerator
    }

    public func execute(
        workspaceID: UUID,
        path: String,
        mode: String = "old_new",
        oldText: String? = nil,
        newText: String? = nil,
        startLine: Int? = nil,
        endLine: Int? = nil,
        content: String? = nil,
        patch: String? = nil,
        approvalGranted: Bool = false
    ) async throws -> PatchFileResult {
        let startedAt = Date()
        do {
            try permissionEngine.authorizePatch(PatchPermission(
                operation: "patch \(path)",
                approvalGranted: approvalGranted
            ))
            let workspace = try await workspaceManager.workspace(id: workspaceID)
            let url = try validator.resolve(workspace: workspace, relativePath: path)
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { throw BridgeError.invalidPath(url.path) }
            let original = try String(contentsOf: url, encoding: .utf8)

            let updated: String
            switch mode {
            case "old_new":
                guard let oldText, let newText else {
                    throw ToolRouterError.invalidArguments("old_new 模式需要 oldText/newText")
                }
                let count = original.components(separatedBy: oldText).count - 1
                guard count == 1 else { throw BridgeError.editTargetNotUnique(count) }
                guard let range = original.range(of: oldText) else { throw BridgeError.editTargetNotUnique(0) }
                var value = original
                value.replaceSubrange(range, with: newText)
                updated = value

            case "line_range":
                guard let startLine, let endLine, let content else {
                    throw ToolRouterError.invalidArguments("line_range 模式需要 startLine/endLine/content")
                }
                var lines = original.components(separatedBy: "\n")
                guard startLine >= 1, endLine >= startLine, endLine <= lines.count else {
                    throw ToolRouterError.invalidArguments("行范围非法")
                }
                lines.replaceSubrange((startLine - 1)..<endLine, with: content.components(separatedBy: "\n"))
                updated = lines.joined(separator: "\n")

            case "unified_diff":
                guard let patch, !patch.isEmpty else {
                    throw ToolRouterError.invalidArguments("unified_diff 模式需要 patch")
                }
                let parsed = try parser.parse(patch)
                try Self.validatePatchPaths(parsed, expectedPath: path)
                updated = try applier.apply(parsed, to: original)

            default:
                throw ToolRouterError.invalidArguments("暂不支持 patch 模式: \(mode)")
            }

            guard updated != original else { throw BridgeError.patchFailed("patch 未产生任何修改") }
            let diff = try diffGenerator.generate(old: original, new: updated, path: path)
            try EditFileTool.atomicReplace(Data(updated.utf8), at: url)
            let result = PatchFileResult(
                success: true,
                path: path,
                diff: diff,
                bytesWritten: updated.utf8.count,
                mode: mode
            )
            try await record(.success, workspaceID: workspaceID, path: path, startedAt: startedAt, summary: mode)
            return result
        } catch {
            try? await record(.failure, workspaceID: workspaceID, path: path, startedAt: startedAt, summary: error.localizedDescription)
            throw error
        }
    }

    private func record(
        _ status: AuditStatus,
        workspaceID: UUID,
        path: String,
        startedAt: Date,
        summary: String
    ) async throws {
        try await auditLogger.record(AuditEntry(
            tool: "patch_file",
            workspaceID: workspaceID,
            target: path,
            status: status,
            durationMilliseconds: max(0, Int(Date().timeIntervalSince(startedAt) * 1_000)),
            summary: summary
        ))
    }

    private static func validatePatchPaths(_ diff: UnifiedDiff, expectedPath: String) throws {
        let normalizedExpected = expectedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        for candidate in [diff.oldPath, diff.newPath].compactMap({ $0 }) where candidate != "/dev/null" {
            let normalized = candidate.hasPrefix("a/") || candidate.hasPrefix("b/")
                ? String(candidate.dropFirst(2))
                : candidate
            guard normalized == normalizedExpected else {
                throw BridgeError.patchFailed(
                    "patch 目标 \(normalized) 与请求路径 \(normalizedExpected) 不一致"
                )
            }
        }
    }
}
