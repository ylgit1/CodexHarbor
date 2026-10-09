import Foundation

/// Bounded, plain-language UI copy. Raw command/payload remains in the request
/// for authorization and auditing, but never participates in window layout.
public struct BridgeApprovalPresentation: Sendable {
    public let title: String
    public let message: String
    public let location: String

    public init(request: BridgeApprovalRequest) {
        switch request.tool {
        case "edit", "patch_file":
            title = "修改文件"
        case "write":
            title = "写入文件"
        case "create_directory":
            title = "创建目录"
        case "move_path":
            title = "移动文件或目录"
        case "trash_path":
            title = "移入回收站"
        case "restore_path":
            title = "恢复文件或目录"
        default:
            title = ""
        }
        message = request.actionDescription.map { Self.displayText($0, limit: 180) } ?? ""
        if request.tool == "restore_path" {
            location = "所选回收站项目"
        } else if let target = request.target, !target.isEmpty, target != "." {
            // Limit before sanitizing so huge/unbroken values cannot create a
            // large text layout every second. Strip terminal/control/bidi data.
            let prefix = target.unicodeScalars.prefix(513)
            let visible = prefix.prefix(512).filter {
                !CharacterSet.controlCharacters.contains($0) && $0.properties.generalCategory != .format
            }
            let cleaned = String(String.UnicodeScalarView(visible))
            location = cleaned.isEmpty ? "当前工作区" : cleaned + (prefix.count > 512 ? "…" : "")
        } else {
            location = "当前工作区"
        }
    }

    /// Descriptions are based on argv, not substring matches in shell source
    /// or a model-supplied explanation. Unknown commands have no description.
    public static func describe(tool: String, arguments: [String: JSONValue]) -> String? {
        let filename = arguments["path"]?.stringValue.map {
            displayText(URL(fileURLWithPath: $0).lastPathComponent, limit: 48)
        }
        switch tool {
        case "edit":
            return filename.map { "替换“\($0)”中匹配的文本" }
        case "patch_file":
            guard let filename else { return nil }
            if arguments["mode"]?.stringValue == "line_range",
               let start = arguments["startLine"]?.intValue,
               let end = arguments["endLine"]?.intValue {
                return "替换“\(filename)”第 \(start)–\(end) 行"
            }
            return "向“\(filename)”应用文件补丁"
        case "write":
            return filename.map { arguments["overwrite"]?.boolValue == true
                ? "写入“\($0)”；文件已存在时覆盖原内容"
                : "创建文件“\($0)”" }
        case "create_directory":
            return filename.map { "创建目录“\($0)”" }
        case "trash_path":
            return filename.map { "将“\($0)”移入回收站" }
        case "move_path":
            guard let filename, let destination = arguments["destination"]?.stringValue else { return nil }
            return "将“\(filename)”移动到“\(displayText(destination, limit: 80))”"
        case "run_command", "start_command", "bash":
            guard let executable = arguments["executable"]?.stringValue else { return nil }
            let args = (arguments["arguments"]?.arrayValue ?? []).compactMap(\.stringValue)
            let program = URL(fileURLWithPath: executable).lastPathComponent
            switch (program, args) {
            case ("swift", ["test"]): return "运行项目的 Swift 测试"
            case ("swift", ["build"]): return "编译 Swift 项目"
            case ("npm", ["test"]), ("npm", ["run", "test"]): return "运行项目定义的测试脚本"
            case ("npm", ["run", "build"]): return "运行项目定义的构建脚本"
            case ("git", ["status"]): return "检查哪些文件已修改、暂存或尚未跟踪"
            case ("git", ["diff"]): return "查看尚未暂存的代码改动"
            case ("git", ["diff", "--cached"]), ("git", ["diff", "--staged"]): return "查看已暂存的代码改动"
            case ("zsh", ["./Scripts/build-app.sh"]), ("bash", ["./Scripts/build-app.sh"]):
                return "运行项目的应用打包脚本"
            default:
                if ["./Scripts/build-app.sh", "Scripts/build-app.sh"].contains(executable), args.isEmpty {
                    return "运行项目的应用打包脚本"
                }
                return nil
            }
        default:
            return nil
        }
    }

    private static func displayText(_ value: String, limit: Int) -> String {
        let prefix = value.unicodeScalars.prefix(limit + 1)
        let scalars = prefix.prefix(limit).filter {
            !CharacterSet.controlCharacters.contains($0) && $0.properties.generalCategory != .format
        }
        return String(String.UnicodeScalarView(scalars)) + (prefix.count > limit ? "…" : "")
    }
}
