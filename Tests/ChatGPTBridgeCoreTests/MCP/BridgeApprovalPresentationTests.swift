import Foundation
import Testing
@testable import ChatGPTBridgeCore

@Suite("Approval presentation")
struct BridgeApprovalPresentationTests {
    @Test("Long commands and embedded content cannot alter approval copy")
    func longCommands() {
        for summary in ["", "swift test", "swift test; other-operation", String(repeating: "\n```<script>\u{001B}[31m密钥", count: 20_000)] {
            let request = BridgeApprovalRequest(id: "preview", tool: "run_command", summary: summary, target: ".")
            let copy = BridgeApprovalPresentation(request: request)
            #expect(copy.title.isEmpty)
            #expect(copy.message.isEmpty)
            #expect(copy.location == "当前工作区")
        }
    }

    @Test("Long paths are bounded and control and bidi characters are stripped")
    func boundedPath() {
        let target = "/project/\n\r\t\u{202E}" + String(repeating: "目录", count: 8_000)
        let copy = BridgeApprovalPresentation(request: BridgeApprovalRequest(id: "path", tool: "write", summary: "payload", target: target))
        #expect(copy.location.unicodeScalars.count <= 513)
        #expect(copy.location.hasSuffix("…"))
        #expect(!copy.location.contains("\n"))
        #expect(!copy.location.contains("\u{202E}"))
    }

    @Test("Unknown tools and restore IDs are not exposed as user-facing labels")
    func fallback() {
        let unknown = BridgeApprovalPresentation(request: BridgeApprovalRequest(id: "a", tool: String(repeating: "unknown", count: 4_000), summary: "raw"))
        #expect(unknown.title.isEmpty)
        #expect(unknown.message.isEmpty)
        let restored = BridgeApprovalPresentation(request: BridgeApprovalRequest(id: "b", tool: "restore_path", summary: "raw", target: UUID().uuidString))
        #expect(restored.location == "所选回收站项目")
    }

    @Test("Known argv has precise copy, unknown and compound commands have none")
    func preciseCommands() {
        func describe(_ program: String, _ args: [String]) -> String? {
            BridgeApprovalPresentation.describe(tool: "run_command", arguments: [
                "executable": .string(program), "arguments": .array(args.map(JSONValue.string))
            ])
        }
        #expect(describe("/usr/bin/swift", ["test"]) == "运行项目的 Swift 测试")
        #expect(describe("swift", ["build"]) == "编译 Swift 项目")
        #expect(describe("./Scripts/build-app.sh", []) == "运行项目的应用打包脚本")
        #expect(describe("git", ["diff", "--staged"]) == "查看已暂存的代码改动")
        #expect(describe("sh", ["-c", "swift test; arbitrary-operation"]) == nil)
        #expect(describe("swift", ["test", "--help"]) == nil)
        #expect(describe("python", ["custom.py"]) == nil)
    }

    @Test("File operation describes exact object and line range")
    func fileDetails() throws {
        let detail = BridgeApprovalPresentation.describe(tool: "patch_file", arguments: [
            "path": .string("Sources/RootView.swift"), "mode": .string("line_range"),
            "startLine": .number(10), "endLine": .number(20)
        ])
        #expect(detail == "替换“RootView.swift”第 10–20 行")
        let request = BridgeApprovalRequest(id: "test", tool: "patch_file", summary: "raw", actionDescription: detail)
        let decoded = try JSONDecoder().decode(BridgeApprovalRequest.self, from: JSONEncoder().encode(request))
        #expect(BridgeApprovalPresentation(request: decoded).message == detail)
    }
}
