import Foundation

public enum RoutingGraphCompiler {
  public static func compileConnections(_ graph: RoutingGraphDocument) throws -> [SourceRoute] {
    var routes: [SourceRoute] = []
    var routeKeys = Set<String>()

    for connection in graph.connections {
      guard let sourceNode = graph.nodes.first(where: { $0.id == connection.sourceNodeID }),
            case .applicationInput(let bundleID, _) = sourceNode.kind else {
        throw RoutingGraphCompilerError.invalidConnection(connection.id)
      }
      guard let targetNode = graph.nodes.first(where: { $0.id == connection.targetNodeID }),
            case .deviceOutput(let deviceUID, _, let channelCount) = targetNode.kind else {
        throw RoutingGraphCompilerError.invalidConnection(connection.id)
      }

      let parentBundle = BundleIDMatcher.parentBundleID(of: bundleID)
      let routeKey = "\(parentBundle)|\(deviceUID)|s\(connection.sourceChannel)|o\(connection.outputChannel)"
      if routeKeys.contains(routeKey) {
        throw RoutingGraphCompilerError.duplicateRoute(
          bundleID,
          deviceUID,
          connection.sourceChannel,
          connection.outputChannel
        )
      }
      routeKeys.insert(routeKey)

      let router = ChannelRouter(channelCount: channelCount)
      let sourceChannelCount = max(connection.sourceChannel, channelCount, 16)
      try router.validateAssignment(
        sourceChannel: connection.sourceChannel,
        outputChannel: connection.outputChannel,
        sourceChannelCount: sourceChannelCount,
        bundleID: bundleID,
        sources: routes,
        outputDeviceUID: deviceUID,
        outputChannelCount: channelCount
      )

      routes.append(SourceRoute(
        bundleID: bundleID,
        outputDeviceUID: deviceUID,
        sourceChannel: connection.sourceChannel,
        outputChannel: connection.outputChannel
      ))
    }

    return routes
  }

  public static func routesEqual(_ lhs: [SourceRoute], _ rhs: [SourceRoute]) -> Bool {
    func signature(_ routes: [SourceRoute]) -> Set<String> {
      Set(routes.filter(\.enabled).map(MatrixRouteCodec.routeKey(for:)))
    }
    return signature(lhs) == signature(rhs)
  }

  public static func syncGraph(
    from session: RoutingSession,
    devices: [OutputDeviceInfo]
  ) -> RoutingGraphDocument {
    if let graph = session.graph, !graph.nodes.isEmpty {
      return graph
    }
    return rebuildGraph(from: session.sources, devices: devices)
  }

  public static func rebuildGraph(
    from sources: [SourceRoute],
    devices: [OutputDeviceInfo]
  ) -> RoutingGraphDocument {
    var nodes: [GraphNode] = []
    var connections: [GraphConnection] = []
    var deviceNodeIDs: [String: UUID] = [:]
    var appIndex = 0
    var deviceIndex = 0

    for source in sources where source.enabled {
      let deviceKey = source.outputDeviceUID
      let deviceNodeID: UUID
      if let existing = deviceNodeIDs[deviceKey] {
        deviceNodeID = existing
      } else {
        let device = devices.first { $0.uid == deviceKey }
        let name = device?.name ?? deviceKey
        let channelCount = device?.outputChannelCount ?? 2
        let node = GraphNode(
          kind: .deviceOutput(
            deviceUID: deviceKey,
            displayName: name,
            channelCount: channelCount
          ),
          position: GraphPoint(x: 420, y: 80 + Double(deviceIndex) * 180)
        )
        deviceNodeID = node.id
        deviceNodeIDs[deviceKey] = deviceNodeID
        nodes.append(node)
        deviceIndex += 1
      }

      let appNode = GraphNode(
        kind: .applicationInput(bundleID: source.bundleID, displayName: source.bundleID),
        position: GraphPoint(x: 80, y: 80 + Double(appIndex) * 100)
      )
      nodes.append(appNode)
      connections.append(GraphConnection(
        sourceNodeID: appNode.id,
        targetNodeID: deviceNodeID,
        sourceChannel: source.sourceChannel,
        outputChannel: source.outputChannel
      ))
      appIndex += 1
    }

    return RoutingGraphDocument(nodes: nodes, connections: connections)
  }

  public static func connection(
    forBundleID bundleID: String,
    in graph: RoutingGraphDocument
  ) -> GraphConnection? {
    let parent = BundleIDMatcher.parentBundleID(of: bundleID)
    for connection in graph.connections {
      guard let node = graph.nodes.first(where: { $0.id == connection.sourceNodeID }),
            case .applicationInput(let candidate, _) = node.kind,
            BundleIDMatcher.parentBundleID(of: candidate) == parent else {
        continue
      }
      return connection
    }
    return nil
  }

  public static func applicationNode(
    forBundleID bundleID: String,
    in graph: RoutingGraphDocument
  ) -> GraphNode? {
    let parent = BundleIDMatcher.parentBundleID(of: bundleID)
    return graph.nodes.first {
      guard case .applicationInput(let candidate, _) = $0.kind else { return false }
      return BundleIDMatcher.parentBundleID(of: candidate) == parent
    }
  }

  public static func connectionsFromSession(
    _ session: RoutingSession,
    nodes: [GraphNode]
  ) -> [GraphConnection] {
    var connections: [GraphConnection] = []
    for source in session.sources where source.enabled {
      let partialGraph = RoutingGraphDocument(nodes: nodes, connections: [])
      guard let appNode = applicationNode(forBundleID: source.bundleID, in: partialGraph),
            let deviceNode = nodes.first(where: {
              guard case .deviceOutput(let uid, _, _) = $0.kind else { return false }
              return uid == source.outputDeviceUID
            }) else {
        continue
      }
      connections.append(GraphConnection(
        sourceNodeID: appNode.id,
        targetNodeID: deviceNode.id,
        sourceChannel: source.sourceChannel,
        outputChannel: source.outputChannel
      ))
    }
    return connections
  }
}

public enum RoutingGraphCompilerError: Error, CustomStringConvertible {
  case invalidConnection(UUID)
  case duplicateApplication(String)
  case duplicateRoute(String, String, Int, Int)

  public var description: String {
    switch self {
    case .invalidConnection(let id):
      "Invalid graph connection \(id.uuidString)"
    case .duplicateApplication(let bundleID):
      "Application \(bundleID) is connected more than once"
    case .duplicateRoute(let bundleID, let deviceUID, let sourceChannel, let outputChannel):
      "Duplicate route for \(bundleID) → \(deviceUID) src \(sourceChannel) out \(outputChannel)"
    }
  }
}
