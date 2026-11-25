import Foundation
import Security
import CryptoKit

/// Both endpoints must be signed by the same persistent signing identity.
/// An ad-hoc signed or unsigned executable is deliberately not trusted.
public enum HarborAgentSigningRequirement {
    public static func forPeer(identifier: String) throws -> String {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { throw Failure.untrusted }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else {
            throw Failure.untrusted
        }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let values = information as? [String: Any],
              let certificates = values[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let leaf = certificates.first else { throw Failure.untrusted }
        let hash = Insecure.SHA1.hash(data: SecCertificateCopyData(leaf) as Data)
            .map { String(format: "%02x", $0) }.joined()
        return "identifier \"\(identifier)\" and certificate leaf = H\"\(hash)\""
    }

    /// Verify the bundled peer before registering its launchd job. A valid
    /// signature alone does not establish the required identifier or signer.
    public static func verifyPeer(at url: URL, identifier: String) throws {
        var requirement: SecRequirement?
        let expression = try forPeer(identifier: identifier)
        guard SecRequirementCreateWithString(expression as CFString, [], &requirement) == errSecSuccess,
              let requirement else { throw Failure.untrusted }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
              let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate),
                                         requirement) == errSecSuccess else { throw Failure.untrusted }
    }

    public static func authenticate(_ connection: NSXPCConnection, identifier: String) throws {
        connection.setCodeSigningRequirement(try forPeer(identifier: identifier))
    }

    enum Failure: Error { case untrusted }
}
