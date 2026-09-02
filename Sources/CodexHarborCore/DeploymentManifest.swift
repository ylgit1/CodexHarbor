import Foundation

struct DeploymentManifest: Codable, Sendable {
    enum State: String, Codable, Sendable {
        case preparing
        case installed
    }

    var identifier: UUID
    var state: State
    var activeMode: CodexMode
    var createdAt: Date
    var configPath: String
    var backupPath: String?
    var originalExisted: Bool
    var originalPermissions: Int
    var originalSHA256: String?
    var installedConfigExists: Bool
    var installedSHA256: String
    /// Fingerprint of the effective TOML content at the last successful
    /// deployment/reconciliation. Raw SHA-256 is retained for transaction
    /// integrity, while this value ignores formatting-only rewrites.
    var installedSemanticFingerprint: String?
    var apiBaseURL: URL
    var model: String
    var helperExecutablePath: String
    var modelCatalogURL: URL?
}
