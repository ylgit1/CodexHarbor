import Darwin
import Foundation
#if DEBUG
import CodexHarborCore
@testable import HarborProxyRuntime

private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    private let continuation: CheckedContinuation<Data?, Never>
    init(_ continuation: CheckedContinuation<Data?, Never>) { self.continuation = continuation }
    func finish(_ value: Data?) {
        let deliver = lock.withLock {
            guard !completed else { return false }
            completed = true
            return true
        }
        if deliver { continuation.resume(returning: value) }
    }
}

@main
struct FixtureMain {
    @MainActor
    static func main() async {
        let args = CommandLine.arguments
        guard getuid() != 0, args.count >= 4,
              args[2].hasPrefix("com.codexharbor.proxy-ipc-test."),
              UUID(uuidString: String(args[2].dropFirst("com.codexharbor.proxy-ipc-test.".count))) != nil else { exit(64) }
        let root = URL(fileURLWithPath: args[3]).standardizedFileURL
        guard root.lastPathComponent.hasPrefix("harbor-ipc-test-"),
              root.path.hasPrefix("/private/var/folders/") || root.path.hasPrefix("/var/folders/") else { exit(64) }
        var info = stat()
        guard lstat(root.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == getuid(), (info.st_mode & 0o077) == 0 else { exit(64) }
        let label = args[2]
        if args[1] == "server", args.count == 4 {
            let runtime = HarborProxyAgentRuntime(isolatedRoot: root, verification: { _ in false })
            await runtime.start()
            let listener = NSXPCListener(machServiceName: label)
            let delegate = AgentListenerDelegate(runtime: runtime)
            listener.delegate = delegate
            listener.resume()
            while true {
                try? await Task.sleep(for: .seconds(3600))
                withExtendedLifetime(listener) {}
                withExtendedLifetime(delegate) {}
            }
        }
        guard args[1] == "client", args.count == 6, let port = Int(args[5]),
              (28000...28998).contains(port), port % 2 == 0 else { exit(64) }
        let command: HarborProxyAgentCommand
        switch args[4] {
        case "inspect": command = .inspect
        case "open": command = .openGateway(port: port)
        case "stop": command = .stopGateway(port: port)
        default: exit(64)
        }
        let connection = NSXPCConnection(machServiceName: label, options: [])
        do { try HarborAgentSigningRequirement.authenticate(connection, identifier: HarborProxyAgentConstants.label) }
        catch { print("LOCAL_SIGNATURE_REJECTED"); exit(3) }
        connection.remoteObjectInterface = NSXPCInterface(with: HarborProxyAgentRPC.self)
        connection.resume()
        let request = try! JSONEncoder().encode(HarborProxyAgentRequest(command))
        let data: Data? = await withCheckedContinuation { continuation in
            let gate = Gate(continuation)
            connection.invalidationHandler = { gate.finish(nil) }
            connection.interruptionHandler = { gate.finish(nil) }
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in gate.finish(nil) }) as? HarborProxyAgentRPC else {
                gate.finish(nil); return
            }
            Task.detached {
                try? await Task.sleep(for: .seconds(8))
                gate.finish(nil)
            }
            proxy.perform(request) { gate.finish($0) }
        }
        connection.invalidate()
        guard let data, let reply = try? JSONDecoder().decode(HarborProxyAgentReply.self, from: data),
              reply.errorCode == nil, let snapshot = reply.snapshot else {
            print("RPC_REJECTED"); exit(2)
        }
        let encoder = JSONEncoder()
        print(String(decoding: try! encoder.encode(snapshot), as: UTF8.self))
    }
}
#else
@main struct FixtureMain { static func main() { exit(64) } }
#endif
