import AudioMatrixCore
import SwiftUI

struct MatrixGridRenderState: Equatable {
    var rows: [MatrixGridRowLayout]
    var gridWidth: CGFloat
    var gridHeight: CGFloat
    var connections: [RouteKey: Bool]
    var mutedRoutes: Set<RouteKey>
    var hoveredCrosspoint: RouteKey?
    var diagonalDragPreview: Set<RouteKey> = []
    var activeSourceGroups: Set<String>
    var unavailableSourceGroups: Set<String>
    var unavailableDestinationGroups: Set<String>
}

private struct DiagonalDragSession: Equatable {
    let anchorColumn: Int
    let anchorRow: Int
    let anchorKey: RouteKey
    let targetConnected: Bool
    var previewKeys: Set<RouteKey>
}

/// GPU-drawn crosspoint grid — one view instead of thousands of `Button` cells.
struct MatrixGridCanvas: View {
    let state: MatrixGridRenderState
    let isCrosspointConnected: (RouteKey) -> Bool
    let onToggleCrosspoint: (RouteKey, EventModifiers) -> Void
    let onCommitDiagonalDrag: ([RouteKey], Bool) -> Void
    let onHoverChange: (RouteKey, Bool) -> Void
    let onExpandSource: (String) -> Void

    @State private var lastHoveredKey: RouteKey?
    @State private var diagonalDrag: DiagonalDragSession?
    @State private var ignoreNextTap = false
    @FocusState private var isFocused: Bool

    private var renderState: MatrixGridRenderState {
        var copy = state
        copy.diagonalDragPreview = diagonalDrag?.previewKeys ?? []
        return copy
    }

    var body: some View {
        MatrixGridCanvasBody(state: renderState)
            .equatable()
            .frame(width: state.gridWidth, height: state.gridHeight, alignment: .topLeading)
            .contentShape(Rectangle())
            .focusable()
            .focused($isFocused)
            .focusEffectDisabled()
            .onAppear { isFocused = true }
            .onKeyPress(.escape) {
                cancelDiagonalDrag()
                return .handled
            }
            .highPriorityGesture(shiftClickGesture)
            .highPriorityGesture(optionClickGesture)
            .highPriorityGesture(diagonalDragGesture)
            .gesture(plainClickGesture)
            .onContinuousHover { phase in
                guard diagonalDrag == nil else { return }
                switch phase {
                case .active(let location):
                    let key = hoverKey(at: location)
                    guard key != lastHoveredKey else { return }
                    if let lastHoveredKey {
                        onHoverChange(lastHoveredKey, false)
                    }
                    lastHoveredKey = key
                    if let key {
                        onHoverChange(key, true)
                    }
                case .ended:
                    if let lastHoveredKey {
                        onHoverChange(lastHoveredKey, false)
                    }
                    lastHoveredKey = nil
                }
            }
    }

    private var diagonalDragGesture: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .local)
            .onChanged { value in
                handleDiagonalDragChanged(value)
            }
            .onEnded { value in
                handleDiagonalDragEnded(value)
            }
    }

    private var shiftClickGesture: some Gesture {
        SpatialTapGesture(coordinateSpace: .local)
            .modifiers(.shift)
            .onEnded { value in
                handleTap(at: value.location, modifiers: .shift)
            }
    }

    private var optionClickGesture: some Gesture {
        SpatialTapGesture(coordinateSpace: .local)
            .modifiers(.option)
            .onEnded { value in
                handleTap(at: value.location, modifiers: .option)
            }
    }

    private var plainClickGesture: some Gesture {
        SpatialTapGesture(coordinateSpace: .local)
            .onEnded { value in
                guard !ignoreNextTap else { return }
                handleTap(at: value.location, modifiers: [])
            }
    }

    private func handleDiagonalDragChanged(_ value: DragGesture.Value) {
        if diagonalDrag == nil {
            guard let hit = MatrixGridLayoutBuilder.crosspointHit(
                at: value.startLocation,
                in: state.rows
            ), case .crosspoint(let anchorKey) = hit.kind else {
                return
            }
            guard isCrosspointInteractive(anchorKey) else { return }

            let previewKeys = Set(
                MatrixGridLayoutBuilder.diagonalCrosspointKeys(
                    from: (gridColumn: hit.gridColumn, gridRow: hit.gridRow),
                    to: (gridColumn: hit.gridColumn, gridRow: hit.gridRow),
                    in: state.rows
                )
            )
            diagonalDrag = DiagonalDragSession(
                anchorColumn: hit.gridColumn,
                anchorRow: hit.gridRow,
                anchorKey: anchorKey,
                targetConnected: !isCrosspointConnected(anchorKey),
                previewKeys: previewKeys
            )
            if let lastHoveredKey {
                onHoverChange(lastHoveredKey, false)
                self.lastHoveredKey = nil
            }
        }

        guard var session = diagonalDrag else { return }
        let currentColumn: Int
        let currentRow: Int
        if let hit = MatrixGridLayoutBuilder.crosspointHit(at: value.location, in: state.rows) {
            currentColumn = hit.gridColumn
            currentRow = hit.gridRow
        } else {
            currentColumn = MatrixGridLayoutBuilder.gridColumnIndex(forMinX: value.location.x)
            currentRow = MatrixGridLayoutBuilder.gridRowIndex(forMinY: value.location.y)
        }

        let keys = MatrixGridLayoutBuilder.diagonalCrosspointKeys(
            from: (gridColumn: session.anchorColumn, gridRow: session.anchorRow),
            to: (gridColumn: currentColumn, gridRow: currentRow),
            in: state.rows
        )
        session.previewKeys = Set(keys.filter(isCrosspointInteractive))
        diagonalDrag = session
    }

    private func handleDiagonalDragEnded(_ value: DragGesture.Value) {
        defer {
            ignoreNextTap = true
            DispatchQueue.main.async {
                ignoreNextTap = false
            }
        }

        guard let session = diagonalDrag else { return }
        diagonalDrag = nil

        let keys = session.previewKeys.sorted {
            $0.sourceId + $0.destinationId < $1.sourceId + $1.destinationId
        }
        guard !keys.isEmpty else { return }
        onCommitDiagonalDrag(keys, session.targetConnected)
    }

    private func cancelDiagonalDrag() {
        guard diagonalDrag != nil else { return }
        diagonalDrag = nil
    }

    private func handleTap(at location: CGPoint, modifiers: EventModifiers) {
        guard diagonalDrag == nil else { return }
        guard let kind = MatrixGridLayoutBuilder.hitTest(at: location, in: state.rows) else { return }
        switch kind {
        case .crosspoint(let key):
            guard isCrosspointInteractive(key) else { return }
            onToggleCrosspoint(key, modifiers)
        case .expandSource(let groupID):
            onExpandSource(groupID)
        }
    }

    private func hoverKey(at location: CGPoint) -> RouteKey? {
        guard let hit = MatrixGridLayoutBuilder.crosspointHit(at: location, in: state.rows),
              case .crosspoint(let key) = hit.kind else {
            return nil
        }
        return key
    }

    private func isCrosspointInteractive(_ key: RouteKey) -> Bool {
        guard let source = MatrixRouteCodec.parseSource(key.sourceId),
              let destination = MatrixRouteCodec.parseDestination(key.destinationId) else {
            return false
        }
        let sourceParent = BundleIDMatcher.parentBundleID(of: source.bundleID)
        return !state.unavailableSourceGroups.contains(sourceParent)
            && !state.unavailableDestinationGroups.contains(destination.deviceUID)
    }
}

private struct MatrixGridCanvasBody: View, Equatable {
    let state: MatrixGridRenderState

    var body: some View {
        Canvas { context, size in
            let visible = visibleRect(in: size)
            for row in state.rows where intersects(row: row, visible: visible) {
                let rowHighlight = MatrixGridLayoutBuilder.rowHighlighted(
                    row: row,
                    hovered: state.hoveredCrosspoint
                )
                for cell in row.cells where intersects(cell: cell, row: row, visible: visible) {
                    draw(cell: cell, row: row, rowHighlight: rowHighlight, in: &context)
                }
            }
        }
    }

    private func visibleRect(in size: CGSize) -> CGRect {
        CGRect(origin: .zero, size: size)
    }

    private func intersects(row: MatrixGridRowLayout, visible: CGRect) -> Bool {
        let rowRect = CGRect(x: 0, y: row.minY, width: state.gridWidth, height: row.height)
        return rowRect.intersects(visible)
    }

    private func intersects(cell: MatrixGridCellLayout, row: MatrixGridRowLayout, visible: CGRect) -> Bool {
        let slot = CGRect(x: cell.minX, y: row.minY, width: cell.width, height: row.height)
        return slot.intersects(visible)
    }

    private func draw(
        cell: MatrixGridCellLayout,
        row: MatrixGridRowLayout,
        rowHighlight: Bool,
        in context: inout GraphicsContext
    ) {
        let slot = CGRect(x: cell.minX, y: row.minY, width: cell.width, height: row.height)
        let insetX = (cell.width - MatrixTheme.cellSize) / 2
        let insetY = (row.height - MatrixTheme.cellSize) / 2
        let rect = CGRect(
            x: slot.minX + insetX,
            y: slot.minY + insetY,
            width: MatrixTheme.cellSize,
            height: MatrixTheme.cellSize
        )

        switch cell.kind {
        case .crosspoint(let key):
            let connected = state.connections[key] == true
            let muted = state.mutedRoutes.contains(key)
            let unavailable = isCrosspointUnavailable(key)
            let dragPreview = state.diagonalDragPreview.contains(key)
            let columnHighlight = MatrixGridLayoutBuilder.columnHighlighted(
                for: cell.kind,
                hovered: state.hoveredCrosspoint
            )
            let highlighted = rowHighlight || columnHighlight || state.hoveredCrosspoint == key

            if dragPreview, !unavailable {
                let halo = CGRect(
                    x: rect.minX - MatrixTheme.cellSpacing / 2,
                    y: rect.minY - MatrixTheme.cellSpacing / 2,
                    width: rect.width + MatrixTheme.cellSpacing,
                    height: rect.height + MatrixTheme.cellSpacing
                )
                context.fill(
                    Path(roundedRect: halo, cornerRadius: 3),
                    with: .color(MatrixTheme.diagonalDragPreview)
                )
            } else if highlighted, !unavailable {
                let halo = CGRect(
                    x: rect.minX - MatrixTheme.cellSpacing / 2,
                    y: rect.minY - MatrixTheme.cellSpacing / 2,
                    width: rect.width + MatrixTheme.cellSpacing,
                    height: rect.height + MatrixTheme.cellSpacing
                )
                context.fill(
                    Path(roundedRect: halo, cornerRadius: 3),
                    with: .color(MatrixTheme.highlight)
                )
            }

            let fill: Color
            if unavailable {
                if connected {
                    fill = muted ? MatrixTheme.unavailableMutedConnectedFill : MatrixTheme.unavailableConnectedFill
                } else {
                    fill = MatrixTheme.disconnectedFill.opacity(MatrixTheme.unavailableOpacity)
                }
            } else if connected {
                fill = muted ? MatrixTheme.mutedConnectedFill : MatrixTheme.connectedFill
            } else {
                fill = MatrixTheme.disconnectedFill
            }
            let border = connected && !unavailable
                ? Color.white.opacity(0.15)
                : MatrixTheme.disconnectedBorder.opacity(unavailable ? MatrixTheme.unavailableOpacity : 1)
            let path = Path(roundedRect: rect, cornerRadius: 3)
            context.fill(path, with: .color(fill))
            context.stroke(path, with: .color(border), lineWidth: 0.5)

        case .expandSource:
            drawExpandCell(rect: rect, in: &context)
        }
    }

    private func drawExpandCell(
        rect: CGRect,
        in context: inout GraphicsContext
    ) {
        let path = Path(roundedRect: rect, cornerRadius: 3)
        context.fill(path, with: .color(MatrixTheme.disconnectedFill))
        context.stroke(path, with: .color(MatrixTheme.disconnectedBorder), lineWidth: 0.5)

        let plus = Text("+")
            .font(.system(size: 15, weight: .bold, design: .monospaced))
            .foregroundStyle(Color.secondary)
        context.draw(plus, at: CGPoint(x: rect.midX, y: rect.midY), anchor: .center)
    }

    private func isCrosspointUnavailable(_ key: RouteKey) -> Bool {
        guard let source = MatrixRouteCodec.parseSource(key.sourceId),
              let destination = MatrixRouteCodec.parseDestination(key.destinationId) else {
            return true
        }
        let sourceParent = BundleIDMatcher.parentBundleID(of: source.bundleID)
        return state.unavailableSourceGroups.contains(sourceParent)
            || state.unavailableDestinationGroups.contains(destination.deviceUID)
    }
}
