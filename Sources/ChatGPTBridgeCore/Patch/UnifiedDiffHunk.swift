import Foundation

public enum UnifiedDiffLine: Equatable, Sendable {
    case context(String)
    case removal(String)
    case addition(String)

    var oldValue: String? {
        switch self {
        case .context(let value), .removal(let value): value
        case .addition: nil
        }
    }

    var newValue: String? {
        switch self {
        case .context(let value), .addition(let value): value
        case .removal: nil
        }
    }
}

public struct UnifiedDiffHunk: Equatable, Sendable {
    public let oldStart: Int
    public let oldCount: Int
    public let newStart: Int
    public let newCount: Int
    public let section: String?
    public let lines: [UnifiedDiffLine]

    public init(
        oldStart: Int,
        oldCount: Int,
        newStart: Int,
        newCount: Int,
        section: String? = nil,
        lines: [UnifiedDiffLine]
    ) {
        self.oldStart = oldStart
        self.oldCount = oldCount
        self.newStart = newStart
        self.newCount = newCount
        self.section = section
        self.lines = lines
    }
}

public struct UnifiedDiff: Equatable, Sendable {
    public let oldPath: String?
    public let newPath: String?
    public let hunks: [UnifiedDiffHunk]

    public init(oldPath: String?, newPath: String?, hunks: [UnifiedDiffHunk]) {
        self.oldPath = oldPath
        self.newPath = newPath
        self.hunks = hunks
    }
}
