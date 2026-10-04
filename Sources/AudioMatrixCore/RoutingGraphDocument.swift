import Foundation

public struct GraphPoint: Codable, Sendable, Hashable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public enum GraphNodeKind: Codable, Sendable, Hashable {
    case applicationInput(bundleID: String, displayName: String)
    case deviceOutput(deviceUID: String, displayName: String, channelCount: Int)
}

public struct GraphNode: Codable, Identifiable, Sendable, Hashable {
    public var id: UUID
    public var kind: GraphNodeKind
    public var position: GraphPoint

    public init(id: UUID = UUID(), kind: GraphNodeKind, position: GraphPoint) {
        self.id = id
        self.kind = kind
        self.position = position
    }
}

public struct GraphConnection: Codable, Identifiable, Sendable, Hashable {
    public var id: UUID
    public var sourceNodeID: UUID
    public var targetNodeID: UUID
    public var sourceChannel: Int
    public var outputChannel: Int

    public init(
        id: UUID = UUID(),
        sourceNodeID: UUID,
        targetNodeID: UUID,
        sourceChannel: Int,
        outputChannel: Int
    ) {
        self.id = id
        self.sourceNodeID = sourceNodeID
        self.targetNodeID = targetNodeID
        self.sourceChannel = sourceChannel
        self.outputChannel = outputChannel
    }

    private enum CodingKeys: String, CodingKey {
        case id, sourceNodeID, targetNodeID, sourceChannel, outputChannel, channelStart
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        sourceNodeID = try container.decode(UUID.self, forKey: .sourceNodeID)
        targetNodeID = try container.decode(UUID.self, forKey: .targetNodeID)
        if let sourceChannel = try container.decodeIfPresent(Int.self, forKey: .sourceChannel),
           let outputChannel = try container.decodeIfPresent(Int.self, forKey: .outputChannel) {
            self.sourceChannel = sourceChannel
            self.outputChannel = outputChannel
        } else {
            let legacy = try container.decode(Int.self, forKey: .channelStart)
            sourceChannel = legacy
            outputChannel = legacy
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(sourceNodeID, forKey: .sourceNodeID)
        try container.encode(targetNodeID, forKey: .targetNodeID)
        try container.encode(sourceChannel, forKey: .sourceChannel)
        try container.encode(outputChannel, forKey: .outputChannel)
    }
}

public struct RoutingGraphDocument: Codable, Sendable, Hashable {
    public var nodes: [GraphNode]
    public var connections: [GraphConnection]

    public init(nodes: [GraphNode] = [], connections: [GraphConnection] = []) {
        self.nodes = nodes
        self.connections = connections
    }
}
