import Foundation

public struct PatchApplier: Sendable {
    public init() {}

    public func apply(_ diff: UnifiedDiff, to original: String) throws -> String {
        let hadTrailingNewline = original.hasSuffix("\n")
        var lines = original.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if hadTrailingNewline, lines.last == "" { lines.removeLast() }
        if original.isEmpty { lines = [] }

        var lineOffset = 0
        var previousOldEnd = 0
        for hunk in diff.hunks {
            guard hunk.oldStart >= previousOldEnd else {
                throw BridgeError.patchFailed("hunk 顺序重叠或逆序")
            }
            let baseIndex = hunk.oldCount == 0 ? hunk.oldStart : hunk.oldStart - 1
            let targetIndex = baseIndex + lineOffset
            let oldLines = hunk.lines.compactMap(\.oldValue)
            let newLines = hunk.lines.compactMap(\.newValue)
            guard targetIndex >= 0, targetIndex + oldLines.count <= lines.count else {
                throw BridgeError.patchFailed("hunk 位置超出文件范围：-\(hunk.oldStart),\(hunk.oldCount)")
            }
            let existing = Array(lines[targetIndex..<(targetIndex + oldLines.count)])
            guard existing == oldLines else {
                let mismatch = existing.indices.first { existing[$0] != oldLines[$0] } ?? 0
                throw BridgeError.patchFailed(
                    "hunk 上下文不匹配：原文件第 \(targetIndex + mismatch + 1) 行与 patch 不一致"
                )
            }
            lines.replaceSubrange(targetIndex..<(targetIndex + oldLines.count), with: newLines)
            lineOffset += newLines.count - oldLines.count
            previousOldEnd = hunk.oldStart + hunk.oldCount
        }

        let result = lines.joined(separator: "\n")
        return hadTrailingNewline ? result + "\n" : result
    }
}
