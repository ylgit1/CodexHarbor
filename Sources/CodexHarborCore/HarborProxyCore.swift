import Foundation
import SQLite3

/// Compares the *loaded Xray outbound*, including transport settings and
/// credentials, with a subscription profile. The comparison is entirely local:
/// no node addresses or secrets are written to diagnostics.
public enum HarborProxyRuntimeIdentity {
    public static func matches(configuration: Data, node: HarborProxyNode) -> Bool {
        guard let document = try? JSONSerialization.jsonObject(with: configuration) as? [String: Any],
              let outbounds = document["outbounds"] as? [[String: Any]],
              let running = outbounds.first(where: { $0["tag"] as? String == "proxy" }),
              let expectedData = try? HarborXrayConfig.make(
                node: node, httpPort: HarborProxyPortPolicy.defaultHTTPPort, ruleMode: false
              ),
              let expected = try? JSONSerialization.jsonObject(with: expectedData) as? [String: Any],
              let expectedOutbound = (expected["outbounds"] as? [[String: Any]])?.first else {
            return false
        }
        return NSDictionary(dictionary: running).isEqual(to: expectedOutbound)
    }
}

/// Stable listener ports. Never auto-increment to another pair when occupied.
public enum HarborProxyPortPolicy {
    public static let defaultHTTPPort = 18080
    public static let defaultSOCKSPort = 18081

    @discardableResult
    public static func validate(httpPort: Int) throws -> Int {
        guard (1024...65534).contains(httpPort) else {
            throw HarborProxyError.invalid("HTTP 代理端口必须在 1024～65534 之间（SOCKS5 使用下一端口）")
        }
        return httpPort
    }

    public static func socksPort(for httpPort: Int) -> Int { httpPort + 1 }
}

/// Local readiness is independent of external HTTPS probe success; network
/// verification is performed asynchronously after the listeners are ready.
public enum HarborProxyStartupPolicy {
    public static func canPublishListenerReady(xrayRunning: Bool, portsListening: Bool) -> Bool {
        xrayRunning && portsListening
    }
}

/// An explicit node click always means "use this proxy". A prior clear action
/// may pause automatic takeover, but it must not permanently turn later node
/// selections into local-listener-only starts.
public enum HarborProxyConnectionIntent {
    public static func shouldManageSystemProxy(
        persistedPreference: Bool,
        userInitiated: Bool
    ) -> Bool {
        persistedPreference || userInitiated
    }
}

/// Latest-intent-wins node activation, independent of Xray startup/teardown.
public struct HarborProxyActivationQueue: Sendable {
    public struct Request: Sendable, Equatable {
        public let nodeID: String
        public let restart: Bool
        public let userInitiated: Bool
    }

    private var pending: Request?

    public init() {}

    public mutating func enqueue(_ nodeID: String, restart: Bool, userInitiated: Bool) {
        pending = Request(nodeID: nodeID, restart: restart, userInitiated: userInitiated)
    }

    public mutating func takeNext() -> Request? {
        defer { pending = nil }
        return pending
    }
}

public struct HarborProxyNode: Codable, Identifiable, Sendable, Hashable {
    public var id: String
    public var name: String
    public var customName: String?
    public var automaticName: String?
    public var protocolName: String
    public var host: String
    public var port: Int
    public var credential: String
    public var encryption: String
    public var network: String
    public var security: String
    public var sni: String
    public var headerHost: String
    public var path: String
    public var fingerprint: String
    public var publicKey: String
    public var shortID: String
    public var flow: String
    public var alterID: Int
    public var subscriptionID: String
    public init(id: String = UUID().uuidString, name: String, customName: String? = nil,
                automaticName: String? = nil,
                protocolName: String, host: String,
                port: Int, credential: String, encryption: String = "none", network: String = "tcp",
                security: String = "none", sni: String = "", headerHost: String = "", path: String = "",
                fingerprint: String = "", publicKey: String = "", shortID: String = "",
                flow: String = "", alterID: Int = 0, subscriptionID: String = "") {
        self.id = id; self.name = name; self.customName = customName
        self.automaticName = automaticName
        self.protocolName = protocolName; self.host = host
        self.port = port; self.credential = credential; self.encryption = encryption
        self.network = network; self.security = security; self.sni = sni
        self.headerHost = headerHost; self.path = path; self.fingerprint = fingerprint
        self.publicKey = publicKey; self.shortID = shortID; self.flow = flow
        self.alterID = alterID; self.subscriptionID = subscriptionID
    }
    public var label: String { "\(protocolName.uppercased()) · \(host):\(port)" }
    public var displayName: String { customName ?? automaticName ?? name }
}

/// User-assigned node names stay separate from provider remarks, so a
/// subscription refresh can update connection data without erasing the alias.
public enum HarborProxyNodeNaming {
    public static let maximumLength = 80

    private struct Endpoint: Hashable {
        var protocolName: String
        var host: String
        var port: Int
        var credential: String
        var encryption: String
        var network: String
        var security: String
        var sni: String
        var headerHost: String
        var path: String
        var fingerprint: String
        var publicKey: String
        var shortID: String
        var flow: String
        var alterID: Int

        init(_ node: HarborProxyNode) {
            protocolName = node.protocolName; host = node.host; port = node.port
            credential = node.credential; encryption = node.encryption
            network = node.network; security = node.security; sni = node.sni
            headerHost = node.headerHost; path = node.path
            fingerprint = node.fingerprint; publicKey = node.publicKey
            shortID = node.shortID; flow = node.flow; alterID = node.alterID
        }
    }

    public static func customName(_ rawValue: String, sourceName: String) throws -> String? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw HarborProxyError.invalid("节点名称不能为空") }
        guard value.count <= maximumLength else {
            throw HarborProxyError.invalid("节点名称最多 \(maximumLength) 个字符")
        }
        return value == sourceName ? nil : value
    }

    public static func preservingCustomNames(
        from current: [HarborProxyNode],
        in replacements: [HarborProxyNode]
    ) -> [HarborProxyNode] {
        let aliases = current.reduce(into: [Endpoint: String]()) { result, node in
            if let customName = node.customName { result[Endpoint(node)] = customName }
        }
        return replacements.map { replacement in
            var node = replacement
            node.customName = aliases[Endpoint(replacement)]
            return node
        }
    }
}

public struct HarborProxySubscription: Codable, Identifiable, Sendable, Hashable {
    public var id: String
    public var name: String
    public var url: String
    public init(id: String = UUID().uuidString, name: String, url: String) {
        self.id = id; self.name = name; self.url = url
    }

    /// Editing changes only metadata. The stable subscription ID is used by
    /// imported nodes, custom names, favorites, and the active connection.
    public func updated(name rawName: String, url rawURL: String) throws -> Self {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80 else {
            throw HarborProxyError.invalid("订阅名称不能为空，且不能超过 80 个字符")
        }
        let url = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: url),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              !url.contains(where: \.isWhitespace) else {
            throw HarborProxyError.invalid("请输入有效的 HTTPS 订阅地址")
        }
        var result = self
        result.name = name
        result.url = url
        return result
    }
}

/// Replace one subscription's profiles without changing unrelated groups or
/// breaking identifiers for unchanged endpoints (favorites and aliases).
/// An in-use endpoint removed by the provider is retained as an ungrouped
/// selected node until the user explicitly switches away from it.
public enum HarborProxySubscriptionReconciler {
    public struct Result: Sendable {
        public let nodes: [HarborProxyNode]
        public let selectedID: String?
        public let retainedActiveNode: Bool
    }

    private static func endpoint(_ node: HarborProxyNode) -> HarborProxyNode {
        var value = node
        value.id = ""
        value.name = ""
        value.customName = nil
        value.automaticName = nil
        value.subscriptionID = ""
        return value
    }

    public static func replace(
        current: [HarborProxyNode],
        incoming: [HarborProxyNode],
        subscriptionID: String,
        selectedID: String?,
        keepActiveConnection: Bool
    ) -> Result {
        let previous = current.filter { $0.subscriptionID == subscriptionID }
        var previousByEndpoint: [HarborProxyNode: [HarborProxyNode]] = [:]
        for node in previous {
            previousByEndpoint[endpoint(node), default: []].append(node)
        }

        var refreshed: [HarborProxyNode] = []
        for supplied in incoming {
            var node = supplied
            node.subscriptionID = subscriptionID
            let key = endpoint(node)
            if var matches = previousByEndpoint[key], !matches.isEmpty {
                let previous = matches.removeFirst()
                previousByEndpoint[key] = matches
                node.id = previous.id
                node.customName = previous.customName
                node.automaticName = previous.automaticName
            }
            refreshed.append(node)
        }

        // A provider may reorder every item on each refresh. Keep the first
        // measured order for profiles whose complete connection identity did
        // not change, then append genuinely new profiles in provider order.
        let refreshedByID = Dictionary(uniqueKeysWithValues: refreshed.map { ($0.id, $0) })
        let stableIDs = previous.compactMap { refreshedByID[$0.id]?.id }
        let stableIDSet = Set(stableIDs)
        refreshed = stableIDs.compactMap { refreshedByID[$0] }
            + refreshed.filter { !stableIDSet.contains($0.id) }

        var other = current.filter { $0.subscriptionID != subscriptionID }
        var chosen = selectedID
        var retainedActive = false
        if let selectedID,
           let obsolete = previous.first(where: { $0.id == selectedID }),
           !refreshed.contains(where: { $0.id == selectedID }) {
            if keepActiveConnection {
                var active = obsolete
                active.subscriptionID = ""
                other.append(active)
                retainedActive = true
            } else {
                chosen = refreshed.first?.id ?? other.first?.id
            }
        }
        return Result(nodes: other + refreshed, selectedID: chosen,
                      retainedActiveNode: retainedActive)
    }
}

public struct HarborV2rayNImport: Sendable {
    public var nodes: [HarborProxyNode]
    public var subscriptions: [HarborProxySubscription]
    public var selectedID: String?
    public var unsupportedCount: Int
}

public enum HarborProxyError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? {
        if case let .invalid(message) = self { return message }
        return "无效代理配置"
    }
}

public enum HarborProxyLinks {
    public static func parse(_ text: String) -> [HarborProxyNode] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = (!trimmed.contains("://") ? base64(trimmed).flatMap { String(data: $0, encoding: .utf8) } : nil) ?? trimmed
        return body.components(separatedBy: .newlines).compactMap { raw in
            let input = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if input.hasPrefix("ss://") {
                // SIP002: base64(method:password)@host:port or base64(all).
                let details = String(input.dropFirst(5))
                let hash = details.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
                let name = hash.count > 1 ? String(hash[1]).removingPercentEncoding ?? "" : ""
                let authority = String(hash[0].split(separator: "?", maxSplits: 1)[0])
                let expanded: String
                if let separator = authority.firstIndex(of: "@") {
                    let auth = String(authority[..<separator])
                    let identity = auth.contains(":") ? auth
                        : (base64(auth).flatMap { String(data: $0, encoding: .utf8) } ?? auth)
                    expanded = identity + String(authority[separator...])
                } else {
                    expanded = base64(authority).flatMap { String(data: $0, encoding: .utf8) } ?? authority
                }
                guard let separator = expanded.lastIndex(of: "@") else { return nil }
                let secretPart = String(expanded[..<separator])
                let endpoint = String(expanded[expanded.index(after: separator)...])
                guard let colon = secretPart.firstIndex(of: ":"),
                      let destination = URLComponents(string: "ss://" + endpoint),
                      let host = destination.host, let port = destination.port else { return nil }
                let method = String(secretPart[..<colon])
                let password = String(secretPart[secretPart.index(after: colon)...])
                guard !method.isEmpty, !password.isEmpty else { return nil }
                return HarborProxyNode(name: name.isEmpty ? host : name,
                    protocolName: "shadowsocks", host: host, port: port,
                    credential: password, encryption: method)
            }
            if input.hasPrefix("vmess://"), let data = base64(String(input.dropFirst(8))),
               let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let host = o["add"] as? String, let credential = o["id"] as? String,
               let port = Int(String(describing: o["port"] ?? "")) {
                return HarborProxyNode(name: o["ps"] as? String ?? host, protocolName: "vmess",
                    host: host, port: port, credential: credential,
                    encryption: o["scy"] as? String ?? "auto", network: o["net"] as? String ?? "tcp",
                    security: (o["tls"] as? String == "tls") ? "tls" : "none",
                    sni: o["sni"] as? String ?? "", headerHost: o["host"] as? String ?? "",
                    path: o["path"] as? String ?? "", alterID: Int(String(describing: o["aid"] ?? 0)) ?? 0)
            }
            guard let url = URLComponents(string: input),
                  let proto = url.scheme?.lowercased(), ["vless", "trojan"].contains(proto),
                  let host = url.host, let port = url.port,
                  let auth = url.user?.removingPercentEncoding, !auth.isEmpty else { return nil }
            let query = Dictionary(url.queryItems?.map { ($0.name, $0.value ?? "") } ?? [],
                                   uniquingKeysWith: { _, new in new })
            return HarborProxyNode(name: url.fragment?.removingPercentEncoding ?? host,
                protocolName: proto, host: host, port: port, credential: auth,
                encryption: query["encryption"] ?? "none", network: query["type"] ?? "tcp",
                security: query["security"] ?? (proto == "trojan" ? "tls" : "none"),
                sni: query["sni"] ?? "", headerHost: query["host"] ?? "",
                path: query["path"] ?? query["serviceName"] ?? "", fingerprint: query["fp"] ?? "",
                publicKey: query["pbk"] ?? "", shortID: query["sid"] ?? "", flow: query["flow"] ?? "")
        }
    }

    private static func base64(_ value: String) -> Data? {
        let adjusted = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        return Data(base64Encoded: adjusted + String(repeating: "=", count: (4 - adjusted.count % 4) % 4))
    }
}

/// Uses SQLite READONLY: v2rayN's files, process and system network settings are never modified.
public enum HarborV2rayNReader {
    public static func read(at root: URL) throws -> HarborV2rayNImport {
        let configuration = root.appendingPathComponent("guiConfigs/guiNConfig.json")
        let database = root.appendingPathComponent("guiConfigs/guiNDB.db")
        let json = try Data(contentsOf: configuration)
        let preferences = try JSONSerialization.jsonObject(with: json) as? [String: Any] ?? [:]
        var db: OpaquePointer?
        guard sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let db else { throw HarborProxyError.invalid("无法以只读方式打开 v2rayN 数据库") }
        defer { sqlite3_close(db) }
        func rows(_ query: String, columns: [String]) throws -> [[String: String]] {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
                throw HarborProxyError.invalid("v2rayN 数据库结构不兼容")
            }
            defer { sqlite3_finalize(statement) }
            var result: [[String: String]] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                var entry: [String: String] = [:]
                for (i, field) in columns.enumerated() {
                    if let pointer = sqlite3_column_text(statement, Int32(i)) {
                        entry[field] = String(cString: pointer)
                    } else if sqlite3_column_type(statement, Int32(i)) == SQLITE_INTEGER {
                        entry[field] = String(sqlite3_column_int(statement, Int32(i)))
                    }
                }
                result.append(entry)
            }
            return result
        }
        let fields = ["IndexId","ConfigType","Address","Port","Id","AlterId","Security","Network",
                      "Remarks","RequestHost","Path","StreamSecurity","Subid","Flow","Sni",
                      "Fingerprint","PublicKey","ShortId"]
        let originals = try rows("SELECT \(fields.joined(separator: ",")) FROM ProfileItem", columns: fields)
        var unsupported = 0
        let nodes = originals.compactMap { item -> HarborProxyNode? in
            // v2rayN's ConfigType 5 is VLESS. Explicitly skip unknown formats.
            guard item["ConfigType"] == "5", let host = item["Address"], !host.isEmpty,
                  let credential = item["Id"], !credential.isEmpty,
                  let port = Int(item["Port"] ?? ""), (1...65535).contains(port) else {
                unsupported += 1
                return nil
            }
            return HarborProxyNode(
                id: item["IndexId"] ?? UUID().uuidString,
                name: item["Remarks"] ?? host, protocolName: "vless", host: host, port: port,
                credential: credential, encryption: item["Security"] ?? "none",
                network: item["Network"] ?? "tcp", security: item["StreamSecurity"] ?? "none",
                sni: item["Sni"] ?? "", headerHost: item["RequestHost"] ?? "",
                path: item["Path"] ?? "", fingerprint: item["Fingerprint"] ?? "",
                publicKey: item["PublicKey"] ?? "", shortID: item["ShortId"] ?? "",
                flow: item["Flow"] ?? "", alterID: Int(item["AlterId"] ?? "") ?? 0,
                subscriptionID: item["Subid"] ?? "")
        }
        let subscriptionFields = ["Id","Remarks","Url"]
        let subscriptions = try rows("SELECT Id, Remarks, Url FROM SubItem", columns: subscriptionFields)
            .compactMap { item -> HarborProxySubscription? in
                guard let url = item["Url"], url.hasPrefix("https://") else { return nil }
                return HarborProxySubscription(id: item["Id"] ?? UUID().uuidString,
                    name: item["Remarks"] ?? "订阅", url: url)
            }
        return HarborV2rayNImport(nodes: nodes, subscriptions: subscriptions,
            selectedID: preferences["IndexId"] as? String, unsupportedCount: unsupported)
    }
}

/// Domains routed through the selected proxy before any GeoIP/GeoSite direct rules.
/// A domain entry covers the apex hostname and all its subdomains.
public enum HarborProxyDomainRules {
    public static let defaults = ["gitee.com", "gitee.io"]

    public static func normalized(_ domains: [String]) throws -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in domains {
            var domain = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if domain.hasPrefix("*.") { domain.removeFirst(2) }
            guard !domain.isEmpty, domain.utf8.count <= 253 else {
                throw HarborProxyError.invalid("强制代理域名不能为空，且不得超过 253 字节")
            }
            let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
            guard labels.count >= 2, labels.allSatisfy({ label in
                !label.isEmpty && label.utf8.count <= 63
                    && label.first != "-" && label.last != "-"
                    && label.utf8.allSatisfy { byte in
                        (97...122).contains(byte) || (48...57).contains(byte) || byte == 45
                    }
            }) else {
                throw HarborProxyError.invalid("无效域名：\(value)。每行填写域名，例如 gitee.com")
            }
            if seen.insert(domain).inserted { result.append(domain) }
        }
        return result
    }
}

/// Keep an intentional stop/switch distinct from an unexpected Xray exit.
public enum HarborProxyLivenessPolicy {
    public static func shouldHandleUnexpectedExit(
        running: Bool, intentionallyStopping: Bool,
        processMatches: Bool, coreAlive: Bool
    ) -> Bool {
        running && !intentionallyStopping && processMatches && !coreAlive
    }
}

public enum HarborXrayConfig {
    /// Endpoints used solely to verify the actual remote proxy route.
    /// Keep them ahead of regional direct rules; otherwise a 200 response can
    /// be mistaken for proof that the remote Xray outbound works.
    // Exactly the selected v2rayN SpeedPingTestUrl target on this Mac.
    // The active connection must never bypass its proxy via regional rules.
    public static let verificationHosts = ["full:www.msftconnecttest.com"]

    /// v2rayN's real-ping batch uses one mixed SOCKS/HTTP inbound per node,
    /// routes each inbound to its matching outbound, and starts one Xray.
    public static func makeRealPingBatch(nodes: [HarborProxyNode], basePort: Int) throws -> Data {
        guard !nodes.isEmpty, nodes.count <= 1_000,
              (1024...65_535).contains(basePort),
              basePort + nodes.count - 1 <= 65_534 else {
            throw HarborProxyError.invalid("测速节点或端口无效")
        }
        var inbounds: [[String: Any]] = []
        var outbounds: [[String: Any]] = []
        var rules: [[String: Any]] = []
        for (index, node) in nodes.enumerated() {
            let port = basePort + index
            let single = try make(node: node, httpPort: port,
                                  ruleMode: false, forcedProxyDomains: [],
                                  routeAllViaProxy: true)
            guard let json = try JSONSerialization.jsonObject(with: single) as? [String: Any],
                  let configured = json["outbounds"] as? [[String: Any]],
                  var outbound = configured.first else {
                throw HarborProxyError.invalid("测速节点配置无效")
            }
            let inboundTag = "mixed\(port)"
            let outboundTag = "proxy\(port)"
            outbound["tag"] = outboundTag
            inbounds.append(["listen": "127.0.0.1", "port": port,
                             "protocol": "mixed", "tag": inboundTag])
            outbounds.append(outbound)
            rules.append(["type": "field", "inboundTag": [inboundTag],
                          "outboundTag": outboundTag])
        }
        let configuration: [String: Any] = [
            "log": ["loglevel": "warning"],
            "inbounds": inbounds,
            "outbounds": outbounds,
            "routing": ["domainStrategy": "IPIfNonMatch", "rules": rules]
        ]
        return try JSONSerialization.data(withJSONObject: configuration, options: [.sortedKeys])
    }

    public static func make(node: HarborProxyNode, httpPort: Int, ruleMode: Bool,
                            forcedProxyDomains: [String] = HarborProxyDomainRules.defaults,
                            routeVerificationViaProxy: Bool = false,
                            routeAllViaProxy: Bool = false,
                            verificationHost: String? = nil) throws -> Data {
        guard (1024...65534).contains(httpPort), (1...65535).contains(node.port),
              !node.host.isEmpty, !node.credential.isEmpty else {
            throw HarborProxyError.invalid("代理节点无效")
        }
        var stream: [String: Any] = ["network": node.network.isEmpty ? "tcp" : node.network]
        if node.security == "tls" || node.security == "reality" {
            var tls: [String: Any] = ["serverName": node.sni.isEmpty ? node.host : node.sni]
            if !node.fingerprint.isEmpty { tls["fingerprint"] = node.fingerprint }
            if node.security == "reality" {
                guard !node.publicKey.isEmpty else { throw HarborProxyError.invalid("Reality 缺少公钥") }
                tls["publicKey"] = node.publicKey; tls["shortId"] = node.shortID
                stream["realitySettings"] = tls
            } else { stream["tlsSettings"] = tls }
            stream["security"] = node.security
        }
        switch node.network {
        case "tcp", "": stream["network"] = "tcp"
        case "ws":
            var settings: [String: Any] = ["path": node.path.isEmpty ? "/" : node.path]
            if !node.headerHost.isEmpty { settings["host"] = node.headerHost }
            stream["wsSettings"] = settings
        case "grpc": stream["grpcSettings"] = ["serviceName": node.path]
        default: throw HarborProxyError.invalid("暂不支持 \(node.network) 传输")
        }
        var outbound: [String: Any] = ["protocol": node.protocolName, "tag": "proxy",
                                       "streamSettings": stream]
        switch node.protocolName {
        case "vless", "vmess":
            var user: [String: Any] = ["id": node.credential]
            if node.protocolName == "vless" {
                user["encryption"] = node.encryption.isEmpty ? "none" : node.encryption
                if !node.flow.isEmpty { user["flow"] = node.flow }
            } else {
                user["security"] = node.encryption; user["alterId"] = node.alterID
            }
            outbound["settings"] = ["vnext": [["address": node.host, "port": node.port, "users": [user]]]]
        case "trojan":
            outbound["settings"] = ["servers": [["address": node.host, "port": node.port,
                                                   "password": node.credential]]]
        case "shadowsocks":
            outbound["settings"] = ["servers": [["address": node.host, "port": node.port,
                                                   "password": node.credential, "method": node.encryption]]]
        default: throw HarborProxyError.invalid("不支持 \(node.protocolName) 协议")
        }
        let forced = try HarborProxyDomainRules.normalized(forcedProxyDomains)
        var rules: [[String: Any]] = []
        if routeVerificationViaProxy && !routeAllViaProxy {
            let destinations = verificationHost.map { ["full:\($0)"] } ?? verificationHosts
            rules.append(["type": "field", "domain": destinations,
                          "outboundTag": "proxy"])
        }
        if !forced.isEmpty && !routeAllViaProxy {
            // First-match-wins: Gitee/custom sites must not be swallowed by geosite:cn
            // or resolve to a Chinese IP and fall through to geoip:cn.
            rules.append(["type": "field", "domain": forced.map { "domain:\($0)" },
                          "outboundTag": "proxy"])
        }
        if !routeAllViaProxy {
            rules.append(["type": "field", "ip": ["geoip:private"], "outboundTag": "direct"])
        }
        if ruleMode && !routeAllViaProxy {
            rules += [
                ["type": "field", "domain": ["geosite:cn"], "outboundTag": "direct"],
                ["type": "field", "ip": ["geoip:cn"], "outboundTag": "direct"]
            ]
        }
        let configuration: [String: Any] = [
            "log": ["loglevel": "warning"],
            "inbounds": [
                ["listen": "127.0.0.1", "port": httpPort, "protocol": "http", "settings": [:] as [String: Any]],
                ["listen": "127.0.0.1", "port": httpPort + 1, "protocol": "socks",
                 "settings": ["udp": true]]
            ],
            "outbounds": [outbound, ["protocol": "freedom", "tag": "direct"]],
            "routing": ["domainStrategy": ruleMode ? "IPIfNonMatch" : "AsIs", "rules": rules]
        ]
        return try JSONSerialization.data(withJSONObject: configuration, options: [.sortedKeys])
    }
}
