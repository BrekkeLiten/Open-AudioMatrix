import SwiftUI

enum MatrixTheme {
    static let cellSize: CGFloat = 34
    /// Gap between crosspoint cells (horizontal and vertical).
    static let cellSpacing: CGFloat = 3
    static let rowHeaderWidth: CGFloat = 200
    /// Row slot height: cell + gap so rows never overlap.
    static var rowHeight: CGFloat { cellSize + cellSpacing }
    static let sourceBandHeight: CGFloat = 156
    /// Source channel number row — one grid row tall (matches receiver channel cells).
    static var channelHeaderHeight: CGFloat { rowHeight }
    static let headerFontSize: CGFloat = 12
    static let appIconSize: CGFloat = 22
    /// Prominent icon size for expanded source band headers.
    static let sourceBandIconSize: CGFloat = 36
    /// Fixed top slot height so logos align across all columns (expanded and minimized).
    static let sourceBandIconSlotHeight: CGFloat = 40
    /// Icon size cap for minimized (single-column) source bands.
    static let sourceBandIconSizeMinimized: CGFloat = 28
    static let sourceLabelRailWidth: CGFloat = 20
    static let sourceLabelFontSize: CGFloat = 9
    static let sourceLevelMeterWidth: CGFloat = 5
    static let sourceLevelMeterHeight: CGFloat = 28
    static let sourceChannelLevelMeterWidth: CGFloat = 4
    static let sourceChannelLevelMeterHeight: CGFloat = 22
    static let sourceHeaderContentSpacing: CGFloat = 6
    static let sourceBandTopPadding: CGFloat = 8
    static let sourceBandHorizontalPadding: CGFloat = 6
    /// Gap between the bottom of the label/meter and the band grid line.
    static let sourceLabelBottomPadding: CGFloat = 8

    /// Square expand/collapse control — identical size and anchor in every header state.
    static let expandToggleSize: CGFloat = 24
    static let expandToggleFontSize: CGFloat = 16
    static let expandToggleCornerRadius: CGFloat = 4
    /// Reserved leading column in receiver device blocks so content never shifts under the toggle.
    static let expandToggleSlotWidth: CGFloat = 28
    /// Corner inset for absolutely pinned header toggles (Sources band headers).
    static let expandToggleCornerInset: CGFloat = 4
    /// Legacy band insets — receiver sidebar uses corner inset + slot width.
    static let expandToggleBandInset: CGFloat = expandToggleCornerInset
    static let expandToggleLeadingInset: CGFloat = expandToggleCornerInset

    /// Space reserved along the bottom edge so source logos clear the corner toggle.
    static var sourceHeaderToggleReserveHeight: CGFloat {
        expandToggleCornerInset * 2 + expandToggleSize
    }

    /// Main content region above the pinned source-header toggle.
    static var sourceHeaderMainBodyHeight: CGFloat {
        sourceBandHeight - sourceHeaderToggleReserveHeight
    }

    static let background = Color(red: 0.12, green: 0.12, blue: 0.13)
    static let headerBackground = Color(red: 0.16, green: 0.16, blue: 0.17)
    static let gridLine = Color.white.opacity(0.08)
    static let highlight = Color(red: 0.0, green: 0.55, blue: 0.55).opacity(0.35)
    static let diagonalDragPreview = Color(red: 0.35, green: 0.75, blue: 1.0).opacity(0.32)

    static let disconnectedFill = Color(red: 0.18, green: 0.18, blue: 0.19)
    static let disconnectedBorder = Color.white.opacity(0.06)
    static let connectedFill = Color(red: 0.0, green: 0.72, blue: 0.25)
    static let mutedConnectedFill = Color(red: 0.0, green: 0.72, blue: 0.25).opacity(0.45)
    static let unavailableOpacity: Double = 0.38
    static let unavailableConnectedFill = connectedFill.opacity(unavailableOpacity)
    static let unavailableMutedConnectedFill = mutedConnectedFill.opacity(unavailableOpacity)

    static var cellColumnWidth: CGFloat { cellSize + cellSpacing }
    /// Receiver device name/icon column — fills sidebar width minus channel rail.
    static var destinationDeviceColumnWidth: CGFloat { rowHeaderWidth - cellColumnWidth }

    /// Vertical extent of one receiver device block in the sidebar (matches grid row stack).
    static func destinationBlockHeight(channelCount: Int, expanded: Bool) -> CGFloat {
        if expanded {
            return rowHeight * CGFloat(max(channelCount, 1))
        }
        return rowHeight
    }
}
