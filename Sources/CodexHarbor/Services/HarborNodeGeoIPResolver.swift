import CodexHarborCore
import Foundation
import Darwin

/// Event-driven GeoIP lookup for the NODE SERVER, not the proxy's exit IP.
/// DNS is resolved off the main actor; the HTTPS country lookup is made only
/// for previously unseen IPs. No timer, per-row lookup or Xray process.
enum HarborNodeGeoIPResolver {
    private static let dnsQueue = DispatchQueue(label: "com.codexharbor.proxy.dns", qos: .utility)
    private static let dnsSlot = DispatchSemaphore(value: 1)

    private final class DNSQuery: @unchecked Sendable {
        private let lock = NSLock()
        private var completed = false
        private var result: String?
        private var continuation: CheckedContinuation<String?, Never>?

        func attach(_ continuation: CheckedContinuation<String?, Never>) {
            lock.lock()
            if completed {
                let result = result
                lock.unlock()
                continuation.resume(returning: result)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }

        func finish(_ value: String?) {
            lock.lock()
            guard !completed else { lock.unlock(); return }
            completed = true
            result = value
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(returning: value)
        }
    }
    private struct Response: Decodable {
        let success: Bool
        let ip: String?
        let country_code: String?
    }

    static func resolvedIP(for host: String) async -> String? {
        let name = HarborIPAddress.socketHost(host)
        guard !Task.isCancelled, !name.isEmpty, name.utf8.count < 254 else { return nil }
        if let literal = HarborIPAddress.normalizedLiteral(name) { return isPublic(literal) ? literal : nil }

        // getaddrinfo may outlive the request on some networks. Release the
        // waiter promptly and allow only one OS lookup until it returns.
        guard claimDNSSlot() else { return nil }
        let query = DNSQuery()
        dnsQueue.async {
            let result = resolveBlocking(name)
            dnsSlot.signal()
            query.finish(result)
        }
        let timer = Task {
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            query.finish(nil)
        }
        defer { timer.cancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { query.attach($0) }
        } onCancel: { query.finish(nil) }
    }

    private static func claimDNSSlot() -> Bool { dnsSlot.wait(timeout: .now()) == .success }

    private static func resolveBlocking(_ name: String) -> String? {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(name, nil, &hints, &list) == 0, let head = list else {
            return nil
        }
        defer { freeaddrinfo(head) }
        var cursor: UnsafeMutablePointer<addrinfo>? = head
        var ipv6: String?
        while let current = cursor {
            let item = current.pointee
            if item.ai_family == AF_INET, let addr = item.ai_addr {
                var raw = UnsafeRawPointer(addr).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
                var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                if inet_ntop(AF_INET, &raw, &buffer, socklen_t(buffer.count)) != nil {
                    let ip = String(decoding: buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
                    if isPublic(ip) { return ip }
                }
            } else if item.ai_family == AF_INET6, let addr = item.ai_addr {
                var raw = UnsafeRawPointer(addr).assumingMemoryBound(to: sockaddr_in6.self).pointee.sin6_addr
                var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                if inet_ntop(AF_INET6, &raw, &buffer, socklen_t(buffer.count)) != nil {
                    let ip = String(decoding: buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
                    if isPublic(ip) { ipv6 = ip }
                }
            }
            cursor = item.ai_next
        }
        return ipv6
    }

    static func countryCode(for ip: String, proxyPort: Int? = nil,
                            cancellation: HarborLatencyCancellation? = nil) async -> String? {
        guard !Task.isCancelled, cancellation?.isCancelled != true else { return nil }
        // Only the public IP is sent to the geolocation provider; node labels,
        // subscriptions, credentials and DNS host names are never transmitted.
        guard let canonicalIP = HarborIPAddress.normalizedLiteral(ip),
              isPublic(canonicalIP),
              let encoded = canonicalIP.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://ipwho.is/\(encoded)?fields=success,ip,country_code") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        guard let lease = await HarborProbeBudget.requests.acquire(cancellation) else { return nil }
        let load = Task { [request] in
            try await HarborProxyHTTPBody.data(for: request,
                configuration: HarborProxyHTTP.configuration(httpPort: proxyPort),
                limit: 16_384, timeout: 6, status: 200..<201)
        }
        let observer = cancellation?.observe { load.cancel() }
        let downloaded = await withTaskCancellationHandler {
            try? await load.value
        } onCancel: { load.cancel() }
        if let observer { cancellation?.removeObserver(observer) }
        await HarborProbeBudget.requests.release(lease)
        guard let (data, _) = downloaded,
              let result = try? JSONDecoder().decode(Response.self, from: data),
              result.success,
              let returnedIP = result.ip,
              HarborIPAddress.equivalent(returnedIP, canonicalIP),
              let code = result.country_code?.uppercased(),
              code.count == 2, code.utf8.allSatisfy({ (65...90).contains($0) }) else {
            return nil
        }
        return code
    }

    /// Ask a non-Cloudflare site for the IP it sees through this node. Looking
    /// up that explicit IP separately avoids mistaking a CF-only ProxyIP for
    /// the exit used by ordinary websites.
    static func exitLocation(socksPort: Int,
                             cancellation: HarborLatencyCancellation? = nil)
        async -> HarborProxyIPLocation? {
        guard (1...65_535).contains(socksPort), !Task.isCancelled,
              cancellation?.isCancelled != true,
              let url = URL(string: "https://checkip.amazonaws.com/") else {
            return nil
        }
        // Force SOCKS5 + remote DNS; URLSession on some macOS builds can
        // silently bypass its SOCKS proxy dictionary and report the host IP.
        // A failed proxy must return nil, never the machine's direct address.
        // VPN Gate relays may block one IP-echo provider while allowing
        // another. Never substitute the host machine's IP: both requests must
        // still go through this exact isolated SOCKS outbound.
        var observedData = await exitDataViaCurl(
            socksPort: socksPort, url: url, cancellation: cancellation)
        if observedData == nil, !Task.isCancelled, cancellation?.isCancelled != true,
           let fallbackURL = URL(string: "https://api.ipify.org/") {
            observedData = await exitDataViaCurl(
                socksPort: socksPort, url: fallbackURL, cancellation: cancellation)
        }
        guard let data = observedData, data.count < 128,
              !Task.isCancelled, cancellation?.isCancelled != true,
              let observedIP = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              let canonical = HarborIPAddress.normalizedLiteral(observedIP),
              isPublic(canonical) else { return nil }

        // Geolocate the explicit observed IP independently. Requiring the
        // second GeoIP website to also be reachable through a fragile VPN
        // unnecessarily turns a valid observed exit into "待识别".
        let country = await countryCode(for: canonical, cancellation: cancellation)
        let code: String?
        if let country {
            code = country
        } else if !Task.isCancelled, cancellation?.isCancelled != true {
            code = await exitCountryCode(
                for: canonical, socksPort: socksPort, cancellation: cancellation)
        } else {
            code = nil
        }
        guard !Task.isCancelled, cancellation?.isCancelled != true,
              !Task.isCancelled else { return nil }
        return HarborProxyIPLocation(ip: canonical, countryCode: code ?? "ZZ")
    }

    private static func exitCountryCode(for ip: String, socksPort: Int,
                                        cancellation: HarborLatencyCancellation?) async -> String? {
        guard let encoded = ip.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://ipwho.is/\(encoded)?fields=success,ip,country_code"),
              let data = await exitDataViaCurl(
                  socksPort: socksPort, url: url, cancellation: cancellation),
              !Task.isCancelled, cancellation?.isCancelled != true,
              let result = try? JSONDecoder().decode(Response.self, from: data),
              result.success,
              let returnedIP = result.ip, HarborIPAddress.equivalent(returnedIP, ip),
              let code = result.country_code?.uppercased(), code != "ZZ",
              code.count == 2, code.utf8.allSatisfy({ (65...90).contains($0) }) else {
            return nil
        }
        return code
    }

    private static func exitDataViaCurl(socksPort: Int, url: URL,
                                        cancellation: HarborLatencyCancellation?) async -> Data? {
        guard !Task.isCancelled, cancellation?.isCancelled != true,
              let lease = await HarborProbeBudget.requests.acquire(cancellation) else { return nil }
        let output = try? await HarborProxyCommand.run(
            URL(fileURLWithPath: "/usr/bin/curl"), arguments: [
                "--disable", "--silent", "--fail", "--max-time", "7", "--max-filesize", "4096",
                "--proxy", "socks5h://127.0.0.1:\(socksPort)", "--noproxy", "", "--url", url.absoluteString
            ], timeout: 8, outputLimit: 4_096, cancelled: { cancellation?.isCancelled == true })
        await HarborProbeBudget.requests.release(lease)
        guard !Task.isCancelled, cancellation?.isCancelled != true, let output, output.status == 0 else { return nil }
        return output.data
    }

    static func isPublic(_ ip: String) -> Bool {
        guard let normalized = HarborIPAddress.normalizedLiteral(ip) else { return false }
        var v4 = in_addr()
        if inet_pton(AF_INET, normalized, &v4) == 1 {
            let bits = UInt32(bigEndian: v4.s_addr)
            let a = (bits >> 24) & 0xff
            let b = (bits >> 16) & 0xff
            return a != 0 && a != 10 && a != 127 && a < 224
                && !(a == 100 && (64...127).contains(b))
                && !(a == 169 && b == 254)
                && !(a == 172 && (16...31).contains(b))
                && !(a == 192 && (b == 168 || b == 0))
                && !(a == 198 && (b == 18 || b == 19))
            }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, normalized, &v6) == 1 {
            let bytes = withUnsafeBytes(of: &v6) { Array($0) }
            // Unspecified, loopback, unique-local, multicast and link-local.
            return !(bytes.prefix(15).allSatisfy { $0 == 0 })
                && (bytes[0] & 0xfe) != 0xfc
                && bytes[0] != 0xff
                && !(bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80)
                && !(bytes[0] == 0x20 && bytes[1] == 0x01 && bytes[2] == 0x0d && bytes[3] == 0xb8)
        }
        return false
    }
}
