import Foundation
import Testing
@testable import ChatGPTBridgeCore

@Suite("Project workflow")
struct ProjectWorkflowTests {
    @Test("detector recognizes supported project types")
    func detectsProjectTypes() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexHarborWorkflowDetect-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let detector = ProjectWorkflowDetector()

        try Data("// swift-tools-version: 6.0\n".utf8)
            .write(to: root.appendingPathComponent("Package.swift"))
        var plan = detector.plan(root: root)
        #expect(plan.kind == .swiftPackage)
        #expect(plan.commands.map(\.executable) == ["swift", "swift"])
        try FileManager.default.removeItem(at: root.appendingPathComponent("Package.swift"))

        let schemeDirectory = root
            .appendingPathComponent("Demo.xcodeproj", isDirectory: true)
            .appendingPathComponent("xcshareddata/xcschemes", isDirectory: true)
        try FileManager.default.createDirectory(at: schemeDirectory, withIntermediateDirectories: true)
        try Data("<Scheme/>".utf8).write(to: schemeDirectory.appendingPathComponent("Demo.xcscheme"))
        plan = detector.plan(root: root)
        #expect(plan.kind == .xcode)
        #expect(plan.commands.map(\.executable) == ["xcodebuild", "xcodebuild"])
        #expect(plan.commands.first?.arguments.contains("Demo") == true)
        try FileManager.default.removeItem(at: root.appendingPathComponent("Demo.xcodeproj"))

        let packageJSON = """
        {"scripts":{"test":"vitest run","build":"vite build"}}
        """
        try Data(packageJSON.utf8).write(to: root.appendingPathComponent("package.json"))
        plan = detector.plan(root: root)
        #expect(plan.kind == .node)
        #expect(plan.commands.count == 2)
        #expect(plan.commands[0].arguments == ["test"])
        #expect(plan.commands[1].arguments == ["run", "build"])
        try FileManager.default.removeItem(at: root.appendingPathComponent("package.json"))

        try Data("<project/>".utf8).write(to: root.appendingPathComponent("pom.xml"))
        plan = detector.plan(root: root)
        #expect(plan.kind == .maven)
        #expect(plan.commands.map(\.executable) == ["mvn", "mvn"])
        try FileManager.default.removeItem(at: root.appendingPathComponent("pom.xml"))

        try Data("plugins {}".utf8).write(to: root.appendingPathComponent("build.gradle"))
        plan = detector.plan(root: root)
        #expect(plan.kind == .gradle)
        #expect(plan.commands.map(\.executable) == ["gradle", "gradle"])
        try FileManager.default.removeItem(at: root.appendingPathComponent("build.gradle"))

        try Data("[project]\nname='demo'\n".utf8).write(to: root.appendingPathComponent("pyproject.toml"))
        plan = detector.plan(root: root)
        #expect(plan.kind == .python)
        #expect(plan.commands.count == 1)
        #expect(plan.commands.first?.executable == "python3")
    }

    @Test("workflow agent returns unsupported for an unknown project")
    func unsupportedProject() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexHarborWorkflowUnknown-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let workspaces = WorkspaceManager(allowedRoots: AllowedRootsManager(roots: [root]))
        let workspace = try await workspaces.open(path: root.path)
        let shell = ShellTool(
            workspaceManager: workspaces,
            permissionEngine: PermissionEngine(
                configuration: BridgeConfiguration(shellPermission: .allow)
            ),
            auditLogger: AuditLogger(paths: BridgePaths(root: root.appendingPathComponent("Bridge")))
        )
        let agent = ProjectWorkflowAgent(
            workspaceManager: workspaces,
            commandService: CommandService(shellTool: shell)
        )

        let result = try await agent.run(workspaceID: workspace.id)
        #expect(result.kind == .unknown)
        #expect(result.state == .unsupported)
        #expect(result.steps.isEmpty)
    }
}
