import AppKit
import AudioMatrixCore
import SwiftUI

// MARK: - Receivers (output devices) — left axis

/// One receiver device block: label band (left) + channel rail (right, flush to grid).
struct MatrixDestinationGroupHeaderBlock: View {
    let group: MatrixDestinationGroup
    let isExpanded: Bool
    let hoveredCrosspoint: RouteKey?
    let channelLabel: (Int) -> String
    let onRenameChannel: (Int) -> Void
    let onToggleExpand: () -> Void

    private var blockHeight: CGFloat {
        MatrixTheme.destinationBlockHeight(
            channelCount: group.monoChannels.count,
            expanded: isExpanded
        )
    }

    private var bandHighlighted: Bool {
        MatrixHoverHighlight.isRowHighlighted(
            hovered: hoveredCrosspoint,
            deviceUID: group.deviceUID,
            monoChannel: nil
        )
    }

    var body: some View {
        HStack(spacing: 0) {
            deviceColumn
            channelRail
        }
        .frame(width: MatrixTheme.rowHeaderWidth, height: blockHeight, alignment: .topLeading)
        .overlay(alignment: .trailing) {
            MatrixTheme.gridLine.frame(width: 1, height: blockHeight)
        }
        .overlay(alignment: .bottom) {
            MatrixTheme.gridLine.frame(width: MatrixTheme.rowHeaderWidth, height: 1)
        }
    }

    // MARK: - Column 1: device name/icon (mirrors source band header)

    private var deviceColumn: some View {
        ZStack(alignment: .topLeading) {
            Group {
                if isExpanded {
                    expandedDeviceContent
                } else {
                    collapsedDeviceContent
                }
            }
            .frame(
                maxWidth: .infinity,
                maxHeight: blockHeight,
                alignment: isExpanded ? .center : .leading
            )
            .padding(.leading, MatrixTheme.expandToggleSlotWidth)

            expandToggle
        }
        .opacity(group.isAvailable ? 1 : MatrixTheme.unavailableOpacity)
        .frame(width: MatrixTheme.destinationDeviceColumnWidth, height: blockHeight, alignment: .topLeading)
        .background(bandHighlighted ? MatrixTheme.highlight : MatrixTheme.headerBackground)
        .overlay(alignment: .trailing) {
            MatrixTheme.gridLine.frame(width: 1, height: blockHeight)
        }
    }

    private var collapsedDeviceContent: some View {
        HStack(spacing: 6) {
            deviceIcon
            Text(group.displayName)
                .font(.system(size: MatrixTheme.headerFontSize, weight: .semibold))
                .foregroundStyle(group.isAvailable ? .primary : .tertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(.horizontal, 6)
    }

    private var expandedDeviceContent: some View {
        VStack(spacing: MatrixTheme.sourceHeaderContentSpacing) {
            deviceIcon
            Text(group.displayName)
                .font(.system(size: MatrixTheme.headerFontSize, weight: .semibold))
                .foregroundStyle(group.isAvailable ? Color.primary : Color.primary.opacity(0.35))
                .lineLimit(4)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .minimumScaleFactor(0.75)
                .frame(maxWidth: deviceContentMaxWidth)
        }
        .padding(.horizontal, 6)
    }

    private var deviceContentMaxWidth: CGFloat {
        max(
            MatrixTheme.destinationDeviceColumnWidth
                - MatrixTheme.expandToggleSlotWidth
                - MatrixTheme.sourceBandHorizontalPadding,
            0
        )
    }

    // MARK: - Column 2: channel numbers (mirrors source channel header row)

    @ViewBuilder
    private var channelRail: some View {
        Group {
            if isExpanded {
                VStack(spacing: 0) {
                    ForEach(group.monoChannels, id: \.self) { channel in
                        channelRailCell(
                            label: channelLabel(channel),
                            monoChannel: channel,
                            onRename: { onRenameChannel(channel) }
                        )
                    }
                }
            } else {
                MatrixExpandCell(
                    onExpand: onToggleExpand,
                    slotWidth: MatrixTheme.cellColumnWidth,
                    slotHeight: MatrixTheme.rowHeight
                )
                .background(MatrixTheme.headerBackground)
            }
        }
        .fixedSize(horizontal: true, vertical: true)
    }

    private var deviceIcon: some View {
        Image(systemName: "hifispeaker.fill")
            .font(.system(size: 11))
            .foregroundStyle(.orange.opacity(group.isAvailable ? 0.9 : 0.35))
            .frame(width: MatrixTheme.appIconSize, height: MatrixTheme.appIconSize)
    }

    private func channelRailCell(
        label: String,
        monoChannel: Int,
        onRename: @escaping () -> Void
    ) -> some View {
        let highlighted = MatrixHoverHighlight.isRowHighlighted(
            hovered: hoveredCrosspoint,
            deviceUID: group.deviceUID,
            monoChannel: monoChannel
        )

        return Text(label)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(width: MatrixTheme.cellColumnWidth, height: MatrixTheme.rowHeight)
            .help(label)
            .contextMenu {
                Button("Rename Channel…") { onRename() }
            }
            .background(highlighted ? MatrixTheme.highlight : MatrixTheme.headerBackground)
            .overlay(alignment: .bottom) { MatrixTheme.gridLine.frame(height: 1) }
    }

    private var expandToggle: some View {
        MatrixExpandToggleButton(
            isExpanded: isExpanded,
            action: onToggleExpand
        )
        .padding(.top, MatrixTheme.expandToggleBandInset)
        .padding(.leading, MatrixTheme.expandToggleLeadingInset)
    }
}

// MARK: - Transmitters (apps) — top axis

struct MatrixSourceBandHeader: View {
    let group: MatrixSourceGroup
    let bandWidth: CGFloat
    let columnSpan: Int
    let level: Float
    let showVUMeters: Bool
    let isExpanded: Bool
    let isHighlighted: Bool
    let onToggleExpand: () -> Void
    var onShiftClick: (() -> Void)?

    private var usesWideHeaderLayout: Bool {
        columnSpan > 1
    }

    private var contentMaxWidth: CGFloat {
        max(
            bandWidth - MatrixTheme.sourceBandHorizontalPadding * 2,
            0
        )
    }

    /// Large in expanded mode; scaled down for narrow minimized columns, always within the icon slot.
    private var sourceIconSize: CGFloat {
        let maxIconWidth = max(contentMaxWidth, 16)
        if isExpanded {
            return min(MatrixTheme.sourceBandIconSize, maxIconWidth)
        }
        let proportional = maxIconWidth * 0.78
        return min(
            MatrixTheme.sourceBandIconSizeMinimized,
            proportional,
            maxIconWidth
        )
    }

    private var labelForegroundStyle: Color {
        group.isAvailable ? Color.primary : Color.primary.opacity(0.35)
    }

    private var minimizedLabelRailHeight: CGFloat {
        max(
            MatrixTheme.sourceHeaderMainBodyHeight
                - MatrixTheme.sourceBandTopPadding
                - MatrixTheme.sourceBandIconSlotHeight
                - MatrixTheme.sourceHeaderContentSpacing
                - MatrixTheme.sourceLabelBottomPadding,
            24
        )
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            sourceHeaderContent
                .frame(width: bandWidth, height: MatrixTheme.sourceBandHeight, alignment: .top)
                .zIndex(0)
        }
        .overlay(alignment: .bottomLeading) {
            expandToggle
                .padding(MatrixTheme.expandToggleCornerInset)
                .zIndex(1)
        }
        .opacity(group.isAvailable ? 1 : MatrixTheme.unavailableOpacity)
        .frame(width: bandWidth, height: MatrixTheme.sourceBandHeight, alignment: .top)
        .background(isHighlighted ? MatrixTheme.highlight : MatrixTheme.headerBackground)
        .overlay(alignment: .bottom) { MatrixTheme.gridLine.frame(height: 1) }
        .overlay(alignment: .trailing) { MatrixTheme.gridLine.frame(width: 1) }
        .contentShape(Rectangle())
        .onTapGesture {
            guard isExpanded, NSEvent.modifierFlags.contains(.shift) else { return }
            onShiftClick?()
        }
    }

    /// Shared column layout: icon slot → label slot → footer slot (expanded only).
    /// Centered in the main body region above the pinned bottom-left toggle.
    private var sourceHeaderContent: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            VStack(spacing: MatrixTheme.sourceHeaderContentSpacing) {
                sourceIconSlot
                sourceLabelSlot
                sourceFooterSlot
            }

            Spacer(minLength: 0)
        }
        .frame(width: bandWidth, height: MatrixTheme.sourceHeaderMainBodyHeight, alignment: .center)
        .padding(.top, MatrixTheme.sourceBandTopPadding)
        .padding(.horizontal, MatrixTheme.sourceBandHorizontalPadding)
        .padding(.bottom, MatrixTheme.sourceLabelBottomPadding)
    }

    private var sourceIconSlot: some View {
        AppIconView(bundleID: group.id, size: sourceIconSize)
            .opacity(group.isAvailable ? 1 : MatrixTheme.unavailableOpacity)
            .frame(
                width: contentMaxWidth,
                height: MatrixTheme.sourceBandIconSlotHeight,
                alignment: .center
            )
            .frame(maxWidth: .infinity, alignment: .center)
    }

    @ViewBuilder
    private var sourceLabelSlot: some View {
        if isExpanded {
            Text(group.displayName)
                .font(.system(size: MatrixTheme.headerFontSize, weight: .semibold))
                .foregroundStyle(labelForegroundStyle)
                .lineLimit(usesWideHeaderLayout ? 2 : 3)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.75)
                .frame(maxWidth: contentMaxWidth, alignment: .center)
                .frame(maxWidth: .infinity, alignment: .center)
        } else {
            VerticalBottomUpLabel(
                text: group.displayName,
                railHeight: minimizedLabelRailHeight,
                containerWidth: bandWidth,
                foregroundStyle: labelForegroundStyle
            )
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    @ViewBuilder
    private var sourceFooterSlot: some View {
        if showVUMeters, !isExpanded, group.isAvailable {
            VerticalLevelMeter(level: level)
                .frame(
                    width: MatrixTheme.sourceLevelMeterWidth,
                    height: MatrixTheme.sourceLevelMeterHeight
                )
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private var expandToggle: some View {
        MatrixExpandToggleButton(
            isExpanded: isExpanded,
            action: onToggleExpand
        )
    }
}

struct MatrixSourceChannelColumnHeader: View {
    let label: String
    let level: Float?
    let isHighlighted: Bool

    var body: some View {
        HStack(spacing: 2) {
            if let level {
                VerticalLevelMeter(level: level)
                    .frame(
                        width: MatrixTheme.sourceChannelLevelMeterWidth,
                        height: MatrixTheme.sourceChannelLevelMeterHeight
                    )
            }
            Text(label)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(width: MatrixTheme.cellColumnWidth, height: MatrixTheme.rowHeight, alignment: .center)
        .background(isHighlighted ? MatrixTheme.highlight : MatrixTheme.headerBackground)
        .overlay(alignment: .trailing) { MatrixTheme.gridLine.frame(width: 1) }
        .overlay(alignment: .bottom) { MatrixTheme.gridLine.frame(height: 1) }
    }
}
