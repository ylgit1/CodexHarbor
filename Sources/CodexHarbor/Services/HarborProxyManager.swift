import CodexHarborCore
import Foundation
import Darwin
import Security

private struct HarborProxyState: Codable {
    var nodes: [HarborProxyNode] = []
    var subscriptions: [HarborProxySubscription] = []
    var selectedID: String?
    var routingRules = true
}
@MainActor
private struct HarborProxyProcessRecord: Codable {
    var pid: Int32
    var configPath: String
    var executablePath: String
}

@MainActor
private enum HarborProxyStore {
    static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.codexharbor.v2rayn-replacement",
        kSecAttrAccount as String: "settings"
    ]
    static func load() -> HarborProxyState {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let state = try? JSONDecoder().decode(HarborProxyState.self, from: data) else {
            return HarborProxyState()
        }
        return state
    }
    static func save(_ value: HarborProxyState) throws {
        let data = try JSONEncoder().encode(value)
        let result = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if result == errSecItemNotFound {
            var q = query
            q[kSecValueData as String] = data
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else {
                throw HarborProxyError.invalid("无法将配置保存到系统钥匙串")
            }
        } else if result != errSecSuccess { throw HarborProxyError.invalid("钥匙串保存失败") }
    }
}

@MainActor
final class HarborProxyManager: ObservableObject {
    static let shared = HarborProxyManager()
    @Published private(set) var nodes: [HarborProxyNode]
    @Published private(set) var subscriptions: [HarborProxySubscription]
    @Published private(set) var selectedID: String?
    @Published private(set) var running = false
    @Published private(set) var healthy = false
    @Published private(set) var busy = false
    @Published private(set) var systemManaged = false
    @Published private(set) var status = "已关闭"
    @Published private(set) var detail = ""
    @Published private(set) var localPort: Int?
    @Published private(set) var probeResults: [String: HarborProxyProbeResult] = [:]
    @Published private(set) var latencyTesting = false
    @Published private(set) var latencyCurrentID: String?
    @Published private(set) var latencyCompleted = 0
    @Published private(set) var latencyTotal = 0
    private var latencyCancellationRequested = false
    @Published private(set) var subscriptionUpdatedAt: [String: Date] = [:]
    @Published var routingRules: Bool { didSet { store.routingRules = routingRules; persist() } }
    private var store: HarborProxyState
    private var child: Process?
    private var configPath: URL?
    private var bootstrapped = false
    private var runtimeRecordURL: URL { root.appendingPathComponent("active-process.json") }
    private let root = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/CodexHarbor/NetworkProxy", isDirectory: true)
    var selectedNode: HarborProxyNode? { nodes.first { $0.id == selectedID } }
    var coreInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: root.appendingPathComponent("xray").path)
    }
    var systemProxyDescription: String { HarborSystemProxy.activeProxyDescription() }
    var requiresRecovery: Bool { HarborSystemProxy.hasBackup }

    private init() {
        let state = HarborProxyStore.load()
        store = state
        nodes = state.nodes; subscriptions = state.subscriptions
        selectedID = state.selectedID; routingRules = state.routingRules
        systemManaged = HarborSystemProxy.isOwned()
    }

    func bootstrap() async {
        guard !bootstrapped else { return }
        bootstrapped = true
        // Never autostart into a stale system proxy pointing at a dead port.
        if requiresRecovery {
            do {
                try HarborSystemProxy.restore(interactive: false)
                systemManaged = false
                detail = "上次退出的系统代理已恢复"
            } catch {
                detail = "系统代理等待恢复：" + error.localizedDescription
                return
            }
        }
        cleanupOrphan()
        // Restore the last selected node on every launch when Xray is installed.
        // This only starts Harbor's own listener; it must never silently replace
        // another app's macOS system proxy (for example v2rayN on port 10808).
        if selectedNode != nil && coreInstalled { await start() }
    }

    private func persist() {
        store.nodes = nodes
        store.subscriptions = subscriptions
        store.selectedID = selectedID
        do { try HarborProxyStore.save(store) }
        catch { detail = error.localizedDescription }
    }

    /// Read-only import. Copy Xray and geo assets into a Harbor-owned folder so
    /// Harbor no longer depends on the v2rayN process or app afterwards.
    func migrateV2rayN() {
        guard !busy, !running, !latencyTesting, child == nil,
              !FileManager.default.fileExists(atPath: runtimeRecordURL.path) else {
            detail = "检测到正在运行或待清理的 Xray，请先关闭代理再导入"
            return
        }
        busy = true
        defer { busy = false }
        let source = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/v2rayN")
        do {
            let imported = try HarborV2rayNReader.read(at: source)
            guard !imported.nodes.isEmpty else { throw HarborProxyError.invalid("没有可迁移的受支持节点") }
            try installCore(from: source)
            // Subscription providers can rotate IndexId on each refresh. Replace
            // the imported subscription groups atomically instead of appending duplicates.
            let merged = HarborProxyImportMerger.merge(
                currentNodes: nodes, currentSubscriptions: subscriptions,
                selectedID: selectedID, imported: imported
            )
            nodes = merged.nodes
            subscriptions = merged.subscriptions
            selectedID = merged.selectedID
            persist()
            detail = "迁移成功：\(imported.nodes.count) 个节点、\(imported.subscriptions.count) 条订阅；\(imported.unsupportedCount) 条非支持类型未导入。原 v2rayN 配置未修改。"
        } catch { detail = "迁移失败：" + error.localizedDescription }
    }

    private func installCore(from source: URL) throws {
        // Prefer the previously downloaded official arm64 core when present,
        // rather than shipping the Intel/Rosetta binary bundled with v2rayN.
        let native = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CodexHarbor/Proxy/xray/xray")
        let binary = nativeArm64(native) ? native : source.appendingPathComponent("bin/xray/xray")
        let files = [
            (binary, root.appendingPathComponent("xray")),
            (source.appendingPathComponent("bin/geosite.dat"), root.appendingPathComponent("geosite.dat")),
            (source.appendingPathComponent("bin/geoip.dat"), root.appendingPathComponent("geoip.dat"))
        ]
        guard files.allSatisfy({ FileManager.default.fileExists(atPath: $0.0.path) }) else {
            throw HarborProxyError.invalid("v2rayN 缺少 Xray 内核或规则数据")
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (from, to) in files {
            let tmp = root.appendingPathComponent(UUID().uuidString)
            try FileManager.default.copyItem(at: from, to: tmp)
            if FileManager.default.fileExists(atPath: to.path) { try FileManager.default.removeItem(at: to) }
            try FileManager.default.moveItem(at: tmp, to: to)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.appendingPathComponent("xray").path)
    }

    private func nativeArm64(_ binary: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: binary) else { return false }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 8), header.count == 8 else { return false }
        let bytes = [UInt8](header)
        // Thin little-endian Mach-O 64-bit with CPU_TYPE_ARM64.
        return bytes[0...3].elementsEqual([0xcf, 0xfa, 0xed, 0xfe])
            && bytes[4...7].elementsEqual([0x0c, 0x00, 0x00, 0x01])
    }

    func addLinks(_ value: String) {
        let items = HarborProxyLinks.parse(value)
        guard !items.isEmpty else { detail = "未找到有效节点链接"; return }
        nodes += items
        if selectedID == nil { selectedID = items[0].id }
        persist(); detail = "已导入 \(items.count) 个节点"
    }

    func addSubscription(name: String, url: String) {
        guard let u = URL(string: url), u.scheme == "https" else {
            detail = "订阅必须使用 HTTPS"; return
        }
        subscriptions.append(HarborProxySubscription(name: name, url: url))
        persist()
    }
    @discardableResult
    func removeSubscription(_ id: String) -> Bool {
        guard !busy, !latencyTesting else {
            detail = "请等待当前操作结束后再删除订阅"
            return false
        }
        guard let subscription = subscriptions.first(where: { $0.id == id }) else { return false }
        let matching = nodes.filter { $0.subscriptionID == id }
        if running && matching.contains(where: { $0.id == selectedID }) {
            detail = "正在使用此订阅节点，请先清理代理再删除订阅"
            return false
        }
        subscriptions.removeAll { $0.id == id }
        let removedIDs = Set(matching.map(\.id))
        nodes.removeAll { removedIDs.contains($0.id) }
        for nodeID in removedIDs { probeResults.removeValue(forKey: nodeID) }
        subscriptionUpdatedAt.removeValue(forKey: id)
        if let selectedID, removedIDs.contains(selectedID) {
            self.selectedID = nodes.first?.id
        }
        persist()
        detail = "已删除订阅「\(subscription.name)」及其 \(matching.count) 个节点"
        return true
    }

    func refreshSubscription(_ id: String) async {
        guard !busy, let subscription = subscriptions.first(where: { $0.id == id }),
              let url = URL(string: subscription.url) else { return }
        busy = true
        defer { busy = false }
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 15
            let config = URLSessionConfiguration.ephemeral
            if running, healthy, let localPort {
                config.connectionProxyDictionary = [
                    "HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": localPort,
                    "HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": localPort
                ]
            }
            let session = URLSession(configuration: config)
            defer { session.invalidateAndCancel() }
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 2_000_000,
                  let text = String(data: data, encoding: .utf8) else {
                throw HarborProxyError.invalid("订阅响应无效")
            }
            let replacement = HarborProxyLinks.parse(text).map { original -> HarborProxyNode in
                var node = original
                node.subscriptionID = id
                return node
            }
            guard !replacement.isEmpty else { throw HarborProxyError.invalid("订阅无支持的节点格式") }
            let old = nodes.filter { $0.subscriptionID == id }
            nodes.removeAll { $0.subscriptionID == id }
            nodes += replacement
            if let chosen = selectedID, old.contains(where: { $0.id == chosen }) {
                selectedID = replacement.first?.id
            }
            persist()
            subscriptionUpdatedAt[id] = .now
            detail = "订阅更新完成：\(replacement.count) 个节点"
        } catch { detail = "更新失败：" + error.localizedDescription }
    }

    func select(_ id: String) async {
        guard nodes.contains(where: { $0.id == id }) else { return }
        let wasRunning = running
        let wasManaged = systemManaged
        if wasRunning && !stop() { return }
        selectedID = id; persist()
        if wasRunning {
            await start()
            if wasManaged && healthy { enableSystemProxy() }
        }
    }
    /// Select-and-connect, matching v2rayN's one-click node workflow.
    /// If another application currently owns system proxy settings, the
    /// existing fail-closed policy remains in place; no takeover occurs.
    func activate(_ id: String) async {
        guard !busy, nodes.contains(where: { $0.id == id }) else { return }
        if id != selectedID {
            await select(id)
        } else if !running {
            await start()
        }
        guard running, healthy, !systemManaged else { return }
        enableSystemProxy()
    }

    /// The visible 'clear proxy' action never silently deletes another
    /// application's system settings or node/subscription configurations.
    func clearProxy() {
        if running || requiresRecovery {
            _ = stop()
        } else {
            detail = "Harbor 当前没有启用代理；其他程序的系统代理设置未修改"
        }
    }

    func remove(_ id: String) {
        guard id != selectedID || !running else { detail = "请先切换或关闭当前节点"; return }
        nodes.removeAll { $0.id == id }
        if selectedID == id { selectedID = nodes.first?.id }
        persist()
    }

    func start() async {
        guard !busy, !running else { return }
        // A former Xray can still be alive if its health state was lost.
        // Do not overwrite our process handle and leave an orphan listening.
        if child != nil && !stop() { return }
        if FileManager.default.fileExists(atPath: runtimeRecordURL.path) {
            cleanupOrphan()
            guard !FileManager.default.fileExists(atPath: runtimeRecordURL.path) else {
                detail = "发现上次未清理的 Xray 进程，已阻止重复启动"
                return
            }
        }
        guard !requiresRecovery else { detail = "请先恢复残留的系统代理设置"; return }
        guard let node = selectedNode else { detail = "先导入并选择节点"; return }
        guard coreInstalled else { detail = "请先从 v2rayN 迁移 Xray 内核"; return }
        busy = true; defer { busy = false }
        status = "正在连接"; detail = ""
        do {
            let port = try choosePort()
            let config = try HarborXrayConfig.make(node: node, httpPort: port, ruleMode: routingRules)
            let file = root.appendingPathComponent("runtime-\(UUID().uuidString).json")
            try config.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            configPath = file
            let process = Process()
            process.executableURL = root.appendingPathComponent("xray")
            process.currentDirectoryURL = root
            process.arguments = ["run", "-config", file.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            child = process; localPort = port
            let record = HarborProxyProcessRecord(
                pid: process.processIdentifier, configPath: file.path,
                executablePath: process.executableURL?.path ?? ""
            )
            try JSONEncoder().encode(record).write(to: runtimeRecordURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: runtimeRecordURL.path)
            var ready = false
            for _ in 0..<25 {
                guard process.isRunning else { break }
                if !portFree(port) && !portFree(port + 1) { ready = true; break }
                try? await Task.sleep(for: .milliseconds(150))
            }
            let checked = ready ? await probe(port: port) : false
            guard process.isRunning, checked else {
                _ = stop()
                throw HarborProxyError.invalid("Xray 未能完成联网验证，请检查节点配置")
            }
            running = true; healthy = true; status = "已连接"
            detail = "HTTP 127.0.0.1:\(port) · SOCKS5 \(port + 1)"
        } catch { _ = stop(); status = "连接失败"; detail = error.localizedDescription }
    }

    func verify() async {
        guard running, let port = localPort, !busy else { return }
        busy = true; defer { busy = false }
        healthy = await probe(port: port)
        status = healthy ? "已连接" : "连接异常"
        detail = healthy ? "当前节点可访问外网" : "内核运行中，但测试目标不可达；可尝试切换节点"
    }

    private func probe(port: Int) async -> Bool {
        let nodeID = selectedID
        let addresses = ["https://www.apple.com/library/test/success.html",
                         "https://www.gstatic.com/generate_204",
                         "https://www.cloudflare.com/cdn-cgi/trace"]
        for address in addresses {
            let started = ContinuousClock.now
            let succeeded = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
                proc.arguments = ["-q", "--silent", "--fail", "--noproxy", "", "--proxy",
                                  "http://127.0.0.1:\(port)", "--connect-timeout", "2",
                                  "--max-time", "4", "--output", "/dev/null", address]
                proc.standardError = FileHandle.nullDevice
                proc.standardOutput = FileHandle.nullDevice
                proc.terminationHandler = { p in continuation.resume(returning: p.terminationStatus == 0) }
                do { try proc.run() } catch { continuation.resume(returning: false) }
            }
            if succeeded {
                let duration = started.duration(to: .now).components
                let milliseconds = max(1, Int(duration.seconds * 1_000 + duration.attoseconds / 1_000_000_000_000_000))
                if let nodeID { probeResults[nodeID] = HarborProxyProbeResult(milliseconds: milliseconds) }
                return true
            }
        }
        if let nodeID { probeResults[nodeID] = HarborProxyProbeResult(milliseconds: nil) }
        return false
    }

    /// User-triggered latency checks. Each node uses a short-lived independent
    /// Xray process and HTTPS request; never switch the active system proxy.
    func testLatency(_ ids: [String]) async {
        guard !latencyTesting, !busy, coreInstalled else {
            if !coreInstalled { detail = "请先导入 Xray 内核，才能测试节点延迟" }
            return
        }
        let uniqueIDs = Array(NSOrderedSet(array: ids)) as? [String] ?? ids
        let targets = uniqueIDs.compactMap { id in nodes.first(where: { $0.id == id }) }
        guard !targets.isEmpty else { return }

        latencyTesting = true
        latencyCancellationRequested = false
        latencyCompleted = 0
        latencyTotal = targets.count
        defer {
            latencyTesting = false
            latencyCurrentID = nil
            latencyCancellationRequested = false
        }
        for node in targets {
            if latencyCancellationRequested || Task.isCancelled { break }
            latencyCurrentID = node.id
            let result = await HarborNodeLatencyTester.measure(node: node, root: root, ruleMode: routingRules)
            probeResults[node.id] = HarborProxyProbeResult(milliseconds: result)
            latencyCompleted += 1
        }
        detail = "本次测试完成 \(latencyCompleted)/\(latencyTotal) 个节点；测试为经过 Xray 的 HTTPS 请求耗时"
    }

    func cancelLatencyTests() {
        latencyCancellationRequested = true
    }

    func enableSystemProxy() {
        guard running, healthy, let localPort else { detail = "请先连接并验证当前节点"; return }
        do {
            try HarborSystemProxy.enable(port: localPort)
            systemManaged = true
            detail = "已设置 macOS 系统代理，可随时清除"
        } catch { detail = error.localizedDescription }
    }

    func clearSystemProxy() {
        do {
            try HarborSystemProxy.restore(interactive: true)
            systemManaged = false
            detail = "原系统代理设置已恢复"
        } catch { detail = error.localizedDescription }
    }

    @discardableResult
    func stop(interactive: Bool = true) -> Bool {
        if requiresRecovery {
            do { try HarborSystemProxy.restore(interactive: interactive) }
            catch { detail = "系统代理未恢复，请先清除再关闭：" + error.localizedDescription; return false }
        }
        systemManaged = false
        if child == nil && FileManager.default.fileExists(atPath: runtimeRecordURL.path) {
            cleanupOrphan()
            guard !FileManager.default.fileExists(atPath: runtimeRecordURL.path) else {
                detail = "存在未清理的 Xray 进程，不能标记为已关闭"
                return false
            }
        }
        if let child {
            if child.isRunning {
                child.terminate()
                for _ in 0..<20 where child.isRunning { usleep(50_000) }
                if child.isRunning { _ = Darwin.kill(child.processIdentifier, SIGKILL) }
                for _ in 0..<20 where child.isRunning { usleep(50_000) }
                if child.isRunning {
                    detail = "代理内核未能退出，请手动检查进程"
                    return false
                }
            }
            self.child = nil
        }
        if let configPath { try? FileManager.default.removeItem(at: configPath) }
        try? FileManager.default.removeItem(at: runtimeRecordURL)
        configPath = nil; localPort = nil
        running = false; healthy = false; status = "已关闭"
        return true
    }

    /// Only remove an orphan that matches Harbor's unique config path and executable.
    /// Never kill a PID solely because a prior runtime record contains that number.
    private func cleanupOrphan() {
        guard let data = try? Data(contentsOf: runtimeRecordURL),
              let record = try? JSONDecoder().decode(HarborProxyProcessRecord.self, from: data),
              record.pid > 0 else { return }
        let config = URL(fileURLWithPath: record.configPath).standardizedFileURL
        guard config.deletingLastPathComponent() == root.standardizedFileURL,
              config.lastPathComponent.hasPrefix("runtime-"),
              config.pathExtension == "json",
              record.executablePath == root.appendingPathComponent("xray").path else {
            detail = "检测到异常的旧代理恢复记录，已停止自动清理"
            return
        }
        let command = Process()
        let pipe = Pipe()
        command.executableURL = URL(fileURLWithPath: "/bin/ps")
        command.arguments = ["-ww", "-p", String(record.pid), "-o", "command="]
        command.standardOutput = pipe
        command.standardError = FileHandle.nullDevice
        do {
            try command.run()
            command.waitUntilExit()
            let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            if command.terminationStatus == 0,
               output.contains(record.executablePath),
               output.contains(record.configPath),
               output.contains("run") {
                _ = Darwin.kill(record.pid, SIGTERM)
                for _ in 0..<20 where Darwin.kill(record.pid, 0) == 0 { usleep(50_000) }
                guard Darwin.kill(record.pid, 0) != 0 else {
                    detail = "旧代理进程尚未退出，请手动处理"
                    return
                }
            }
            try? FileManager.default.removeItem(at: config)
            try? FileManager.default.removeItem(at: runtimeRecordURL)
        } catch { detail = "旧代理进程检查失败：" + error.localizedDescription }
    }

    private func choosePort() throws -> Int {
        for port in stride(from: 18080, through: 18160, by: 2)
            where portFree(port) && portFree(port + 1) { return port }
        throw HarborProxyError.invalid("无可用代理监听端口")
    }
    private func portFree(_ port: Int) -> Bool {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr = in_addr(s_addr: in_addr_t(INADDR_LOOPBACK).bigEndian)
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }
}
