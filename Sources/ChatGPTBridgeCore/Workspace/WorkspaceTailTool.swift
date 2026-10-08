import Foundation

public struct WorkspaceTailResult: Codable, Equatable, Sendable {
    public let path: String
    public let startOffset: Int
    public let totalBytes: Int
    public let content: String
    public let truncated: Bool
}

public struct WorkspaceTailTool: Sendable {
    public static let maximumTailBytes = 256 * 1_024

    private let workspaceManager: WorkspaceManager
    private let validator = PathValidator()
    private let redactor = SecretRedactor()

    public init(workspaceManager: WorkspaceManager) {
        self.workspaceManager = workspaceManager
    }

    /// Read only the end of a potentially huge text log. Never allocate or
    /// return the entire file. Use this instead of failing at read's 4 MiB cap.
    public func execute(workspaceID: UUID, path: String, limitBytes: Int = 64 * 1_024) async throws -> WorkspaceTailResult {
        let workspace = try await workspaceManager.workspace(id: workspaceID)
        let url = try validator.resolve(workspace: workspace, relativePath: path)
        guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw BridgeError.invalidPath(path)
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        let limit = max(1, min(limitBytes, Self.maximumTailBytes))
        let start = size > UInt64(limit) ? size - UInt64(limit) : 0
        try handle.seek(toOffset: start)
        let bytes = try handle.read(upToCount: limit) ?? Data()
        return WorkspaceTailResult(
            path: path,
            startOffset: Int(start),
            totalBytes: Int(size),
            content: redactor.redact(String(decoding: bytes, as: UTF8.self)),
            truncated: start > 0
        )
    }
}
