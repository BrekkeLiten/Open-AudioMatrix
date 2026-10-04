import AudioMatrixCore
import SwiftUI

private struct MatrixCrosspointCellVisual: View, Equatable {
    let routeKey: RouteKey
    let isConnected: Bool
    let isMuted: Bool
    let isHighlighted: Bool

    var body: some View {
        ZStack {
            if isHighlighted {
                RoundedRectangle(cornerRadius: 3)
                    .fill(MatrixTheme.highlight)
                    .frame(
                        width: MatrixTheme.cellSize + MatrixTheme.cellSpacing,
                        height: MatrixTheme.cellSize + MatrixTheme.cellSpacing
                    )
            }

            RoundedRectangle(cornerRadius: 3)
                .fill(fillColor)
                .overlay {
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(borderColor, lineWidth: 0.5)
                }
                .frame(width: MatrixTheme.cellSize, height: MatrixTheme.cellSize)
        }
        .frame(
            width: MatrixTheme.cellColumnWidth,
            height: MatrixTheme.rowHeight,
            alignment: .center
        )
    }

    private var fillColor: Color {
        if isConnected {
            return isMuted ? MatrixTheme.mutedConnectedFill : MatrixTheme.connectedFill
        }
        return MatrixTheme.disconnectedFill
    }

    private var borderColor: Color {
        isConnected ? Color.white.opacity(0.15) : MatrixTheme.disconnectedBorder
    }
}

struct MatrixCrosspointCell: View {
    let routeKey: RouteKey
    let isConnected: Bool
    let isMuted: Bool
    let isHighlighted: Bool
    let onTap: (RouteKey) -> Void
    var onHoverChange: ((Bool) -> Void)?

    var body: some View {
        Button {
            onTap(routeKey)
        } label: {
            MatrixCrosspointCellVisual(
                routeKey: routeKey,
                isConnected: isConnected,
                isMuted: isMuted,
                isHighlighted: isHighlighted
            )
            .equatable()
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            onHoverChange?(hovering)
        }
    }
}
