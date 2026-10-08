import CryptoKit
import Foundation

/// Created only from server-resolved workspaces and tool arguments, never from
/// a caller-supplied approval flag or a human-readable command description.
public struct BridgeApprovalScope: Codable, Equatable, Sendable {
    public let workspacePath: String
    public let category: String
    public let discriminator: [String]

    public static func make(workspacePath: String, tool: String, target: String?, details: [String]) -> Self? {
        guard workspacePath.hasPrefix("/") else { return nil }
        let category: String
        let discriminator: [String]
        switch tool {
        case "edit", "write", "patch_file":
            category = "file-modification"
            discriminator = []
        case "create_directory", "move_path", "trash_path", "restore_path":
            category = tool
            discriminator = []
        case "bash", "run_command", "start_command":
            category = "command"
            discriminator = [target ?? "."] + details
        default:
            return nil
        }
        return Self(
            workspacePath: URL(fileURLWithPath: workspacePath).standardizedFileURL.resolvingSymlinksInPath().path,
            category: category,
            discriminator: discriminator
        )
    }

    var id: String {
        // Array encoding preserves argument boundaries, including separators.
        let data = try! JSONEncoder().encode([workspacePath, category] + discriminator)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public var explanation: String {
        category == "command"
            ? "仅限此工作区内相同的程序操作，可在设置中撤销。"
            : "仅限此工作区内同类文件操作，可在设置中撤销。"
    }
}
