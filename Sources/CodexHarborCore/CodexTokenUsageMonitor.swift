import Foundation

/// Token usage emitted by Codex for one completed turn. This is deliberately
/// kept separate from provider billing: it describes the tokens Codex itself
/// recorded for the request.
public struct CodexTokenUsageRecord: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let timestamp: Date
    public let inputTokens: Int
    public let cachedInputTokens: Int
    public let outputTokens: Int
    public let reasoningOutputTokens: Int
    public let totalTokens: Int

    public init(
        id: String,
        timestamp: Date,
        inputTokens: Int,
        cachedInputTokens: Int = 0,
        outputTokens: Int,
        reasoningOutputTokens: Int = 0,
        totalTokens: Int
    ) {
        self.id = id
        self.timestamp = timestamp
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.outputTokens = outputTokens
        self.reasoningOutputTokens = reasoningOutputTokens
        self.totalTokens = totalTokens
    }
}

private struct CodexTokenUsageMonitorState: Codable {
    var fileOffsets: [String: Int64]
    var records: [CodexTokenUsageRecord]
}

/// Incrementally tails Codex rollout JSONL files. Files are fingerprinted by
/// byte offset, so the 300MB+ history directory is never rescanned on every
/// poll or launch after the first pass.
public actor CodexTokenUsageMonitor {
    private let paths: CodexPaths
    private let fileManager: FileManager
    private var fileOffsets: [String: Int64]
    private var recordsByID: [String: CodexTokenUsageRecord]
    private let isoFormatter: ISO8601DateFormatter

    public init(
        paths: CodexPaths = .live(),
        fileManager: FileManager = .default
    ) {
        self.paths = paths
        self.fileManager = fileManager
        self.fileOffsets = [:]
        self.recordsByID = [:]
        self.isoFormatter = ISO8601DateFormatter()

        if let data = try? Data(contentsOf: paths.tokenMonitorStateURL),
           let state = try? JSONDecoder().decode(CodexTokenUsageMonitorState.self, from: data) {
            // Older builds cleared the whole record cache when one rollout
            // file rotated. A suspiciously small cache means it may have been
            // truncated; rescan the immutable rollout history once to recover
            // the missing account/API usage records.
            if state.records.count < 20 && !state.fileOffsets.isEmpty {
                self.fileOffsets = [:]
                self.recordsByID = [:]
            } else {
                self.fileOffsets = state.fileOffsets
                self.recordsByID = Dictionary(uniqueKeysWithValues: state.records.map { ($0.id, $0) })
            }
        }
    }

    public func recentUsage() -> [CodexTokenUsageRecord] {
        let cutoff = Date().addingTimeInterval(-30 * 24 * 60 * 60)
        var changed = false
        let files = rolloutFiles()
        let livePaths = Set(files.map(\.path))

        for fileURL in files {
            let path = fileURL.path
            let size = fileSize(fileURL)
            let previousOffset = fileOffsets[path] ?? 0
            if size < previousOffset {
                // A rewritten rollout is rare; reset only its offset. Keep
                // records from other rollout files; they belong to independent
                // turns and must survive rotation and connection switching.
                fileOffsets[path] = 0
                changed = true
            }
            let offset = min(fileOffsets[path] ?? 0, size)
            guard size > offset, let handle = try? FileHandle(forReadingFrom: fileURL) else { continue }
            defer { try? handle.close() }
            do {
                try handle.seek(toOffset: UInt64(offset))
                let data = try handle.readToEnd() ?? Data()
                let text = String(decoding: data, as: UTF8.self)
                for line in text.split(whereSeparator: \.isNewline) {
                    if let record = parse(String(line)) {
                        recordsByID[record.id] = record
                        changed = true
                    }
                }
                fileOffsets[path] = size
                changed = true
            } catch {
                // A turn can be appended while we read it. Keeping the old
                // offset makes the partial tail retry on the next poll.
            }
        }

        for path in fileOffsets.keys where !livePaths.contains(path) {
            fileOffsets.removeValue(forKey: path)
            changed = true
        }
        recordsByID = recordsByID.filter { $0.value.timestamp >= cutoff }
        if changed { persistState() }
        return recordsByID.values.sorted { $0.timestamp < $1.timestamp }
    }

    private func rolloutFiles() -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: paths.sessionsURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return enumerator.compactMap { item in
            guard let url = item as? URL, url.pathExtension == "jsonl" else { return nil }
            return url
        }
    }

    private func fileSize(_ url: URL) -> Int64 {
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    private func parse(_ line: String) -> CodexTokenUsageRecord? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == "token_usage_record",
              let payload = object["payload"] as? [String: Any],
              let turnID = payload["turn_id"] as? String,
              let usage = payload["usage"] as? [String: Any],
              let totalTokens = integer(usage["total_tokens"]) else { return nil }

        let threadID = (payload["thread_id"] as? String) ?? (payload["session_id"] as? String) ?? "unknown"
        let timestamp = (object["timestamp"] as? String).flatMap(isoFormatter.date) ?? Date()
        return CodexTokenUsageRecord(
            id: "\(threadID)/\(turnID)",
            timestamp: timestamp,
            inputTokens: integer(usage["input_tokens"]) ?? 0,
            cachedInputTokens: integer(usage["cached_input_tokens"]) ?? 0,
            outputTokens: integer(usage["output_tokens"]) ?? 0,
            reasoningOutputTokens: integer(usage["reasoning_output_tokens"]) ?? 0,
            totalTokens: totalTokens
        )
    }

    private func integer(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    private func persistState() {
        let state = CodexTokenUsageMonitorState(
            fileOffsets: fileOffsets,
            records: Array(recordsByID.values)
        )
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? fileManager.createDirectory(at: paths.appSupport, withIntermediateDirectories: true)
        try? data.write(to: paths.tokenMonitorStateURL, options: .atomic)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.tokenMonitorStateURL.path)
    }
}
