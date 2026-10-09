import CryptoKit
import Foundation

/// Created only from server-resolved workspaces and tool arguments, never from
/// a caller-supplied approval flag or a human-readable command description.
public struct BridgeApprovalScope: Codable, Equatable, Sendable {
    public let workspacePath: String
    public let category: String
    public let discriminator: [String]

    /// File grants are exact-path and exact-payload. Safe, repeatable
    /// development commands may also be remembered for 24 hours, but only
    /// when both the executable and every argument are identical.
    /// Arbitrary shell, Git push, network and destructive commands stay
    /// one-shot even if the user previously approved them.
    public static func mayRemember(tool: String, details: [String] = []) -> Bool {
        if ["edit", "write", "patch_file", "create_directory"].contains(tool) {
            return true
        }
        guard ["run_command", "start_command"].contains(tool),
              let executable = details.first, !executable.isEmpty else { return false }
        let program = URL(fileURLWithPath: executable).lastPathComponent.lowercased()
        let args = Array(details.dropFirst())
        switch program {
        case "ps", "pgrep", "top", "lsof", "sample", "pwd", "which":
            return true
        case "swift":
            return ["test", "build"].contains(args.first)
        case "xcodebuild":
            return args.contains("test") || args.contains("build")
        case "npm":
            return args.first == "test" ||
                (args.count >= 2 && args[0] == "run" && ["build", "test"].contains(args[1]))
        case "mvn", "mvnw", "gradle", "gradlew":
            return args.contains(where: { ["test", "build", "verify"].contains($0) })
        default:
            return false
        }
    }

    public static func make(workspacePath: String, tool: String, target: String?, details: [String]) -> Self? {
        guard workspacePath.hasPrefix("/") else { return nil }
        let category: String
        let discriminator: [String]
        switch tool {
        case "edit", "write", "patch_file", "create_directory", "move_path", "trash_path", "restore_path":
            // A remembered file approval is for *one tool and one location*,
            // never every file in the workspace. No implicit grant for an
            // empty path, a workspace root, or an unresolved traversal.
            guard let target, !target.isEmpty else { return nil }
            let root = URL(fileURLWithPath: workspacePath, isDirectory: true)
                .standardizedFileURL.resolvingSymlinksInPath()
            let resolved: URL
            if target.hasPrefix("/") {
                resolved = URL(fileURLWithPath: target).standardizedFileURL.resolvingSymlinksInPath()
            } else {
                resolved = root.appendingPathComponent(target).standardizedFileURL.resolvingSymlinksInPath()
            }
            guard resolved.path.hasPrefix(root.path + "/"),
                  !target.split(separator: "/").contains("..") else { return nil }
            category = tool
            // Destination and actual contents can change the meaning of a
            // move, write or patch. Bind the exact supplied arguments too.
            discriminator = [resolved.path, Self.digest(details)]
        case "bash", "run_command", "start_command":
            category = "command"
            discriminator = [target ?? ".", Self.digest(details)]
        default:
            return nil
        }
        return Self(
            workspacePath: URL(fileURLWithPath: workspacePath).standardizedFileURL.resolvingSymlinksInPath().path,
            category: category,
            discriminator: discriminator
        )
    }

    private static func digest(_ fields: [String]) -> String {
        let data = (try? JSONEncoder().encode(fields)) ?? Data(UUID().uuidString.utf8)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public var id: String {
        // Array encoding preserves argument boundaries, including separators.
        let data = (try? JSONEncoder().encode([workspacePath, category] + discriminator)) ?? Data(UUID().uuidString.utf8)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public var explanation: String {
        category == "command"
            ? "24 小时内仅对本项目相同命令与参数生效，可随时撤销。"
            : "24 小时内仅对本项目相同文件、工具与参数生效，可随时撤销。"
    }
}
