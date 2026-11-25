import CodexHarborCore
import HarborProxyRuntime
import Darwin
import Foundation

@main
struct HarborProxyAgentMain {
    @MainActor
    static func main() async {
        guard getuid() != 0 else { exit(64) }
        if Array(CommandLine.arguments.dropFirst()) == ["--verify-package"] {
            exit(await verifyPackage() ? EXIT_SUCCESS : EXIT_FAILURE)
        }
        // The release check never accesses the production journal, launchd
        // job, system proxy or Keychain. The normal entry takes no arguments.
        guard CommandLine.arguments.count == 1 else { exit(64) }
        let runtime = HarborProxyAgentRuntime()
        await runtime.start()
        let listener = NSXPCListener(machServiceName: HarborProxyAgentConstants.label)
        let delegate = AgentListenerDelegate(runtime: runtime)
        listener.delegate = delegate
        listener.resume()
        // Retain listener/delegate for the entire launchd service lifetime.
        while true {
            try? await Task.sleep(for: .seconds(3600))
            withExtendedLifetime(listener) {}
            withExtendedLifetime(delegate) {}
        }
    }

    private static func verifyPackage() async -> Bool {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let app = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        do {
            try HarborAgentSigningRequirement.verifyPeer(at: executable, identifier: HarborProxyAgentConstants.label)
            try HarborAgentSigningRequirement.verifyPeer(at: app, identifier: HarborProxyAgentConstants.appIdentifier)
        } catch {
            FileHandle.standardError.write(Data("Packaged app and proxy helper cannot authenticate each other.\n".utf8))
            return false
        }
        for port in stride(from: 29400, to: 29700, by: 2).shuffled().prefix(4) {
            guard !HarborLoopbackTCP.isListening(port), !HarborLoopbackTCP.isListening(port + 1),
                  let gateway = try? HarborLocalProxyGateway(httpPort: port, connectionLimit: 1) else { continue }
            defer { gateway.stop() }
            if (try? await gateway.start()) != nil, gateway.isReady,
               HarborLoopbackTCP.isListening(port), HarborLoopbackTCP.isListening(port + 1) {
                print("Packaged proxy helper: signing compatibility and both loopback listeners verified.")
                return true
            }
        }
        FileHandle.standardError.write(Data("Packaged proxy helper could not open test listeners.\n".utf8))
        return false
    }
}
