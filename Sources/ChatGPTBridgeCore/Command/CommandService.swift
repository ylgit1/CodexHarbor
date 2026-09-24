import Foundation

public struct CommandService: Sendable {
    private let shellTool: ShellTool

    public init(shellTool: ShellTool) {
        self.shellTool = shellTool
    }

    public func run(
        workspaceID: UUID,
        executable: String,
        arguments: [String] = [],
        workingDirectory: String = ".",
        timeoutSeconds: Int = 30,
        approvalGranted: Bool = false,
        auditTool: String = "run_command"
    ) async throws -> ShellResult {
        try await shellTool.execute(
            workspaceID: workspaceID,
            request: CommandRequest(
                executable: executable,
                arguments: arguments,
                workingDirectory: workingDirectory,
                timeoutSeconds: timeoutSeconds
            ),
            approvalGranted: approvalGranted,
            auditTool: auditTool
        )
    }
}
