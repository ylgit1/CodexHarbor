import Foundation

public enum HarborProxyAgentConstants {
    public static let label = "com.codexharbor.proxy-agent"
    public static let appIdentifier = "com.codexharbor.app"
    public static let protocolVersion = 1
    public static let messageLimit = 1_048_576

    public static var root: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CodexHarbor/NetworkProxy", isDirectory: true)
    }
    public static var journalURL: URL { root.appendingPathComponent("proxy-agent-journal.json") }
    public static var activeMarker: URL { root.appendingPathComponent("proxy-agent-active") }
}

public enum HarborProxyAgentEngineKind: String, Codable, Sendable { case xray, mihomo }

public struct HarborProxyAgentEngineRecord: Codable, Equatable, Sendable {
    public let id: UUID
    public let kind: HarborProxyAgentEngineKind
    public let port: Int
    public var identity: HarborProcessIdentity
    public let configurationPath: String
    public let configurationDigest: Data
    public let directoryPath: String
    public let dependencyIDs: Set<UUID>
    public let createdAt: Date
    public let promotedWARP: Bool

    public init(id: UUID, kind: HarborProxyAgentEngineKind, port: Int, identity: HarborProcessIdentity,
                configurationPath: String, configurationDigest: Data, directoryPath: String,
                dependencyIDs: Set<UUID>, createdAt: Date = .now, promotedWARP: Bool = false) {
        self.id = id
        self.kind = kind
        self.port = port
        self.identity = identity
        self.configurationPath = configurationPath
        self.configurationDigest = configurationDigest
        self.directoryPath = directoryPath
        self.dependencyIDs = dependencyIDs
        self.createdAt = createdAt
        self.promotedWARP = promotedWARP
    }
}

public struct HarborProxyAgentRoute: Codable, Equatable, Sendable {
    public let nodeID: String
    public let endpointSignature: String
    public let primaryID: UUID
    public let underlayID: UUID?
    public let underlayNodeID: String?
    public let warpEndpoint: HarborWARPEndpoint?
    public let ruleMode: Bool
    public let forcedDomains: [String]
    public let localHostAddresses: [String: [String]]
    public var observedExitIP: String?
    public let engines: [HarborProxyAgentEngineRecord]

    public init(nodeID: String, endpointSignature: String, primaryID: UUID, underlayID: UUID?,
                underlayNodeID: String?, warpEndpoint: HarborWARPEndpoint?, ruleMode: Bool,
                forcedDomains: [String], localHostAddresses: [String: [String]],
                observedExitIP: String?, engines: [HarborProxyAgentEngineRecord]) {
        self.nodeID = nodeID
        self.endpointSignature = endpointSignature
        self.primaryID = primaryID
        self.underlayID = underlayID
        self.underlayNodeID = underlayNodeID
        self.warpEndpoint = warpEndpoint
        self.ruleMode = ruleMode
        self.forcedDomains = forcedDomains
        self.localHostAddresses = localHostAddresses
        self.observedExitIP = observedExitIP
        self.engines = engines
    }
}

public struct HarborProxyAgentGatewaySnapshot: Codable, Sendable {
    public let port: Int
    public let ready: Bool
    public let route: HarborProxyAgentRoute?
    public let healthy: Bool
    public let lastHealth: Date?
    /// The persisted route is intent; this field reflects the live gateway.
    public let routingBackendID: UUID?
    public init(port: Int, ready: Bool, route: HarborProxyAgentRoute?, healthy: Bool, lastHealth: Date?,
                routingBackendID: UUID? = nil) {
        self.port = port
        self.ready = ready
        self.route = route
        self.healthy = healthy
        self.lastHealth = lastHealth
        self.routingBackendID = routingBackendID
    }
}

public struct HarborProxyAgentSnapshot: Codable, Sendable {
    public let version: Int
    public let gateways: [HarborProxyAgentGatewaySnapshot]
    public let engines: [HarborProxyAgentEngineRecord]
    public let pendingLaunchPorts: [UUID: Int]?
    public let operationInProgress: Bool?
    public init(gateways: [HarborProxyAgentGatewaySnapshot], engines: [HarborProxyAgentEngineRecord],
                pendingLaunchPorts: [UUID: Int] = [:], operationInProgress: Bool = false) {
        self.version = HarborProxyAgentConstants.protocolVersion
        self.gateways = gateways
        self.engines = engines
        self.pendingLaunchPorts = pendingLaunchPorts
        self.operationInProgress = operationInProgress
    }
}

/// Short-lived, in-memory authorization for detached recovery. Never put
/// candidate credentials into the resident journal. Only the authenticated
/// UI may grant it, and a new UI session or network change revokes it.
public struct HarborDetachedFallbackGrant: Codable, Sendable {
    public let primaryID: UUID
    public let sourceNode: HarborProxyNode
    public let sourceEvidence: HarborProxyNetworkEvidence
    public let candidates: [HarborProxyNode]
    public let underlayNode: HarborProxyNode?
    public let warpAccount: HarborWARPAccount?

    public init(primaryID: UUID, sourceNode: HarborProxyNode, sourceEvidence: HarborProxyNetworkEvidence,
                candidates: [HarborProxyNode], underlayNode: HarborProxyNode? = nil,
                warpAccount: HarborWARPAccount? = nil) {
        self.primaryID = primaryID
        self.sourceNode = sourceNode
        self.sourceEvidence = sourceEvidence
        self.candidates = candidates
        self.underlayNode = underlayNode
        self.warpAccount = warpAccount
    }
}

public enum HarborProxyAgentCommand: Codable, Sendable {
    case inspect
    case heartbeat
    case grantDetachedFallback(HarborDetachedFallbackGrant?)
    case openGateway(port: Int)
    case startEngine(id: UUID, kind: HarborProxyAgentEngineKind, port: Int, configuration: Data, dependencies: Set<UUID>)
    case commit(port: Int, route: HarborProxyAgentRoute, closeOld: Bool)
    case recordExit(port: Int, backendID: UUID, ip: String)
    case suspend(port: Int, closeExisting: Bool)
    case connectionCount(port: Int, backendID: UUID)
    case closeConnections(port: Int, backendID: UUID)
    case stopGateway(port: Int)
    case stopEngine(id: UUID)
}

public struct HarborProxyAgentRequest: Codable, Sendable {
    public let version: Int
    public let command: HarborProxyAgentCommand
    public init(_ command: HarborProxyAgentCommand) {
        self.version = HarborProxyAgentConstants.protocolVersion
        self.command = command
    }
}

public struct HarborProxyAgentReply: Codable, Sendable {
    public let errorCode: String?
    public let snapshot: HarborProxyAgentSnapshot?
    public let count: Int?
    public init(errorCode: String? = nil, snapshot: HarborProxyAgentSnapshot? = nil, count: Int? = nil) {
        self.errorCode = errorCode
        self.snapshot = snapshot
        self.count = count
    }
}

@objc public protocol HarborProxyAgentRPC {
    func perform(_ request: Data, reply: @escaping (Data) -> Void)
}
