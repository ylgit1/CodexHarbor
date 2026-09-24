import Foundation

public struct BridgePipelineDiagnostics: Codable, Equatable, Sendable {
    public var nodes: [BridgeNodeDiagnostic]

    public init(nodes: [BridgeNodeDiagnostic] = []) {
        self.nodes = nodes
    }

    public var requiresFastRecoveryCheck: Bool {
        guard !nodes.isEmpty else { return true }
        return nodes.contains { node in
            switch node.state {
            case .connecting, .recovering, .failed:
                return true
            case .ready, .waiting:
                return false
            }
        }
    }

    public func node(_ id: String) -> BridgeNodeDiagnostic? {
        nodes.first { $0.id == id }
    }
}
