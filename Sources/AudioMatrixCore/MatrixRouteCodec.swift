import Foundation

public struct RouteKey: Hashable, Sendable, Codable {
    public let sourceId: String
    public let destinationId: String

    public init(sourceId: String, destinationId: String) {
        self.sourceId = sourceId
        self.destinationId = destinationId
    }
}

public enum MatrixRouteCodec {
    private static let channelSuffix = "-Ch"

    public static func sourceId(bundleID: String, monoChannel: Int) -> String {
        "\(bundleID)\(channelSuffix)\(monoChannel)"
    }

    public static func destinationId(deviceUID: String, monoChannel: Int) -> String {
        "\(deviceUID)\(channelSuffix)\(monoChannel)"
    }

    public static func parseSource(_ id: String) -> (bundleID: String, monoChannel: Int)? {
        guard let parsed = parse(id) else { return nil }
        return (bundleID: parsed.identifier, monoChannel: parsed.monoChannel)
    }

    public static func parseDestination(_ id: String) -> (deviceUID: String, monoChannel: Int)? {
        guard let parsed = parse(id) else { return nil }
        return (deviceUID: parsed.identifier, monoChannel: parsed.monoChannel)
    }

    public static func engineRoute(
        sourceId: String,
        destinationId: String
    ) -> (bundleID: String, deviceUID: String, sourceChannel: Int, outputChannel: Int)? {
        guard let source = parseSource(sourceId),
              let destination = parseDestination(destinationId) else {
            return nil
        }
        return (
            bundleID: source.bundleID,
            deviceUID: destination.deviceUID,
            sourceChannel: source.monoChannel,
            outputChannel: destination.monoChannel
        )
    }

    public static func engineRouteKey(
        bundleID: String,
        deviceUID: String,
        sourceChannel: Int,
        outputChannel: Int
    ) -> String {
        let parent = BundleIDMatcher.parentBundleID(of: bundleID)
        return "\(parent)|\(deviceUID)|s\(sourceChannel)|o\(outputChannel)"
    }

    public static func routeKey(for route: SourceRoute) -> String {
        engineRouteKey(
            bundleID: route.bundleID,
            deviceUID: route.outputDeviceUID,
            sourceChannel: route.sourceChannel,
            outputChannel: route.outputChannel
        )
    }

    /// Single mono cross-point for an active route.
    public static func diagonalRouteKeys(
        bundleID: String,
        deviceUID: String,
        sourceChannel: Int,
        outputChannel: Int
    ) -> [RouteKey] {
        [
            RouteKey(
                sourceId: sourceId(bundleID: bundleID, monoChannel: sourceChannel),
                destinationId: destinationId(deviceUID: deviceUID, monoChannel: outputChannel)
            )
        ]
    }

    public static func diagonalPatchEngineRoutes(
        sourceBundleID: String,
        destinationDeviceUID: String,
        sourceMonoChannels: [Int],
        destinationMonoChannels: [Int]
    ) -> [(bundleID: String, deviceUID: String, sourceChannel: Int, outputChannel: Int)] {
        let count = min(sourceMonoChannels.count, destinationMonoChannels.count)
        var seen = Set<String>()
        var routes: [(bundleID: String, deviceUID: String, sourceChannel: Int, outputChannel: Int)] = []

        for index in 0..<count {
            let sourceChannel = sourceMonoChannels[index]
            let outputChannel = destinationMonoChannels[index]
            let key = engineRouteKey(
                bundleID: sourceBundleID,
                deviceUID: destinationDeviceUID,
                sourceChannel: sourceChannel,
                outputChannel: outputChannel
            )
            guard seen.insert(key).inserted else { continue }
            routes.append((sourceBundleID, destinationDeviceUID, sourceChannel, outputChannel))
        }
        return routes
    }

    /// Slices channel lists to begin at the anchor crosspoint. When `maxPairs` is set
    /// (e.g. 2 for shift-click stereo), only that many parallel routes are returned.
    public static func diagonalPatchChannels(
        sourceMonoChannels: [Int],
        destinationMonoChannels: [Int],
        anchorSourceChannel: Int,
        anchorDestinationChannel: Int,
        maxPairs: Int? = nil
    ) -> (source: [Int], destination: [Int]) {
        guard let sourceStart = sourceMonoChannels.firstIndex(of: anchorSourceChannel),
              let destinationStart = destinationMonoChannels.firstIndex(of: anchorDestinationChannel) else {
            return ([], [])
        }

        var source = Array(sourceMonoChannels[sourceStart...])
        var destination = Array(destinationMonoChannels[destinationStart...])
        let pairCount = min(source.count, destination.count)
        source = Array(source.prefix(pairCount))
        destination = Array(destination.prefix(pairCount))

        if let maxPairs, maxPairs > 0 {
            source = Array(source.prefix(maxPairs))
            destination = Array(destination.prefix(maxPairs))
        }

        return (source, destination)
    }

    private static func parse(_ id: String) -> (identifier: String, monoChannel: Int)? {
        guard let range = id.range(of: channelSuffix, options: .backwards) else { return nil }
        let identifier = String(id[..<range.lowerBound])
        guard !identifier.isEmpty,
              let monoChannel = Int(id[range.upperBound...]),
              monoChannel >= 1 else {
            return nil
        }
        return (identifier, monoChannel)
    }
}
