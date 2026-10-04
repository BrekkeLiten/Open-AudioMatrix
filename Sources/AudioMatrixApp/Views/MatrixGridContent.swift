import AudioMatrixCore
import SwiftUI

/// Scrollable crosspoint grid backed by a single `Canvas` for large matrices.
struct MatrixGridContent: View {
    let gridRows: [MatrixGridRowLayout]
    let gridWidth: CGFloat
    let gridHeight: CGFloat
    let connections: [RouteKey: Bool]
    let mutedRoutes: Set<RouteKey>
    let hoveredCrosspoint: RouteKey?
    let activeSourceGroups: Set<String>
    let unavailableSourceGroups: Set<String>
    let unavailableDestinationGroups: Set<String>
    let isCrosspointConnected: (RouteKey) -> Bool
    let onToggleCrosspoint: (RouteKey, EventModifiers) -> Void
    let onCommitDiagonalDrag: ([RouteKey], Bool) -> Void
    let onHoverChange: (RouteKey, Bool) -> Void
    let onExpandSource: (String) -> Void

    var body: some View {
        MatrixGridCanvas(
            state: MatrixGridRenderState(
                rows: gridRows,
                gridWidth: gridWidth,
                gridHeight: gridHeight,
                connections: connections,
                mutedRoutes: mutedRoutes,
                hoveredCrosspoint: hoveredCrosspoint,
                activeSourceGroups: activeSourceGroups,
                unavailableSourceGroups: unavailableSourceGroups,
                unavailableDestinationGroups: unavailableDestinationGroups
            ),
            isCrosspointConnected: isCrosspointConnected,
            onToggleCrosspoint: onToggleCrosspoint,
            onCommitDiagonalDrag: onCommitDiagonalDrag,
            onHoverChange: onHoverChange,
            onExpandSource: onExpandSource
        )
    }
}
