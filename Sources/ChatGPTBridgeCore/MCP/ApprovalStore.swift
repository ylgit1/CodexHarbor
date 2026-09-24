import CryptoKit
import Foundation

public enum BridgeApprovalDecision: String, Codable, Sendable {
    case pending
    case granted
    case denied
}

public struct BridgeApprovalRequest: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let tool: String
    public let summary: String
    public let target: String?
    public let createdAt: Date
    public var decision: BridgeApprovalDecision

    public init(
        id: String,
        tool: String,
        summary: String,
        target: String? = nil,
        createdAt: Date = Date(),
        decision: BridgeApprovalDecision = .pending
    ) {
        self.id = id
        self.tool = tool
        self.summary = summary
        self.target = target
        self.createdAt = createdAt
        self.decision = decision
    }
}

public final class BridgeApprovalStore: @unchecked Sendable {
    private let directory: URL
    private let lock = NSLock()
    private let ttl: TimeInterval

    public init(paths: BridgePaths, ttl: TimeInterval = 10 * 60) {
        self.directory = paths.root.appendingPathComponent("approvals", isDirectory: true)
        self.ttl = ttl
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public static func requestID(
        tool: String,
        workspaceID: UUID?,
        target: String?,
        details: [String]
    ) -> String {
        let payload = ([tool, workspaceID?.uuidString ?? "", target ?? ""] + details)
            .joined(separator: "\u{1F}")
        let digest = SHA256.hash(data: Data(payload.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public func request(
        id: String,
        tool: String,
        summary: String,
        target: String? = nil
    ) {
        withLock {
            pruneExpiredLocked()
            let url = requestURL(id)
            if let existing = loadLocked(url), existing.decision == .pending {
                return
            }
            let request = BridgeApprovalRequest(
                id: id,
                tool: tool,
                summary: summary,
                target: target
            )
            saveLocked(request, to: url)
        }
    }

    public func consumeDecision(id: String) -> BridgeApprovalDecision? {
        withLock {
            pruneExpiredLocked()
            let url = requestURL(id)
            guard let request = loadLocked(url) else { return nil }
            switch request.decision {
            case .pending:
                return nil
            case .granted, .denied:
                try? FileManager.default.removeItem(at: url)
                return request.decision
            }
        }
    }

    public func waitForDecision(
        id: String,
        timeout: TimeInterval = 90
    ) async -> BridgeApprovalDecision? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline && !Task.isCancelled {
            if let decision = consumeDecision(id: id) {
                return decision
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return nil
    }

    public func pendingRequests() -> [BridgeApprovalRequest] {
        withLock {
            pruneExpiredLocked()
            guard let urls = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { return [] }

            return urls
                .compactMap(loadLocked)
                .filter { $0.decision == .pending }
                .sorted { $0.createdAt > $1.createdAt }
        }
    }

    public func decide(id: String, allow: Bool) {
        withLock {
            pruneExpiredLocked()
            let url = requestURL(id)
            guard var request = loadLocked(url), request.decision == .pending else { return }
            request.decision = allow ? .granted : .denied
            saveLocked(request, to: url)
        }
    }

    public func clear() {
        withLock {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    private func requestURL(_ id: String) -> URL {
        directory.appendingPathComponent("\(id).json")
    }

    private func pruneExpiredLocked(now: Date = Date()) {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }

        for url in urls {
            guard let request = loadLocked(url) else {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            if now.timeIntervalSince(request.createdAt) > ttl {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private func loadLocked(_ url: URL) -> BridgeApprovalRequest? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(BridgeApprovalRequest.self, from: data)
    }

    private func saveLocked(_ request: BridgeApprovalRequest, to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(request) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func withLock<T>(_ operation: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }
}

public enum BridgeLogRotator {
    public static func rotateIfNeeded(
        _ url: URL,
        maximumBytes: Int = 8 * 1_024 * 1_024,
        backups: Int = 3,
        fileManager: FileManager = .default
    ) {
        guard backups > 0,
              let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber,
              size.intValue >= maximumBytes else { return }

        for index in stride(from: backups, through: 1, by: -1) {
            let destination = URL(fileURLWithPath: url.path + ".\(index)")
            if index == backups {
                try? fileManager.removeItem(at: destination)
            }
            let source = index == 1
                ? url
                : URL(fileURLWithPath: url.path + ".\(index - 1)")
            if fileManager.fileExists(atPath: source.path) {
                try? fileManager.moveItem(at: source, to: destination)
            }
        }
    }
}
