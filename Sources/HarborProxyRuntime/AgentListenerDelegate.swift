import CodexHarborCore
import Darwin
import Foundation

private final class ReplyBox: @unchecked Sendable {
    let reply: (Data) -> Void
    init(_ reply: @escaping (Data) -> Void) { self.reply = reply }
}

private final class AgentEndpoint: NSObject, HarborProxyAgentRPC, @unchecked Sendable {
    private let runtime: HarborProxyAgentRuntime
    private let peerPID: Int32
    private let sessionID: UUID
    private let stateLock = NSLock()
    private var disconnected = false

    init(runtime: HarborProxyAgentRuntime, peerPID: Int32, sessionID: UUID) {
        self.runtime = runtime
        self.peerPID = peerPID
        self.sessionID = sessionID
    }

    func disconnect() {
        stateLock.withLock { disconnected = true }
        Task { @MainActor in runtime.clientDisconnected(sessionID) }
    }

    func perform(_ request: Data, reply: @escaping (Data) -> Void) {
        let box = ReplyBox(reply)
        guard request.count <= HarborProxyAgentConstants.messageLimit,
              let decoded = try? JSONDecoder().decode(HarborProxyAgentRequest.self, from: request) else {
            let response = HarborProxyAgentReply(errorCode: "INVALID_REQUEST")
            box.reply((try? JSONEncoder().encode(response)) ?? Data())
            return
        }
        Task { @MainActor in
            guard !stateLock.withLock({ disconnected }) else {
                box.reply((try? JSONEncoder().encode(HarborProxyAgentReply(errorCode: "DISCONNECTED"))) ?? Data())
                return
            }
            let result = await runtime.handle(decoded, peerPID: peerPID, sessionID: sessionID)
            box.reply((try? JSONEncoder().encode(result)) ?? Data())
        }
    }
}

package final class AgentListenerDelegate: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let runtime: HarborProxyAgentRuntime
    package init(runtime: HarborProxyAgentRuntime) { self.runtime = runtime }

    package func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier == getuid(), connection.processIdentifier > 1 else { return false }
        do {
            try HarborAgentSigningRequirement.authenticate(connection, identifier: HarborProxyAgentConstants.appIdentifier)
        } catch {
            return false
        }
        let id = UUID()
        let runtime = runtime
        connection.exportedInterface = NSXPCInterface(with: HarborProxyAgentRPC.self)
        let endpoint = AgentEndpoint(runtime: runtime, peerPID: connection.processIdentifier, sessionID: id)
        connection.exportedObject = endpoint
        connection.invalidationHandler = { endpoint.disconnect() }
        connection.interruptionHandler = { endpoint.disconnect() }
        connection.resume()
        return true
    }
}
