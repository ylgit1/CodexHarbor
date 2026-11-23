import Darwin
import Foundation

/// Canonical IP literals for node-server GeoIP and native TCP probing.
/// Compare decoded addresses rather than IPv6's many equivalent spellings.
public enum HarborIPAddress {
    public static func normalizedLiteral(_ host: String) -> String? {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let literal = trimmed.hasPrefix("[") && trimmed.hasSuffix("]")
            ? String(trimmed.dropFirst().dropLast()) : trimmed
        var ipv4 = in_addr()
        if literal.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 {
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            return inet_ntop(AF_INET, &ipv4, &buffer, socklen_t(buffer.count))
                .map { _ in String(decoding: buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self) }
        }
        var ipv6 = in6_addr()
        if literal.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1 {
            var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            return inet_ntop(AF_INET6, &ipv6, &buffer, socklen_t(buffer.count))
                .map { _ in String(decoding: buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self) }
        }
        return nil
    }

    public static func equivalent(_ lhs: String, _ rhs: String) -> Bool {
        guard let first = normalizedLiteral(lhs),
              let second = normalizedLiteral(rhs) else { return false }
        return first == second
    }

    public static func isLocal(_ host: String) -> Bool {
        guard let ip = normalizedLiteral(host) else { return false }
        if ip.hasPrefix("::ffff:") { return isLocal(String(ip.dropFirst(7))) }
        if ip.contains(":") {
            return ip == "::1" || ip == "::" || ip.hasPrefix("fc") || ip.hasPrefix("fd")
                || ["fe8", "fe9", "fea", "feb"].contains { ip.hasPrefix($0) }
        }
        let parts = ip.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        return [0, 10, 127].contains(parts[0])
            || (parts[0] == 169 && parts[1] == 254)
            || (parts[0] == 172 && (16...31).contains(parts[1]))
            || (parts[0] == 192 && parts[1] == 168)
            || (parts[0] == 100 && (64...127).contains(parts[1]))
    }

    /// Strip URL-style brackets only for valid IP literals; preserve DNS names.
    public static func socketHost(_ host: String) -> String {
        normalizedLiteral(host) ?? host.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
