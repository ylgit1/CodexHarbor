import Darwin
import Foundation

public enum HarborProxyErrorCategory: String, Codable, Sendable {
    case portInUse = "PORT_IN_USE"
    case engineStartFailed = "ENGINE_START_FAILED"
    case listenerTimeout = "LISTENER_TIMEOUT"
    case configurationIdentityMismatch = "CONFIG_IDENTITY_MISMATCH"
    case dnsFailed = "DNS_FAILED"
    case tlsFailed = "TLS_FAILED"
    case httpsUnreachable = "HTTPS_UNREACHABLE"
    case underlayUnavailable = "UNDERLAY_UNAVAILABLE"
    case warpUnavailable = "WARP_UNAVAILABLE"
    case networkOffline = "NETWORK_OFFLINE"
    case resourceExhausted = "RESOURCE_EXHAUSTED"
    case systemProxyConflict = "SYSTEM_PROXY_CONFLICT"
    case transactionCancelled = "TRANSACTION_CANCELLED"
    case recoveryFailed = "RECOVERY_FAILED"
    case cleanupFailed = "CLEANUP_FAILED"
}

public struct HarborProxyDiagnosticEvent: Codable, Sendable {
    public let timestamp: Date
    public let event: String
    public let transactionID: UUID?
    public let generation: UInt64
    public let engineID: UUID?
    public let nodeHash: String?
    public let engineType: String?
    public let connectionState: HarborConnectionPhase
    public let networkEpoch: UInt64
    public let errorCategory: HarborProxyErrorCategory?
    public let failureStage: String?
    public let durationMilliseconds: Int?
    public let retryCount: Int
    public let fields: [String: String]

    public init(event: String, transactionID: UUID?, generation: UInt64, engineID: UUID?,
                nodeHash: String?, engineType: String?, connectionState: HarborConnectionPhase,
                networkEpoch: UInt64, errorCategory: HarborProxyErrorCategory?, failureStage: String?,
                durationMilliseconds: Int?, retryCount: Int, fields: [String: String]) {
        self.timestamp = .now
        self.event = Self.safeToken(event) ?? "unknown"
        self.transactionID = transactionID
        self.generation = generation
        self.engineID = engineID
        self.nodeHash = nodeHash.flatMap(Self.safeToken)
        self.engineType = engineType.flatMap(Self.safeToken)
        self.connectionState = connectionState
        self.networkEpoch = networkEpoch
        self.errorCategory = errorCategory
        self.failureStage = failureStage.flatMap(Self.safeToken)
        self.durationMilliseconds = durationMilliseconds
        self.retryCount = max(0, retryCount)
        self.fields = fields.reduce(into: [:]) { result, pair in
            if Self.allowedFields.contains(pair.key), let token = Self.safeToken(pair.value) {
                result[pair.key] = token
            }
        }
    }

    private static let allowedFields: Set<String> = [
        "alive", "attempt", "backend", "candidates", "cancelled", "classified",
        "code", "completed", "method", "partial", "passed", "pid", "port",
        "process", "remaining", "route", "running", "stage", "total"
    ]

    private static func safeToken(_ value: String) -> String? {
        guard !value.isEmpty, value.utf8.count <= 80,
              value.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0)
                  || (97...122).contains($0) || $0 == 45 || $0 == 95 }) else { return nil }
        return value
    }

    public static func fields(from note: String) -> [String: String] {
        var fields: [String: String] = [:]
        for part in note.split(whereSeparator: \.isWhitespace) {
            let values = part.split(separator: "=", maxSplits: 1)
            guard values.count == 2 else { continue }
            let key = String(values[0])
            if allowedFields.contains(key), let value = safeToken(String(values[1])) { fields[key] = value }
        }
        return fields
    }
}

/// Two bounded private JSONL files. No raw engine output or arbitrary error
/// text enters the diagnostic journal. Serialize appends across callers.
public final class HarborProxyDiagnostics: @unchecked Sendable {
    private let lock = NSLock()
    private let destination: URL
    private let maximumBytes: Int
    private let retention: TimeInterval

    public init(destination: URL, maximumBytes: Int = 256 * 1024, retention: TimeInterval = 7 * 24 * 3600) {
        self.destination = destination
        self.maximumBytes = max(4096, maximumBytes)
        self.retention = retention
    }

    public func append(_ event: HarborProxyDiagnosticEvent) {
        lock.withLock {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            guard var data = try? encoder.encode(event), data.count < maximumBytes else { return }
            data.append(10)
            let rotated = destination.appendingPathExtension("1")
            if let attributes = try? FileManager.default.attributesOfItem(atPath: rotated.path),
               let date = attributes[.modificationDate] as? Date,
               Date.now.timeIntervalSince(date) > retention {
                try? FileManager.default.removeItem(at: rotated)
            }
            func openFile() -> Int32 {
                Darwin.open(destination.path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
            }
            var fd = openFile()
            guard fd >= 0 else { return }
            var info = stat()
            guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid(),
                  info.st_nlink == 1 else { Darwin.close(fd); return }
            if info.st_size + Int64(data.count) > Int64(maximumBytes) {
                Darwin.close(fd)
                guard Darwin.rename(destination.path, rotated.path) == 0 else { return }
                fd = openFile()
                guard fd >= 0 else { return }
            }
            defer { Darwin.close(fd) }
            guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
                  info.st_uid == getuid(), info.st_nlink == 1,
                  fchmod(fd, 0o600) == 0 else { return }
            data.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return }
                var offset = 0
                while offset < bytes.count {
                    let count = Darwin.write(fd, base.advanced(by: offset), bytes.count - offset)
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { break }
                    offset += count
                }
            }
        }
    }
}
