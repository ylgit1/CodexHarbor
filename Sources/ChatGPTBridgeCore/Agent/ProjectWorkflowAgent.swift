import Foundation

public enum ProjectWorkflowKind: String, Codable, Equatable, Sendable {
    case swiftPackage
    case xcode
    case node
    case python
    case maven
    case gradle
    case unknown
}

public enum ProjectWorkflowState: String, Codable, Equatable, Sendable {
    case planned
    case completed
    case failed
    case unsupported
}

public struct ProjectWorkflowCommand: Codable, Equatable, Sendable {
    public let name: String
    public let executable: String
    public let arguments: [String]
    public let workingDirectory: String

    public init(
        name: String,
        executable: String,
        arguments: [String],
        workingDirectory: String = "."
    ) {
        self.name = name
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
    }
}

public struct ProjectWorkflowPlan: Codable, Equatable, Sendable {
    public let kind: ProjectWorkflowKind
    public let commands: [ProjectWorkflowCommand]
    public let message: String
}

public struct ProjectWorkflowStepResult: Codable, Equatable, Sendable {
    public let name: String
    public let command: ProjectWorkflowCommand
    public let result: ShellResult
}

public struct ProjectWorkflowResult: Codable, Equatable, Sendable {
    public let kind: ProjectWorkflowKind
    public let state: ProjectWorkflowState
    public let message: String
    public let steps: [ProjectWorkflowStepResult]
}

public struct ProjectWorkflowDetector: Sendable {
    public init() {}

    public func plan(
        root: URL,
        includeTests: Bool = true,
        includeBuild: Bool = true
    ) -> ProjectWorkflowPlan {
        if exists("Package.swift", root: root) {
            var commands: [ProjectWorkflowCommand] = []
            if includeTests {
                commands.append(ProjectWorkflowCommand(
                    name: "Swift tests",
                    executable: "swift",
                    arguments: ["test"]
                ))
            }
            if includeBuild {
                commands.append(ProjectWorkflowCommand(
                    name: "Swift build",
                    executable: "swift",
                    arguments: ["build"]
                ))
            }
            return ProjectWorkflowPlan(
                kind: .swiftPackage,
                commands: commands,
                message: "Detected Swift Package Manager project"
            )
        }

        if let xcode = xcodeProject(at: root) {
            guard let scheme = sharedScheme(for: xcode.url) else {
                return ProjectWorkflowPlan(
                    kind: .xcode,
                    commands: [],
                    message: "Detected Xcode \(xcode.kind), but no shared scheme is available"
                )
            }
            let containerFlag = xcode.kind == "workspace" ? "-workspace" : "-project"
            var commands: [ProjectWorkflowCommand] = []
            if includeTests {
                commands.append(ProjectWorkflowCommand(
                    name: "Xcode tests",
                    executable: "xcodebuild",
                    arguments: [
                        containerFlag, xcode.url.lastPathComponent,
                        "-scheme", scheme,
                        "-configuration", "Debug",
                        "test",
                        "CODE_SIGNING_ALLOWED=NO"
                    ]
                ))
            }
            if includeBuild {
                commands.append(ProjectWorkflowCommand(
                    name: "Xcode build",
                    executable: "xcodebuild",
                    arguments: [
                        containerFlag, xcode.url.lastPathComponent,
                        "-scheme", scheme,
                        "-configuration", "Debug",
                        "build",
                        "CODE_SIGNING_ALLOWED=NO"
                    ]
                ))
            }
            return ProjectWorkflowPlan(
                kind: .xcode,
                commands: commands,
                message: "Detected Xcode \(xcode.kind) with shared scheme \(scheme)"
            )
        }

        if exists("package.json", root: root) {
            let scripts = nodeScripts(root: root)
            var commands: [ProjectWorkflowCommand] = []
            if includeTests, let test = scripts["test"], !Self.isDefaultNodeTest(test) {
                commands.append(ProjectWorkflowCommand(
                    name: "Node tests",
                    executable: "npm",
                    arguments: ["test"]
                ))
            }
            if includeBuild, scripts["build"] != nil {
                commands.append(ProjectWorkflowCommand(
                    name: "Node build",
                    executable: "npm",
                    arguments: ["run", "build"]
                ))
            }
            return ProjectWorkflowPlan(
                kind: .node,
                commands: commands,
                message: commands.isEmpty
                    ? "Detected Node project, but no test/build scripts are defined"
                    : "Detected Node project"
            )
        }

        if exists("pom.xml", root: root) {
            var commands: [ProjectWorkflowCommand] = []
            if includeTests {
                commands.append(ProjectWorkflowCommand(
                    name: "Maven tests",
                    executable: "mvn",
                    arguments: ["test"]
                ))
            }
            if includeBuild {
                commands.append(ProjectWorkflowCommand(
                    name: "Maven package",
                    executable: "mvn",
                    arguments: ["-DskipTests", "package"]
                ))
            }
            return ProjectWorkflowPlan(
                kind: .maven,
                commands: commands,
                message: "Detected Maven project"
            )
        }

        if exists("gradlew", root: root) || exists("build.gradle", root: root) || exists("build.gradle.kts", root: root) {
            let executable = exists("gradlew", root: root) ? "./gradlew" : "gradle"
            var commands: [ProjectWorkflowCommand] = []
            if includeTests {
                commands.append(ProjectWorkflowCommand(
                    name: "Gradle tests",
                    executable: executable,
                    arguments: ["test"]
                ))
            }
            if includeBuild {
                commands.append(ProjectWorkflowCommand(
                    name: "Gradle build",
                    executable: executable,
                    arguments: ["build", "-x", "test"]
                ))
            }
            return ProjectWorkflowPlan(
                kind: .gradle,
                commands: commands,
                message: "Detected Gradle project"
            )
        }

        if exists("pyproject.toml", root: root)
            || exists("pytest.ini", root: root)
            || exists("requirements.txt", root: root)
            || directoryExists("tests", root: root) {
            var commands: [ProjectWorkflowCommand] = []
            if includeTests {
                commands.append(ProjectWorkflowCommand(
                    name: "Python tests",
                    executable: "python3",
                    arguments: ["-m", "pytest"]
                ))
            }
            return ProjectWorkflowPlan(
                kind: .python,
                commands: commands,
                message: includeBuild
                    ? "Detected Python project; automatic build is not assumed, tests will be used for verification"
                    : "Detected Python project"
            )
        }

        return ProjectWorkflowPlan(
            kind: .unknown,
            commands: [],
            message: "No supported project workflow was detected"
        )
    }

    private func xcodeProject(at root: URL) -> (url: URL, kind: String)? {
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        if let workspace = children
            .filter({ $0.pathExtension == "xcworkspace" })
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            .first {
            return (workspace, "workspace")
        }
        if let project = children
            .filter({ $0.pathExtension == "xcodeproj" })
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            .first {
            return (project, "project")
        }
        return nil
    }

    private func sharedScheme(for container: URL) -> String? {
        let directory = container
            .appendingPathComponent("xcshareddata", isDirectory: true)
            .appendingPathComponent("xcschemes", isDirectory: true)
        guard let schemes = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        return schemes
            .filter { $0.pathExtension == "xcscheme" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
            .first
    }

    private func exists(_ relativePath: String, root: URL) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(relativePath).path)
    }

    private func directoryExists(_ relativePath: String, root: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(
            atPath: root.appendingPathComponent(relativePath).path,
            isDirectory: &isDirectory
        ) && isDirectory.boolValue
    }

    private func nodeScripts(root: URL) -> [String: String] {
        let url = root.appendingPathComponent("package.json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let scripts = object["scripts"] as? [String: Any] else {
            return [:]
        }
        return scripts.reduce(into: [:]) { result, item in
            if let value = item.value as? String {
                result[item.key] = value
            }
        }
    }

    private static func isDefaultNodeTest(_ script: String) -> Bool {
        let normalized = script.lowercased()
        return normalized.contains("no test specified") || normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

public struct ProjectWorkflowAgent: Sendable {
    private let workspaceManager: WorkspaceManager
    private let commandService: CommandService
    private let detector: ProjectWorkflowDetector

    public init(
        workspaceManager: WorkspaceManager,
        commandService: CommandService,
        detector: ProjectWorkflowDetector = ProjectWorkflowDetector()
    ) {
        self.workspaceManager = workspaceManager
        self.commandService = commandService
        self.detector = detector
    }

    public func plan(
        workspaceID: UUID,
        includeTests: Bool = true,
        includeBuild: Bool = true
    ) async throws -> ProjectWorkflowPlan {
        let workspace = try await workspaceManager.workspace(id: workspaceID)
        return detector.plan(
            root: URL(fileURLWithPath: workspace.rootPath, isDirectory: true),
            includeTests: includeTests,
            includeBuild: includeBuild
        )
    }

    public func run(
        workspaceID: UUID,
        includeTests: Bool = true,
        includeBuild: Bool = true,
        timeoutSeconds: Int = 300,
        approvalGranted: Bool = false
    ) async throws -> ProjectWorkflowResult {
        let plan = try await plan(
            workspaceID: workspaceID,
            includeTests: includeTests,
            includeBuild: includeBuild
        )
        guard plan.kind != .unknown else {
            return ProjectWorkflowResult(
                kind: .unknown,
                state: .unsupported,
                message: plan.message,
                steps: []
            )
        }
        guard !plan.commands.isEmpty else {
            return ProjectWorkflowResult(
                kind: plan.kind,
                state: .unsupported,
                message: plan.message,
                steps: []
            )
        }

        var steps: [ProjectWorkflowStepResult] = []
        for command in plan.commands {
            let result = try await commandService.run(
                workspaceID: workspaceID,
                executable: command.executable,
                arguments: command.arguments,
                workingDirectory: command.workingDirectory,
                timeoutSeconds: timeoutSeconds,
                approvalGranted: approvalGranted,
                auditTool: "run_workflow"
            )
            steps.append(ProjectWorkflowStepResult(
                name: command.name,
                command: command,
                result: result
            ))
            if result.exitCode != 0 {
                return ProjectWorkflowResult(
                    kind: plan.kind,
                    state: .failed,
                    message: "\(command.name) failed",
                    steps: steps
                )
            }
        }

        return ProjectWorkflowResult(
            kind: plan.kind,
            state: .completed,
            message: "Project workflow completed",
            steps: steps
        )
    }
}
