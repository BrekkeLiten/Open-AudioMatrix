import AudioMatrixCore
import CoreGraphics
import Foundation

enum MatrixGridCellKind: Hashable, Sendable {
    case crosspoint(RouteKey)
    case expandSource(groupID: String)
}

struct MatrixGridCellLayout: Identifiable, Hashable, Sendable {
    let id: String
    let minX: CGFloat
    let width: CGFloat
    let kind: MatrixGridCellKind
}

struct MatrixGridRowLayout: Identifiable, Hashable, Sendable {
    let id: String
    let minY: CGFloat
    let height: CGFloat
    let cells: [MatrixGridCellLayout]
}

enum MatrixGridLayoutBuilder {
    static func buildRows(
        destinationGroups: [MatrixDestinationGroup],
        sourceColumns: [MatrixSourceColumn],
        expandedDestinationGroups: Set<String>,
        expandedSourceGroups: Set<String>
    ) -> [MatrixGridRowLayout] {
        var rows: [MatrixGridRowLayout] = []
        var y: CGFloat = 0

        for group in destinationGroups {
            if expandedDestinationGroups.contains(group.id) {
                for destChannel in group.monoChannels {
                    rows.append(MatrixGridRowLayout(
                        id: "\(group.id)-ch\(destChannel)",
                        minY: y,
                        height: MatrixTheme.rowHeight,
                        cells: cellsForChannelRow(
                            destinationGroup: group,
                            destChannel: destChannel,
                            sourceColumns: sourceColumns,
                            expandedSourceGroups: expandedSourceGroups
                        )
                    ))
                    y += MatrixTheme.rowHeight
                }
            } else {
                rows.append(MatrixGridRowLayout(
                    id: "\(group.id)-collapsed",
                    minY: y,
                    height: MatrixTheme.rowHeight,
                    cells: []
                ))
                y += MatrixTheme.rowHeight
            }
        }

        return rows
    }

    static func hitTest(
        at point: CGPoint,
        in rows: [MatrixGridRowLayout]
    ) -> MatrixGridCellKind? {
        crosspointHit(at: point, in: rows)?.kind
    }

    /// Grid column/row indices and crosspoint at a point (when the hit is a crosspoint cell).
    static func crosspointHit(
        at point: CGPoint,
        in rows: [MatrixGridRowLayout]
    ) -> (gridColumn: Int, gridRow: Int, kind: MatrixGridCellKind)? {
        for (gridRow, row) in rows.enumerated() where point.y >= row.minY && point.y < row.minY + row.height {
            for cell in row.cells {
                guard point.x >= cell.minX, point.x < cell.minX + cell.width else { continue }
                let gridColumn = gridColumnIndex(forMinX: cell.minX)
                return (gridColumn, gridRow, cell.kind)
            }
            return nil
        }
        return nil
    }

    static func gridColumnIndex(forMinX minX: CGFloat) -> Int {
        Int(floor((minX + MatrixTheme.cellColumnWidth * 0.5) / MatrixTheme.cellColumnWidth))
    }

    static func gridRowIndex(forMinY minY: CGFloat) -> Int {
        Int(floor((minY + MatrixTheme.rowHeight * 0.5) / MatrixTheme.rowHeight))
    }

    /// Primary diagonal from anchor toward bottom-right through the current grid cell.
    static func diagonalCrosspointKeys(
        from anchor: (gridColumn: Int, gridRow: Int),
        to current: (gridColumn: Int, gridRow: Int),
        in rows: [MatrixGridRowLayout]
    ) -> [RouteKey] {
        let endColumn = max(current.gridColumn, anchor.gridColumn)
        let endRow = max(current.gridRow, anchor.gridRow)
        let steps = min(endColumn - anchor.gridColumn, endRow - anchor.gridRow)
        guard steps >= 0 else { return [] }

        var keys: [RouteKey] = []
        for step in 0...steps {
            guard let key = crosspointKey(
                gridColumn: anchor.gridColumn + step,
                gridRow: anchor.gridRow + step,
                in: rows
            ) else {
                continue
            }
            keys.append(key)
        }
        return keys
    }

    static func crosspointKey(
        gridColumn: Int,
        gridRow: Int,
        in rows: [MatrixGridRowLayout]
    ) -> RouteKey? {
        guard gridRow >= 0, gridRow < rows.count else { return nil }
        let targetMinX = CGFloat(gridColumn) * MatrixTheme.cellColumnWidth
        let row = rows[gridRow]
        for cell in row.cells {
            guard abs(cell.minX - targetMinX) < 0.5 else { continue }
            guard case .crosspoint(let key) = cell.kind else { return nil }
            return key
        }
        return nil
    }

    static func rowHighlighted(
        row: MatrixGridRowLayout,
        hovered: RouteKey?
    ) -> Bool {
        guard let hovered,
              let destination = MatrixRouteCodec.parseDestination(hovered.destinationId) else {
            return false
        }
        return row.cells.contains { cell in
            guard case .crosspoint(let key) = cell.kind,
                  let cellDestination = MatrixRouteCodec.parseDestination(key.destinationId) else {
                return false
            }
            return cellDestination.deviceUID == destination.deviceUID
                && cellDestination.monoChannel == destination.monoChannel
        }
    }

    static func columnHighlighted(
        for kind: MatrixGridCellKind,
        hovered: RouteKey?
    ) -> Bool {
        guard let hovered else { return false }
        guard case .crosspoint(let key) = kind else { return false }
        return key.sourceId == hovered.sourceId
    }

    private static func cellsForChannelRow(
        destinationGroup: MatrixDestinationGroup,
        destChannel: Int,
        sourceColumns: [MatrixSourceColumn],
        expandedSourceGroups: Set<String>
    ) -> [MatrixGridCellLayout] {
        var x: CGFloat = 0
        var cells: [MatrixGridCellLayout] = []
        for column in sourceColumns {
            if expandedSourceGroups.contains(column.groupID) {
                let key = RouteKey(
                    sourceId: MatrixRouteCodec.sourceId(
                        bundleID: column.bundleID,
                        monoChannel: column.monoChannel
                    ),
                    destinationId: MatrixRouteCodec.destinationId(
                        deviceUID: destinationGroup.deviceUID,
                        monoChannel: destChannel
                    )
                )
                cells.append(
                    MatrixGridCellLayout(
                        id: "\(column.id)-x-\(destChannel)",
                        minX: x,
                        width: MatrixTheme.cellColumnWidth,
                        kind: .crosspoint(key)
                    )
                )
            }
            x += MatrixTheme.cellColumnWidth
        }
        return cells
    }
}
