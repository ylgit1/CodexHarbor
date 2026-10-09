import Darwin
import Foundation

/// One-frame screenshot transport between the launchd Agent and the foreground
/// Codex Harbor application. Image bytes stay in a Unix domain socket: no
/// desktop recording, temporary screenshot files, or public TCP listener.
public enum HarborUICaptureSocket {
    private static let maxMessageBytes = 3_500_000

    private struct Request: Codable, Sendable {
        let bundleID: String
        let windowIndex: Int
        let windowTitle: String
    }

    private struct Response: Codable {
        let result: HarborUICaptureResult?
        let error: String?
    }

    private static func socketPath(_ paths: BridgePaths) -> String {
        paths.root.appendingPathComponent("ui-capture.sock").path
    }

    /// Runs only from the MCP Agent after the user granted this app/capability.
    public static func capture(
        paths: BridgePaths, bundleID: String,
        windowIndex: Int, windowTitle: String
    ) async throws -> HarborUICaptureResult {
        let request = Request(bundleID: bundleID, windowIndex: windowIndex, windowTitle: windowTitle)
        // The Agent retains the AX-based exact-window check; the GUI process
        // separately verifies a unique matching ScreenCaptureKit window.
        let available = try await HarborUIAutomationService(paths: paths).windows(bundleID: bundleID)
        guard available.contains(where: { $0.windowIndex == windowIndex && $0.title == windowTitle }) else {
            throw BridgeError.permissionDenied("截图窗口已变化，请重新选择")
        }
        return try await Task.detached(priority: .userInitiated) {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw BridgeError.searchFailed("无法创建本地截图连接") }
            defer { _ = Darwin.close(fd) }
            setTimeout(fd, seconds: 12)
            var address = try socketAddress(socketPath(paths))
            let connected = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard connected == 0 else {
                throw BridgeError.permissionDenied("前台 Codex Harbor 截图服务不可用，请打开主应用")
            }
            try send(JSONEncoder().encode(request), fd: fd)
            let response = try JSONDecoder().decode(Response.self, from: receive(fd: fd))
            if let result = response.result { return result }
            throw BridgeError.permissionDenied(response.error ?? "前台截图失败")
        }.value
    }

    @MainActor
    public final class Server {
        public static let shared = Server()
        private var listener: Int32 = -1
        private var paths: BridgePaths?

        private init() {}

        public func start() {
            guard listener == -1, let paths = try? BridgePaths.live() else { return }
            do {
                try paths.ensureDirectories()
                let location = socketPath(paths)
                let fd = socket(AF_UNIX, SOCK_STREAM, 0)
                guard fd >= 0 else { return }
                var address = try socketAddress(location)
                // Refuse to replace an active server. Remove a socket left by
                // a crashed previous GUI process only after probing it.
                let probe = socket(AF_UNIX, SOCK_STREAM, 0)
                if probe >= 0 {
                    let active = withUnsafePointer(to: &address) { pointer in
                        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            Darwin.connect(probe, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
                        }
                    }
                    _ = Darwin.close(probe)
                    if active { _ = Darwin.close(fd); return }
                }
                _ = unlink(location)
                let bound = withUnsafePointer(to: &address) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                    }
                }
                guard bound == 0 else { _ = Darwin.close(fd); return }
                _ = chmod(location, 0o600)
                guard listen(fd, 4) == 0 else { _ = Darwin.close(fd); return }
                self.listener = fd
                self.paths = paths
                DispatchQueue.global(qos: .utility).async {
                    while true {
                        let client = Darwin.accept(fd, nil, nil)
                        if client >= 0 {
                            Task.detached(priority: .userInitiated) {
                                await handleClient(client, paths: paths)
                            }
                        } else if errno != EINTR {
                            break
                        }
                    }
                }
            } catch {
                NSLog("Harbor capture socket setup failed: %@", String(describing: error))
            }
        }
    }

    private static func handleClient(_ fd: Int32, paths: BridgePaths) async {
        defer { _ = Darwin.close(fd) }
        setTimeout(fd, seconds: 12)
        do {
            // Peer PID and exact executable path are checked on the local
            // Unix socket. Generic same-user processes cannot ask the GUI to
            // take screenshots by merely writing to shared application files.
            var peerUID: uid_t = 0
            var peerGID: gid_t = 0
            guard getpeereid(fd, &peerUID, &peerGID) == 0, peerUID == getuid(),
                  isTrustedAgentPeer(fd) else {
                throw BridgeError.permissionDenied("截图请求不是来自本机 Codex Harbor Agent")
            }
            let request = try JSONDecoder().decode(Request.self, from: receive(fd: fd))
            guard HarborUIAuthorization.isValidTarget(request.bundleID),
                  request.windowIndex >= 0,
                  !request.windowTitle.isEmpty,
                  request.windowTitle.utf8.count < 300,
                  HarborUIConsentStore(paths: paths).allows(
                    bundleID: request.bundleID, capability: .capture
                  ) else {
                throw BridgeError.permissionDenied("目标应用或截图能力未获本地用户授权")
            }
            let service = await HarborUICaptureService(paths: paths)
            let result = try await service.capture(
                bundleID: request.bundleID,
                windowIndex: request.windowIndex,
                windowTitle: request.windowTitle,
                skipAgentAXValidation: true
            )
            try send(JSONEncoder().encode(Response(result: result, error: nil)), fd: fd)
        } catch {
            let response = Response(result: nil, error: error.localizedDescription)
            if let data = try? JSONEncoder().encode(response) {
                try? send(data, fd: fd)
            }
        }
    }

    private static func isTrustedAgentPeer(_ fd: Int32) -> Bool {
        var pid: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0, pid > 0 else {
            return false
        }
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else {
            return false
        }
        let path = String(cString: buffer)
        // Only the installed, signed Helper inside the running app bundle.
        guard let applicationURL = Bundle.main.bundleURL as URL? else { return false }
        let expected = applicationURL.appendingPathComponent(
            "Contents/Helpers/HarborChatGPTAgent"
        ).standardizedFileURL.path
        return path == expected
    }

    private static func socketAddress(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        let pathBytes = Array(path.utf8) + [0]
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count <= capacity else {
            throw BridgeError.invalidPath("本地截图 socket 路径过长")
        }
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in pathBytes.enumerated() { buffer[index] = byte }
        }
        return address
    }

    private static func setTimeout(_ fd: Int32, seconds: Int) {
        var timeout = timeval(tv_sec: seconds, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                       socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout,
                       socklen_t(MemoryLayout<timeval>.size))
    }

    private static func send(_ data: Data, fd: Int32) throws {
        guard data.count <= maxMessageBytes else { throw BridgeError.fileTooLarge("截图响应过大") }
        let count = UInt32(data.count)
        let prefix = Data([
            UInt8((count >> 24) & 0xff), UInt8((count >> 16) & 0xff),
            UInt8((count >> 8) & 0xff), UInt8(count & 0xff)
        ])
        try writeAll(prefix, fd: fd)
        try writeAll(data, fd: fd)
    }

    private static func writeAll(_ data: Data, fd: Int32) throws {
        var offset = 0
        while offset < data.count {
            let written = data.withUnsafeBytes { bytes in
                Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), data.count - offset)
            }
            guard written > 0 else { throw BridgeError.searchFailed("截图 socket 写入失败") }
            offset += written
        }
    }

    private static func receive(fd: Int32) throws -> Data {
        let prefix = try readExact(fd: fd, count: 4)
        let bytes = Array(prefix)
        let count = bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard count > 0, count <= maxMessageBytes else {
            throw BridgeError.searchFailed("截图响应尺寸无效")
        }
        return try readExact(fd: fd, count: Int(count))
    }

    private static func readExact(fd: Int32, count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            let received = bytes.withUnsafeMutableBytes { buffer in
                Darwin.read(fd, buffer.baseAddress!.advanced(by: offset), count - offset)
            }
            guard received > 0 else {
                throw BridgeError.searchFailed("截图连接提前关闭或超时")
            }
            offset += received
        }
        return Data(bytes)
    }
}
