import CryptoKit
import Foundation

public enum DeviceIdentity {
    public static func hash(using store: SecretStore) throws -> String {
        let identifier: String
        if let existing = try store.string(for: .deviceIdentifier), !existing.isEmpty {
            identifier = existing
        } else {
            identifier = UUID().uuidString.lowercased()
            try store.set(identifier, for: .deviceIdentifier)
        }
        return SHA256.hash(data: Data(identifier.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
