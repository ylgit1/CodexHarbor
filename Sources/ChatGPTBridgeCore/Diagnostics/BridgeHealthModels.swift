import Foundation

public enum BridgeNodeState: String, Codable, Equatable, Sendable {
    case ready
    case connecting
    case recovering
    case waiting
    case failed
}

public struct BridgeNodeDiagnostic: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let state: BridgeNodeState
    public let message: String
    public let lastCheckAt: Date?
    public let latency: Int?
    public let details: [String]

    public init(
        id: String,
        title: String,
        state: BridgeNodeState,
        message: String,
        lastCheckAt: Date? = nil,
        latency: Int? = nil,
        details: [String] = []
    ) {
        self.id = id
        self.title = title
        self.state = state
        self.message = message
        self.lastCheckAt = lastCheckAt
        self.latency = latency
        self.details = details
    }
}

public enum BridgeRuntimeKeyState: String, Codable, Equatable, Sendable {
    case notRequired
    case checking
    case valid
    case invalid
}

public struct BridgeServiceHealth: Codable, Equatable, Sendable {
    public var state: BridgeNodeState
    public var processIdentifier: Int32?
    public var message: String?

    public init(
        state: BridgeNodeState = .waiting,
        processIdentifier: Int32? = nil,
        message: String? = nil
    ) {
        self.state = state
        self.processIdentifier = processIdentifier
        self.message = message
    }
}

public struct BridgeTunnelHealth: Codable, Equatable, Sendable {
    public var process: BridgeServiceHealth
    public var runtimeKey: BridgeRuntimeKeyState
    public var controlPlane: BridgeNodeState
    public var endpoint: BridgeNodeState

    public init(
        process: BridgeServiceHealth = BridgeServiceHealth(),
        runtimeKey: BridgeRuntimeKeyState = .notRequired,
        controlPlane: BridgeNodeState = .waiting,
        endpoint: BridgeNodeState = .waiting
    ) {
        self.process = process
        self.runtimeKey = runtimeKey
        self.controlPlane = controlPlane
        self.endpoint = endpoint
    }
}

public struct BridgeHealthSnapshot: Codable, Equatable, Sendable {
    public var agent: BridgeServiceHealth
    public var mcp: BridgeServiceHealth
    public var tunnel: BridgeTunnelHealth

    public init(
        agent: BridgeServiceHealth = BridgeServiceHealth(),
        mcp: BridgeServiceHealth = BridgeServiceHealth(),
        tunnel: BridgeTunnelHealth = BridgeTunnelHealth()
    ) {
        self.agent = agent
        self.mcp = mcp
        self.tunnel = tunnel
    }
}
