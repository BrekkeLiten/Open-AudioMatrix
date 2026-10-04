import AudioMatrixCore
import Foundation

func expect(_ condition: Bool, _ message: String) {
    if !condition {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

let parent = BundleIDMatcher.parentBundleID(of: "com.google.Chrome.helper")
expect(parent == "com.google.Chrome", "parent bundle ID")

let router = ChannelRouter(channelCount: 16)
var output = [Float](repeating: 0, count: 16)
let source: [Float] = [1, 2, 3, 4, 5, 6]
source.withUnsafeBufferPointer { src in
    router.mixMonoChannel(
        src.baseAddress!,
        frameCount: 1,
        sourceChannels: 6,
        sourceChannel: 3,
        outputChannel: 3,
        into: output.withUnsafeMutableBufferPointer { $0.baseAddress! }
    )
}
expect(output[2] == 3, "mono channel routing")

do {
    try router.validateAssignment(
        sourceChannel: 0,
        outputChannel: 1,
        sourceChannelCount: 6,
        bundleID: "com.apple.Safari",
        sources: [],
        outputDeviceUID: "device-a",
        outputChannelCount: 16
    )
    fputs("FAIL: invalid channel should throw\n", stderr)
    exit(1)
} catch {
    // expected
}

let multiDeviceSources = [
    SourceRoute(bundleID: "com.spotify.client", outputDeviceUID: "device-a", sourceChannel: 1, outputChannel: 1),
]
do {
    try router.validateAssignment(
        sourceChannel: 1,
        outputChannel: 1,
        sourceChannelCount: 6,
        bundleID: "com.apple.Safari",
        sources: multiDeviceSources,
        outputDeviceUID: "device-b",
        outputChannelCount: 16
    )
} catch {
    fputs("FAIL: same channel on different devices should be allowed\n", stderr)
    exit(1)
}

do {
    try router.validateAssignment(
        sourceChannel: 2,
        outputChannel: 2,
        sourceChannelCount: 6,
        bundleID: "com.apple.Safari",
        sources: multiDeviceSources,
        outputDeviceUID: "device-a",
        outputChannelCount: 16
    )
} catch {
    fputs("FAIL: multiple apps on same channel should be allowed\n", stderr)
    exit(1)
}

var mixSamePort = [Float](repeating: 0, count: 8)
let spotify: [Float] = [0.5, 0.6]
let safari: [Float] = [0.7, 0.8]
let routerSamePort = ChannelRouter(channelCount: 8)
spotify.withUnsafeBufferPointer { ptr in
    routerSamePort.mixMonoChannel(
        ptr.baseAddress!, frameCount: 1, sourceChannels: 2, sourceChannel: 1, outputChannel: 1,
        into: mixSamePort.withUnsafeMutableBufferPointer { $0.baseAddress! }
    )
}
safari.withUnsafeBufferPointer { ptr in
    routerSamePort.mixMonoChannel(
        ptr.baseAddress!, frameCount: 1, sourceChannels: 2, sourceChannel: 1, outputChannel: 1,
        into: mixSamePort.withUnsafeMutableBufferPointer { $0.baseAddress! }
    )
}
expect(abs(mixSamePort[0] - 1.2) < 0.001, "mixed mono sources same port")

let router8 = ChannelRouter(channelCount: 8)
var mix8 = [Float](repeating: 0, count: 8)
spotify.withUnsafeBufferPointer { ptr in
    router8.mixMonoChannel(
        ptr.baseAddress!, frameCount: 1, sourceChannels: 2, sourceChannel: 1, outputChannel: 1,
        into: mix8.withUnsafeMutableBufferPointer { $0.baseAddress! }
    )
}
safari.withUnsafeBufferPointer { ptr in
    router8.mixMonoChannel(
        ptr.baseAddress!, frameCount: 1, sourceChannels: 2, sourceChannel: 2, outputChannel: 5,
        into: mix8.withUnsafeMutableBufferPointer { $0.baseAddress! }
    )
}
expect(mix8[0] == 0.5 && mix8[4] == 0.8, "mono routes to different outputs")

let session = RoutingSession(sources: [
    SourceRoute(bundleID: "com.spotify.client", outputDeviceUID: "test-device", sourceChannel: 1, outputChannel: 1),
])
let data = try JSONEncoder().encode(session)
let decoded = try JSONDecoder().decode(RoutingSession.self, from: data)
expect(decoded.sources.first?.bundleID == "com.spotify.client", "codable session")

let labeled = RoutingSession(
    sources: [],
    channelLabels: [RoutingSession.channelLabelKey(deviceUID: "uid", channelStart: 1): "House L/R"]
)
expect(labeled.channelLabel(deviceUID: "uid", channelStart: 1) == "House L/R", "channel labels")

var graph = RoutingGraphDocument(
    nodes: [
        GraphNode(
            kind: .applicationInput(bundleID: "com.spotify.client", displayName: "Spotify"),
            position: GraphPoint(x: 0, y: 0)
        ),
        GraphNode(
            kind: .deviceOutput(deviceUID: "device-a", displayName: "Interface", channelCount: 8),
            position: GraphPoint(x: 200, y: 0)
        ),
    ],
    connections: []
)
let appNodeID = graph.nodes[0].id
let deviceNodeID = graph.nodes[1].id
graph.connections.append(GraphConnection(
    sourceNodeID: appNodeID,
    targetNodeID: deviceNodeID,
    sourceChannel: 2,
    outputChannel: 4
))
let compiled: [SourceRoute]
do {
    compiled = try RoutingGraphCompiler.compileConnections(graph)
} catch {
    fputs("FAIL: graph compile \(error)\n", stderr)
    exit(1)
}
expect(compiled.count == 1, "compiled route count")
expect(compiled[0].sourceChannel == 2, "compiled source channel")
expect(compiled[0].outputChannel == 4, "compiled output channel")

let legacySession = RoutingSession(sources: [
    SourceRoute(bundleID: "com.apple.Safari", outputDeviceUID: "device-a", channelStart: 3),
])
let devices = [OutputDeviceInfo(uid: "device-a", name: "Interface", outputChannelCount: 8, isDefault: true)]
let rebuilt = RoutingGraphCompiler.syncGraph(from: legacySession, devices: devices)
expect(!rebuilt.nodes.isEmpty, "rebuilt graph nodes")
expect(rebuilt.connections.count == 1, "rebuilt connection")
expect(rebuilt.connections[0].outputChannel == 3, "rebuilt output channel")

let catalog = SourceCatalogBuilder.build(from: [
    AudioProcessInfo(
        bundleID: "com.spotify.client",
        pid: 1,
        name: "Spotify",
        isRunningOutput: true,
        isRunningInput: false
    ),
])
let catalogResponse = EngineResponse(
    ok: true,
    message: "ok",
    processes: [],
    sourceCatalog: catalog,
    running: false
)
let catalogData = try JSONEncoder().encode(catalogResponse)
let catalogDecoded = try JSONDecoder().decode(EngineResponse.self, from: catalogData)
expect(catalogDecoded.sourceCatalog?.playing.first?.name == "Spotify", "catalog codable")

print("CoreSelfTest passed")
