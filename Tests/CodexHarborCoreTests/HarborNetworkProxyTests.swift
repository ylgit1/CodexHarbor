import Foundation
import SQLite3
import Testing
@testable import CodexHarborCore

@Suite("Independent network proxy")
struct HarborNetworkProxyTests {
    @Test("Xray creates loopback listeners and isolated routing")
    func xrayConfiguration() throws {
        let node = HarborProxyNode(name: "test", protocolName: "vless",
            host: "node.example.com", port: 443,
            credential: "00000000-0000-0000-0000-000000000001",
            network: "ws", security: "tls", sni: "example.com",
            headerHost: "host.example.com", path: "/proxy")
        let bytes = try HarborXrayConfig.make(node: node, httpPort: 18080, ruleMode: true)
        let object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let listeners = try #require(object["inbounds"] as? [[String: Any]])
        #expect(listeners.count == 2)
        #expect(listeners.allSatisfy { ($0["listen"] as? String) == "127.0.0.1" })
        #expect(listeners.compactMap { $0["port"] as? Int } == [18080, 18081])
        let rules = try #require(object["routing"] as? [String: Any])
        #expect((rules["rules"] as? [[String: Any]])?.count == 3)
        let all = try HarborXrayConfig.make(node: node, httpPort: 18080, ruleMode: false)
        let other = try #require(JSONSerialization.jsonObject(with: all) as? [String: Any])
        let allRules = try #require(other["routing"] as? [String: Any])
        #expect((allRules["rules"] as? [[String: Any]])?.count == 1)
    }

    @Test("Installed Xray accepts generated rule-mode configuration when available")
    func validatesActualXray() throws {
        let source = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/v2rayN/bin")
        let binary = source.appendingPathComponent("xray/xray")
        guard FileManager.default.isExecutableFile(atPath: binary.path),
              FileManager.default.fileExists(atPath: source.appendingPathComponent("geosite.dat").path),
              FileManager.default.fileExists(atPath: source.appendingPathComponent("geoip.dat").path) else {
            return
        }
        let node = HarborProxyNode(name: "fixture", protocolName: "vless",
            host: "node.example.com", port: 443,
            credential: "00000000-0000-0000-0000-000000000001",
            network: "ws", security: "tls", sni: "node.example.com",
            headerHost: "node.example.com", path: "/")
        let config = try HarborXrayConfig.make(node: node, httpPort: 18080, ruleMode: true)
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: destination) }
        try config.write(to: destination)
        let process = Process()
        process.executableURL = binary
        process.arguments = ["run", "-test", "-config", destination.path]
        process.currentDirectoryURL = source
        process.environment = ProcessInfo.processInfo.environment.merging(["XRAY_LOCATION_ASSET": source.path]) { _, newer in newer }
        let errorOutput = Pipe()
        process.standardOutput = errorOutput
        process.standardError = errorOutput
        try process.run()
        process.waitUntilExit()
        let errorText = String(decoding: errorOutput.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(process.terminationStatus == 0, "Xray load issue: \(errorText)")
    }

    @Test("VLESS share link carries websocket and TLS settings")
    func linkParsing() throws {
        let url = "vless://00000000-0000-0000-0000-000000000001@example.com:443?type=ws&security=tls&path=%2Fsome&host=host.example.com#Test"
        let node = try #require(HarborProxyLinks.parse(url).first)
        #expect(node.protocolName == "vless")
        #expect(node.network == "ws")
        #expect(node.security == "tls")
        #expect(node.path == "/some")
        #expect(node.headerHost == "host.example.com")
    }

    @Test("Optional live selected v2rayN node remains isolated from the macOS proxy")
    func liveSelectedNode() throws {
        guard ProcessInfo.processInfo.environment["HARBOR_LIVE_PROXY_SMOKE"] == "1" else { return }
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/v2rayN")
        let imported = try HarborV2rayNReader.read(at: base)
        guard let selected = imported.nodes.first(where: { $0.id == imported.selectedID }) else {
            Issue.record("当前 v2rayN 节点不存在或不是受支持格式")
            return
        }
        let native = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CodexHarbor/Proxy/xray/xray")
        let embedded = base.appendingPathComponent("bin/xray/xray")
        let binary = FileManager.default.isExecutableFile(atPath: native.path) ? native : embedded
        let config = try HarborXrayConfig.make(node: selected, httpPort: 18150, ruleMode: true)
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("harbor-proxy-smoke-" + UUID().uuidString + ".json")
        try config.write(to: path, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        defer { try? FileManager.default.removeItem(at: path) }

        let xray = Process()
        xray.executableURL = binary
        xray.arguments = ["run", "-config", path.path]
        xray.environment = ProcessInfo.processInfo.environment.merging([
            "XRAY_LOCATION_ASSET": base.appendingPathComponent("bin").path
        ]) { _, new in new }
        xray.standardOutput = FileHandle.nullDevice
        xray.standardError = FileHandle.nullDevice
        try xray.run()
        defer { if xray.isRunning { xray.terminate() } }
        Thread.sleep(forTimeInterval: 1.5)
        #expect(xray.isRunning)
        let curl = Process()
        curl.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        curl.arguments = ["-q", "--fail", "--silent", "--noproxy", "",
                          "--proxy", "http://127.0.0.1:18150",
                          "--connect-timeout", "3", "--max-time", "9",
                          "--output", "/dev/null",
                          "https://www.apple.com/library/test/success.html"]
        curl.standardError = FileHandle.nullDevice
        curl.standardOutput = FileHandle.nullDevice
        try curl.run()
        curl.waitUntilExit()
        #expect(curl.terminationStatus == 0, "选中节点无法完成独立代理联网；macOS 系统代理未更改")
    }

    @Test("v2rayN SQLite reader imports supported nodes read-only, preserving source")
    func sqliteMigration() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let gui = root.appendingPathComponent("guiConfigs")
        try FileManager.default.createDirectory(at: gui, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(#"{"IndexId":"profile-1"}"#.utf8)
            .write(to: gui.appendingPathComponent("guiNConfig.json"))
        var db: OpaquePointer?
        let dbURL = gui.appendingPathComponent("guiNDB.db")
        #expect(sqlite3_open(dbURL.path, &db) == SQLITE_OK)
        let dbValue = try #require(db)
        defer { sqlite3_close(dbValue) }
        let sql = """
        CREATE TABLE ProfileItem (IndexId TEXT,ConfigType TEXT,Address TEXT,Port INTEGER,
          Id TEXT,AlterId INTEGER,Security TEXT,Network TEXT,Remarks TEXT,RequestHost TEXT,
          Path TEXT,StreamSecurity TEXT,Subid TEXT,Flow TEXT,Sni TEXT,
          Fingerprint TEXT,PublicKey TEXT,ShortId TEXT);
        CREATE TABLE SubItem (Id TEXT,Remarks TEXT,Url TEXT);
        INSERT INTO ProfileItem VALUES ('profile-1','5','edge.example.com',443,
          'dummy-uuid',0,'none','ws','Example Node','host.example.com',
          '/demo','tls','subscription-1','','edge.example.com','chrome','','');
        INSERT INTO ProfileItem VALUES ('unsupported','11','other.example.com',443,
          'secret',0,'none','tcp','unsupported','','','tls','','','','','','');
        INSERT INTO SubItem VALUES ('subscription-1','Example','https://example.com/subscribe');
        """
        #expect(sqlite3_exec(dbValue, sql, nil, nil, nil) == SQLITE_OK)
        let before = try Data(contentsOf: dbURL)
        let result = try HarborV2rayNReader.read(at: root)
        #expect(result.nodes.count == 1)
        #expect(result.subscriptions.count == 1)
        #expect(result.selectedID == "profile-1")
        #expect(result.nodes[0].network == "ws")
        #expect(result.nodes[0].subscriptionID == "subscription-1")
        #expect(result.unsupportedCount == 1)
        #expect(try Data(contentsOf: dbURL) == before)
    }
}
