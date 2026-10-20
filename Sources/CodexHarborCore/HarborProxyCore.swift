import Foundation
import SQLite3

public struct HarborProxyNode: Codable, Identifiable, Sendable, Hashable {
    public var id: String
    public var name: String
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
    public init(id: String = UUID().uuidString, name: String, protocolName: String, host: String,
                port: Int, credential: String, encryption: String = "none", network: String = "tcp",
                security: String = "none", sni: String = "", headerHost: String = "", path: String = "",
                fingerprint: String = "", publicKey: String = "", shortID: String = "",
                flow: String = "", alterID: Int = 0, subscriptionID: String = "") {
        self.id = id; self.name = name; self.protocolName = protocolName; self.host = host
        self.port = port; self.credential = credential; self.encryption = encryption
        self.network = network; self.security = security; self.sni = sni
        self.headerHost = headerHost; self.path = path; self.fingerprint = fingerprint
        self.publicKey = publicKey; self.shortID = shortID; self.flow = flow
        self.alterID = alterID; self.subscriptionID = subscriptionID
    }
    public var label: String { "\(protocolName.uppercased()) · \(host):\(port)" }
}

public struct HarborProxySubscription: Codable, Identifiable, Sendable, Hashable {
    public var id: String
    public var name: String
    public var url: String
    public init(id: String = UUID().uuidString, name: String, url: String) {
        self.id = id; self.name = name; self.url = url
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

public enum HarborXrayConfig {
    public static func make(node: HarborProxyNode, httpPort: Int, ruleMode: Bool) throws -> Data {
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
            let headers: [String: String] = node.headerHost.isEmpty ? [:] : ["Host": node.headerHost]
            stream["wsSettings"] = ["path": node.path.isEmpty ? "/" : node.path, "headers": headers]
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
        var rules: [[String: Any]] = [
            ["type": "field", "ip": ["geoip:private"], "outboundTag": "direct"]
        ]
        if ruleMode {
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
