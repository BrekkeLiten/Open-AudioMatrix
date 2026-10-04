import AudioMatrixCore
import Foundation

enum MatrixHoverHighlight {
    static func isRowHighlighted(
        hovered: RouteKey?,
        deviceUID: String,
        monoChannel: Int?
    ) -> Bool {
        guard let hovered,
              let destination = MatrixRouteCodec.parseDestination(hovered.destinationId) else { return false }
        guard destination.deviceUID == deviceUID else { return false }
        if let monoChannel {
            return monoChannel == destination.monoChannel
        }
        return true
    }

    static func isColumnHighlighted(
        hovered: RouteKey?,
        bundleID: String,
        monoChannel: Int?
    ) -> Bool {
        guard let hovered,
              let source = MatrixRouteCodec.parseSource(hovered.sourceId) else { return false }
        let parent = BundleIDMatcher.parentBundleID(of: source.bundleID)
        guard parent == bundleID else { return false }
        if let monoChannel {
            return monoChannel == source.monoChannel
        }
        return true
    }
}
