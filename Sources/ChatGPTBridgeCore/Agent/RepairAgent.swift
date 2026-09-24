import Foundation

public enum RepairWorkflowState: String, Codable, Equatable, Sendable {
    case inspecting
    case testing
    case needsPatch
    case applyingPatch
    case retesting
    case building
    case completed
    case failed
}

public struct RepairWorkflowStep: Codable, Equatable, Sendable {
    public let state: RepairWorkflowState
    public let succeeded: Bool
    public let message: String

    public init(state: RepairWorkflowState, succeeded: Bool, message: String) {
        self.state = state
        self.succeeded = succeeded
        self.message = message
    }
}

public struct RepairAgentResult: Codable, Equatable, Sendable {
    public let state: RepairWorkflowState
    public let gitStatus: GitStatusResult
    public let errors: [BuildError]
    public let patch: PatchFileResult?
    public let test: ShellResult
    public let build: ShellResult?
    public let steps: [RepairWorkflowStep]
}

public struct RepairAgent: Sendable {
    private let workspaceManager: WorkspaceManager
    private let gitService: GitService
    private let commandService: CommandService
    private let patchTool: PatchFileTool

    public init(
        workspaceManager: WorkspaceManager,
        gitService: GitService,
        commandService: CommandService,
        patchTool: PatchFileTool
    ) {
        self.workspaceManager = workspaceManager
        self.gitService = gitService
        self.commandService = commandService
        self.patchTool = patchTool
    }

    public func repair(
        workspaceID: UUID,
        patchPath: String? = nil,
        unifiedDiff: String? = nil,
        timeoutSeconds: Int = 300,
        approvalGranted: Bool = false
    ) async throws -> RepairAgentResult {
        let workspace = try await workspaceManager.workspace(id: workspaceID)
        let status = try gitService.getStatus(workspace: workspace)
        var steps = [RepairWorkflowStep(
            state: .inspecting,
            succeeded: true,
            message: status.isClean ? "Git workspace is clean" : "Git workspace has local changes"
        )]

        let initialTest = try await commandService.run(
            workspaceID: workspaceID,
            executable: "swift",
            arguments: ["test"],
            timeoutSeconds: timeoutSeconds,
            approvalGranted: approvalGranted,
            auditTool: "repair_project"
        )
        steps.append(RepairWorkflowStep(
            state: .testing,
            succeeded: initialTest.exitCode == 0,
            message: initialTest.exitCode == 0 ? "swift test passed" : "swift test failed"
        ))

        var finalTest = initialTest
        var appliedPatch: PatchFileResult?
        if initialTest.exitCode != 0 {
            guard let patchPath, let unifiedDiff, !unifiedDiff.isEmpty else {
                steps.append(RepairWorkflowStep(
                    state: .needsPatch,
                    succeeded: false,
                    message: "Build errors require a reviewed unified diff"
                ))
                return RepairAgentResult(
                    state: .needsPatch,
                    gitStatus: status,
                    errors: initialTest.errors,
                    patch: nil,
                    test: initialTest,
                    build: nil,
                    steps: steps
                )
            }

            appliedPatch = try await patchTool.execute(
                workspaceID: workspaceID,
                path: patchPath,
                mode: "unified_diff",
                patch: unifiedDiff,
                approvalGranted: approvalGranted
            )
            steps.append(RepairWorkflowStep(
                state: .applyingPatch,
                succeeded: true,
                message: "Applied reviewed patch to \(patchPath)"
            ))

            finalTest = try await commandService.run(
                workspaceID: workspaceID,
                executable: "swift",
                arguments: ["test"],
                timeoutSeconds: timeoutSeconds,
                approvalGranted: approvalGranted,
                auditTool: "repair_project"
            )
            steps.append(RepairWorkflowStep(
                state: .retesting,
                succeeded: finalTest.exitCode == 0,
                message: finalTest.exitCode == 0 ? "swift test passed after patch" : "swift test still fails"
            ))
            if finalTest.exitCode != 0 {
                return RepairAgentResult(
                    state: .failed,
                    gitStatus: status,
                    errors: finalTest.errors,
                    patch: appliedPatch,
                    test: finalTest,
                    build: nil,
                    steps: steps
                )
            }
        }

        let build = try await commandService.run(
            workspaceID: workspaceID,
            executable: "swift",
            arguments: ["build"],
            timeoutSeconds: timeoutSeconds,
            approvalGranted: approvalGranted,
            auditTool: "repair_project"
        )
        let completed = build.exitCode == 0
        steps.append(RepairWorkflowStep(
            state: .building,
            succeeded: completed,
            message: completed ? "swift build passed" : "swift build failed"
        ))
        if completed {
            steps.append(RepairWorkflowStep(state: .completed, succeeded: true, message: "Repair workflow completed"))
        }
        return RepairAgentResult(
            state: completed ? .completed : .failed,
            gitStatus: status,
            errors: completed ? [] : build.errors,
            patch: appliedPatch,
            test: finalTest,
            build: build,
            steps: steps
        )
    }
}
