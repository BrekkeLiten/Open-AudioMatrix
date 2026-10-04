import Foundation

/// Matrix layout metadata stored alongside routing session in show presets.
public struct MatrixPresetSnapshot: Codable, Equatable, Sendable {
    public var destinationOrder: [String]
    public var sourceOrder: [String]
    public var collapsedDestinationGroups: [String]
    public var collapsedSourceGroups: [String]
    public var sourceDisplayNames: [String: String]
    public var destinationDisplayNames: [String: String]
    public var destinationChannelCounts: [String: Int]

    public init(
        destinationOrder: [String] = [],
        sourceOrder: [String] = [],
        collapsedDestinationGroups: [String] = [],
        collapsedSourceGroups: [String] = [],
        sourceDisplayNames: [String: String] = [:],
        destinationDisplayNames: [String: String] = [:],
        destinationChannelCounts: [String: Int] = [:]
    ) {
        self.destinationOrder = destinationOrder
        self.sourceOrder = sourceOrder
        self.collapsedDestinationGroups = collapsedDestinationGroups
        self.collapsedSourceGroups = collapsedSourceGroups
        self.sourceDisplayNames = sourceDisplayNames
        self.destinationDisplayNames = destinationDisplayNames
        self.destinationChannelCounts = destinationChannelCounts
    }

    public static let empty = MatrixPresetSnapshot()
}
