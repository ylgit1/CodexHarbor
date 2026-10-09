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
    public let rememberScope: BridgeApprovalScope?
    public let expiresAt: Date?
    /// Chinese copy derived by the server from structured tool arguments.
    /// Absent when the exact purpose cannot be established.
    public let actionDescription: String?

    public var deadline: Date { expiresAt ?? createdAt.addingTimeInterval(90) }

    public func remainingSeconds(at now: Date) -> Int {
        max(0, Int(ceil(deadline.timeIntervalSince(now))))
    }

    public init(
        id: String,
        tool: String,
        summary: String,
        target: String? = nil,
        createdAt: Date = Date(),
        decision: BridgeApprovalDecision = .pending,
        rememberScope: BridgeApprovalScope? = nil,
        expiresAt: Date? = nil,
        actionDescription: String? = nil
    ) {
        self.id = id
        self.tool = tool
        self.summary = summary
        self.target = target
        self.createdAt = createdAt
        self.decision = decision
        self.rememberScope = rememberScope
        self.expiresAt = expiresAt
        self.actionDescription = actionDescription
    }
}

/// Expiring, explicitly scoped approval. Legacy indefinite rules are never
/// accepted after upgrading to this format.
public struct BridgeRememberedApprovalRule: Codable, Sendable {
    public let scope: BridgeApprovalScope
    public let expiresAt: Date
    public let grantedAt: Date
}

public final class BridgeApprovalStore: @unchecked Sendable {
    private let directory: URL
    private let rulesDirectory: URL
    private let lock = NSLock()
    private let ttl: TimeInterval
    // Keep authorization lifetime aligned with ToolRouter's 90-second wait.
    // A late decision must never authorize a subsequent identical command.
    private let approvalTimeout: TimeInterval = 90
    public static let rememberedApprovalLifetime: TimeInterval = 24 * 60 * 60

    public init(paths: BridgePaths, ttl: TimeInterval = 10 * 60) {
        self.directory = paths.root.appendingPathComponent("approvals", isDirectory: true)
        self.rulesDirectory = paths.root.appendingPathComponent("approval-rules", isDirectory: true)
        self.ttl = ttl
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
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
        target: String? = nil,
        rememberScope: BridgeApprovalScope? = nil,
        actionDescription: String? = nil
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
                target: target,
                rememberScope: rememberScope,
                expiresAt: Date().addingTimeInterval(min(ttl, approvalTimeout)),
                actionDescription: actionDescription
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
                if let scope = request.rememberScope, hasRememberedApproval(scope) {
                    try? FileManager.default.removeItem(at: url)
                    return .granted
                }
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
        // The command is no longer waiting. Remove the prompt immediately
        // so its notification and UI cannot approve a dead command.
        withLock { try? FileManager.default.removeItem(at: requestURL(id)) }
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
                .filter { request in
                    guard let scope = request.rememberScope else { return true }
                    return !hasRememberedApproval(scope)
                }
                .sorted { $0.createdAt > $1.createdAt }
        }
    }

    @discardableResult
    public func decide(id: String, allow: Bool, remember: Bool = false) -> Bool {
        withLock {
            pruneExpiredLocked()
            let url = requestURL(id)
            guard var request = loadLocked(url), request.decision == .pending else { return false }
            if allow && remember {
                guard let scope = request.rememberScope else { return false }
                do {
                    try FileManager.default.createDirectory(at: rulesDirectory, withIntermediateDirectories: true,
                                                           attributes: [.posixPermissions: 0o700])
                    let rule = rulesDirectory.appendingPathComponent(scope.id + ".json")
                    let saved = BridgeRememberedApprovalRule(
                        scope: scope,
                        expiresAt: Date().addingTimeInterval(Self.rememberedApprovalLifetime),
                        grantedAt: Date()
                    )
                    try JSONEncoder().encode(saved).write(to: rule, options: .atomic)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: rule.path)
                } catch { return false }
            }
            request.decision = allow ? .granted : .denied
            saveLocked(request, to: url)
            return loadLocked(url)?.decision == request.decision
        }
    }

    public func hasRememberedApproval(_ scope: BridgeApprovalScope) -> Bool {
        let url = rulesDirectory.appendingPathComponent(scope.id + ".json")
        guard let data = try? Data(contentsOf: url),
              let rule = try? JSONDecoder().decode(BridgeRememberedApprovalRule.self, from: data),
              rule.expiresAt > Date() else { return false }
        return rule.scope == scope
    }

    public func rememberedApprovalRules() -> [BridgeRememberedApprovalRule] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: rulesDirectory, includingPropertiesForKeys: nil
        ) else { return [] }
        return urls.compactMap { url -> BridgeRememberedApprovalRule? in
            guard let data = try? Data(contentsOf: url),
                  let rule = try? JSONDecoder().decode(BridgeRememberedApprovalRule.self, from: data),
                  rule.expiresAt > Date() else { return nil }
            return rule
        }.sorted { $0.grantedAt > $1.grantedAt }
    }

    public func revokeRememberedApproval(_ scope: BridgeApprovalScope) throws {
        try FileManager.default.removeItem(
            at: rulesDirectory.appendingPathComponent(scope.id + ".json")
        )
    }

    public func revokeRememberedApprovals() throws {
        if FileManager.default.fileExists(atPath: rulesDirectory.path) {
            try FileManager.default.removeItem(at: rulesDirectory)
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
            if now >= request.deadline || now.timeIntervalSince(request.createdAt) >= min(ttl, approvalTimeout) {
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
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
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
