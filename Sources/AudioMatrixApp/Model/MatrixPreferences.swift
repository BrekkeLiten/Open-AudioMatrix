import Foundation
import AudioMatrixCore

struct MatrixPreferences: Codable, Equatable {
    var destinationOrder: [String] = []
    var sourceOrder: [String] = []
    /// Groups the user explicitly collapsed. Everything else defaults to expanded.
    var collapsedDestinationGroups: [String] = []
    var collapsedSourceGroups: [String] = []
    var savedRoutes: [SourceRoute] = []
    var mutedRouteKeys: [RouteKey] = []
    var sourceDisplayNames: [String: String] = [:]
    var destinationDisplayNames: [String: String] = [:]
    var destinationChannelCounts: [String: Int] = [:]
    /// Explicitly removed from the matrix; not re-added while routes remain.
    var hiddenSourceIDs: [String] = []
    var hiddenDestinationUIDs: [String] = []
    /// Legacy — migrated to collapsed sets on load.
    var expandedDestinationGroups: [String]?
    var expandedSourceGroups: [String]?

    private static let storageKey = "io.github.brekkeliten.openaudiomatrix.matrixPreferences"

    static func load() -> MatrixPreferences {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let prefs = try? JSONDecoder().decode(MatrixPreferences.self, from: data) else {
            return MatrixPreferences()
        }
        return prefs
    }

    static var hasPersistedPreferences: Bool {
        UserDefaults.standard.data(forKey: storageKey) != nil
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    func matrixSnapshot() -> MatrixPresetSnapshot {
        MatrixPresetSnapshot(
            destinationOrder: destinationOrder,
            sourceOrder: sourceOrder,
            collapsedDestinationGroups: collapsedDestinationGroups,
            collapsedSourceGroups: collapsedSourceGroups,
            sourceDisplayNames: sourceDisplayNames,
            destinationDisplayNames: destinationDisplayNames,
            destinationChannelCounts: destinationChannelCounts
        )
    }

    static func from(snapshot: MatrixPresetSnapshot, savedRoutes: [SourceRoute], mutedRouteKeys: [RouteKey]) -> MatrixPreferences {
        MatrixPreferences(
            destinationOrder: snapshot.destinationOrder,
            sourceOrder: snapshot.sourceOrder,
            collapsedDestinationGroups: snapshot.collapsedDestinationGroups,
            collapsedSourceGroups: snapshot.collapsedSourceGroups,
            savedRoutes: savedRoutes,
            mutedRouteKeys: mutedRouteKeys,
            sourceDisplayNames: snapshot.sourceDisplayNames,
            destinationDisplayNames: snapshot.destinationDisplayNames,
            destinationChannelCounts: snapshot.destinationChannelCounts
        )
    }
}
