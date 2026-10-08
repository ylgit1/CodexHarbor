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
    private var sortedRecords: [CodexTokenUsageRecord] = []
    private var knownRolloutFiles: [URL] = []
    private var lastFullDiscoveryAt: Date?
    private var lastHistoricalPollAt: Date?
    private let fullDiscoveryInterval: TimeInterval = 300
    private let historicalPollInterval: TimeInterval = 30
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
        self.sortedRecords = Self.orderedRecords(self.recordsByID.values)
    }

    public func recentUsage() -> [CodexTokenUsageRecord] {
        let now = Date()
        let cutoff = now.addingTimeInterval(-30 * 24 * 60 * 60)
        var changed = false
        var recordsChanged = false
        let (files, didDiscoverAll) = filesToPoll(at: now)
        let livePaths = didDiscoverAll ? Set(knownRolloutFiles.map(\.path)) : []

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
                    if let record = parse(String(line)),
                       recordsByID[record.id] != record {
                        recordsByID[record.id] = record
                        recordsChanged = true
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

        if didDiscoverAll {
            for path in fileOffsets.keys where !livePaths.contains(path) {
                fileOffsets.removeValue(forKey: path)
                changed = true
            }
        }

        // No new token data means there is no reason to re-sort the entire
        // retained history on every 10-second telemetry refresh.
        if recordsChanged || sortedRecords.first.map({ $0.timestamp < cutoff }) == true {
            let retained = recordsByID.filter { $0.value.timestamp >= cutoff }
            if retained.count != recordsByID.count { changed = true }
            recordsByID = retained
            sortedRecords = Self.orderedRecords(recordsByID.values)
        }
        if changed { persistState() }
        return sortedRecords
    }

    /// Fast path: discover today's new rollouts each poll, while checking
    /// historical rollouts less often. A full recursive scan still runs every
    /// five minutes, so imported or moved sessions are eventually discovered.
    private func filesToPoll(at now: Date) -> (files: [URL], didDiscoverAll: Bool) {
        let fullScan = lastFullDiscoveryAt.map {
            now.timeIntervalSince($0) >= fullDiscoveryInterval
        } ?? true
        if fullScan {
            knownRolloutFiles = rolloutFiles()
            lastFullDiscoveryAt = now
        }

        let recent = recentRolloutFiles(at: now)
        let knownPaths = Set(knownRolloutFiles.map(\.path))
        knownRolloutFiles.append(contentsOf: recent.filter { !knownPaths.contains($0.path) })

        let historicalPoll = fullScan || (lastHistoricalPollAt.map {
            now.timeIntervalSince($0) >= historicalPollInterval
        } ?? true)
        if historicalPoll {
            lastHistoricalPollAt = now
            return (knownRolloutFiles, fullScan)
        }

        // Continue reading active day's appended token records immediately.
        return (recent, false)
    }

    private func recentRolloutFiles(at now: Date) -> [URL] {
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var folders = Set<String>()
        for calendar in [Calendar.current, utcCalendar] {
            for date in [now, now.addingTimeInterval(-86_400)] {
                let components = calendar.dateComponents([.year, .month, .day], from: date)
                guard let year = components.year, let month = components.month,
                      let day = components.day else { continue }
                folders.insert(String(format: "%04d/%02d/%02d", year, month, day))
            }
        }

        return folders.flatMap { relativePath in
            let folder = paths.sessionsURL.appendingPathComponent(relativePath, isDirectory: true)
            let contents = (try? fileManager.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            return contents.filter { $0.pathExtension == "jsonl" }
        }
    }

    private static func orderedRecords<S: Sequence>(_ values: S) -> [CodexTokenUsageRecord]
        where S.Element == CodexTokenUsageRecord {
        values.sorted {
            if $0.timestamp == $1.timestamp { return $0.id < $1.id }
            return $0.timestamp < $1.timestamp
        }
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
