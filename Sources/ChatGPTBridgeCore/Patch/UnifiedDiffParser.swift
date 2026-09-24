import Foundation

public struct UnifiedDiffParser: Sendable {
    public init() {}

    public func parse(_ patch: String) throws -> UnifiedDiff {
        let lines = patch.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var oldPath: String?
        var newPath: String?
        var hunks: [UnifiedDiffHunk] = []
        var index = 0

        while index < lines.count {
            let line = lines[index]
            if line.hasPrefix("--- ") {
                if !hunks.isEmpty {
                    throw BridgeError.patchFailed("单次 patch_file 仅支持一个目标文件")
                }
                oldPath = Self.path(from: line, prefix: "--- ")
                index += 1
                continue
            }
            if line.hasPrefix("+++ ") {
                newPath = Self.path(from: line, prefix: "+++ ")
                index += 1
                continue
            }
            guard line.hasPrefix("@@") else {
                index += 1
                continue
            }

            let header = try Self.parseHeader(line)
            index += 1
            var hunkLines: [UnifiedDiffLine] = []
            while index < lines.count, !lines[index].hasPrefix("@@") {
                let body = lines[index]
                if body.isEmpty, index == lines.count - 1 {
                    index += 1
                    break
                }
                if body.hasPrefix("--- ") || body.hasPrefix("+++ ") || body.hasPrefix("diff --git ") {
                    break
                }
                if body == "\\ No newline at end of file" {
                    index += 1
                    continue
                }
                guard let marker = body.first else {
                    throw BridgeError.patchFailed("hunk 中存在缺少前缀的空行")
                }
                let value = String(body.dropFirst())
                switch marker {
                case " ": hunkLines.append(.context(value))
                case "-": hunkLines.append(.removal(value))
                case "+": hunkLines.append(.addition(value))
                default:
                    throw BridgeError.patchFailed("hunk 行前缀无效：\(marker)")
                }
                index += 1
            }

            let actualOldCount = hunkLines.compactMap(\.oldValue).count
            let actualNewCount = hunkLines.compactMap(\.newValue).count
            guard actualOldCount == header.oldCount, actualNewCount == header.newCount else {
                throw BridgeError.patchFailed(
                    "hunk 行数与声明不一致：期望 -\(header.oldCount)/+\(header.newCount)，实际 -\(actualOldCount)/+\(actualNewCount)"
                )
            }
            hunks.append(UnifiedDiffHunk(
                oldStart: header.oldStart,
                oldCount: header.oldCount,
                newStart: header.newStart,
                newCount: header.newCount,
                section: header.section,
                lines: hunkLines
            ))
        }

        guard !hunks.isEmpty else {
            throw BridgeError.patchFailed("未找到 unified diff hunk")
        }
        return UnifiedDiff(oldPath: oldPath, newPath: newPath, hunks: hunks)
    }

    private static func path(from line: String, prefix: String) -> String {
        let value = line.dropFirst(prefix.count)
        return String(value.split(separator: "\t", maxSplits: 1).first ?? Substring(value))
    }

    private static func parseHeader(_ line: String) throws -> (
        oldStart: Int,
        oldCount: Int,
        newStart: Int,
        newCount: Int,
        section: String?
    ) {
        let pattern = #"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@(?: (.*))?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else {
            throw BridgeError.patchFailed("hunk header 无效：\(line)")
        }

        func integer(_ position: Int, default defaultValue: Int? = nil) throws -> Int {
            let range = match.range(at: position)
            if range.location == NSNotFound, let defaultValue { return defaultValue }
            guard let swiftRange = Range(range, in: line), let value = Int(line[swiftRange]) else {
                throw BridgeError.patchFailed("hunk header 行号无效：\(line)")
            }
            return value
        }

        let sectionRange = match.range(at: 5)
        let section = sectionRange.location == NSNotFound
            ? nil
            : Range(sectionRange, in: line).map { String(line[$0]) }
        return (
            try integer(1),
            try integer(2, default: 1),
            try integer(3),
            try integer(4, default: 1),
            section
        )
    }
}
