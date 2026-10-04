import AudioMatrixCore
import SwiftUI

struct RoutingMatrixView: View {
    @Bindable var model: AppViewModel
    @State private var scrollOffset = CGPoint.zero
    @State private var quantizedScrollColumn = 0
    @State private var hoveredCrosspoint: RouteKey?
    @State private var channelLabelEdit: ChannelLabelEdit?

    private struct ChannelLabelEdit: Identifiable {
        let deviceUID: String
        let monoChannel: Int
        var id: String { "\(deviceUID)-\(monoChannel)" }
    }

    private var layout: MatrixLayoutSnapshot { model.matrixLayout }

    private var columnHeaderTotalHeight: CGFloat {
        MatrixTheme.sourceBandHeight + MatrixTheme.channelHeaderHeight
    }

    var body: some View {
        GeometryReader { geometry in
            let availableHeight = geometry.size.height
            let gridAreaHeight = max(availableHeight - columnHeaderTotalHeight, 0)
            let paneWidth = geometry.size.width - MatrixTheme.rowHeaderWidth

            HStack(alignment: .top, spacing: 0) {
                receiverHeaderColumn(rowsHeight: gridAreaHeight)
                matrixPane(paneWidth: paneWidth, gridAreaHeight: gridAreaHeight)
            }
            .frame(width: geometry.size.width, height: availableHeight, alignment: .topLeading)
            .onAppear {
                syncMeterVisibility(paneWidth: paneWidth)
            }
            .onChange(of: paneWidth) { _, newWidth in
                syncMeterVisibility(paneWidth: newWidth)
            }
            .onChange(of: layout.sourceColumns) { _, _ in
                syncMeterVisibility(paneWidth: paneWidth)
            }
            .onChange(of: model.collapsedSourceGroups) { _, _ in
                syncMeterVisibility(paneWidth: paneWidth)
            }
            .onChange(of: model.showVUMeters) { _, _ in
                syncMeterVisibility(paneWidth: paneWidth)
            }
            .onChange(of: model.windowVisibility.isVisibleOnDisplay) { _, _ in
                syncMeterVisibility(paneWidth: paneWidth)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(MatrixTheme.background)
        .overlay {
            if layout.sourceGroups.isEmpty || layout.destinationGroups.isEmpty {
                emptyState
            }
        }
        .sheet(item: $channelLabelEdit) { edit in
            ChannelLabelSheet(
                deviceUID: edit.deviceUID,
                monoChannel: edit.monoChannel,
                initialLabel: model.destinationChannelLabel(
                    deviceUID: edit.deviceUID,
                    monoChannel: edit.monoChannel
                ),
                onSave: { label in
                    model.setChannelLabel(
                        deviceUID: edit.deviceUID,
                        monoChannel: edit.monoChannel,
                        label: label
                    )
                }
            )
        }
    }

    // MARK: - Left: receivers (output devices)

    private func receiverHeaderColumn(rowsHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            cornerCell

            ReceiverHeaderRows(
                destinationGroups: layout.destinationGroups,
                hoveredCrosspoint: hoveredCrosspoint,
                isDestinationGroupExpanded: model.isDestinationGroupExpanded,
                channelLabel: model.destinationChannelLabel,
                onRenameChannel: { deviceUID, channel in
                    channelLabelEdit = ChannelLabelEdit(deviceUID: deviceUID, monoChannel: channel)
                },
                onToggleExpand: model.toggleDestinationGroupExpanded
            )
            .offset(y: -scrollOffset.y)
            .frame(height: rowsHeight, alignment: .topLeading)
            .clipped()
        }
        .frame(width: MatrixTheme.rowHeaderWidth, height: rowsHeight + columnHeaderTotalHeight, alignment: .topLeading)
        .clipped()
    }

    private var cornerCell: some View {
        MatrixAxisCornerCell(
            width: MatrixTheme.rowHeaderWidth,
            height: columnHeaderTotalHeight,
            sourceBandHeight: MatrixTheme.sourceBandHeight
        )
    }

    // MARK: - Top: transmitters (apps)

    private func matrixPane(paneWidth: CGFloat, gridAreaHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            transmitterHeaderStack(paneWidth: paneWidth)
            gridScrollView(paneWidth: paneWidth, gridAreaHeight: gridAreaHeight)
        }
        .frame(width: paneWidth, height: gridAreaHeight + columnHeaderTotalHeight, alignment: .topLeading)
    }

    private func transmitterHeaderStack(paneWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            TransmitterSourceBandsView(
                segments: layout.sourceBandSegments,
                gridWidth: layout.gridWidth,
                hoveredCrosspoint: hoveredCrosspoint,
                meters: model.meters,
                showVUMeters: model.vuMetersActive,
                isSourceGroupExpanded: model.isSourceGroupExpanded,
                onToggleExpand: model.toggleSourceGroupExpanded,
                onShiftClick: { groupID in
                    if let destination = layout.destinationGroups.first {
                        model.executeDiagonalPatch(
                            sourceGroupID: groupID,
                            destinationGroupID: destination.deviceUID
                        )
                    }
                }
            )
            .offset(x: -scrollOffset.x)
            .frame(width: paneWidth, height: MatrixTheme.sourceBandHeight, alignment: .leading)
            .clipped()

            TransmitterChannelHeadersView(
                sourceColumns: layout.sourceColumns,
                gridWidth: layout.gridWidth,
                hoveredCrosspoint: hoveredCrosspoint,
                meters: model.meters,
                showVUMeters: model.vuMetersActive,
                visibleSourceColumnIDs: visibleSourceColumnIDs(paneWidth: paneWidth),
                isSourceGroupExpanded: model.isSourceGroupExpanded,
                onExpandSource: model.toggleSourceGroupExpanded
            )
            .offset(x: -scrollOffset.x)
            .frame(width: paneWidth, height: MatrixTheme.rowHeight, alignment: .leading)
            .clipped()
        }
        .frame(width: paneWidth, height: columnHeaderTotalHeight, alignment: .topLeading)
    }

    // MARK: - Grid

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text("Matrix is empty")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Open Configure Matrix to choose outputs and sources.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .background(MatrixTheme.background.opacity(0.94))
    }

    private func gridScrollView(paneWidth: CGFloat, gridAreaHeight: CGFloat) -> some View {
        ScrollView([.horizontal, .vertical]) {
            MatrixGridContent(
                gridRows: layout.gridRows,
                gridWidth: layout.gridWidth,
                gridHeight: layout.gridContentHeight,
                connections: model.audioConnections,
                mutedRoutes: model.mutedConnections,
                hoveredCrosspoint: hoveredCrosspoint,
                activeSourceGroups: model.activeRouteSourceGroups,
                unavailableSourceGroups: Set(
                    layout.sourceGroups.filter { !$0.isAvailable }.map(\.id)
                ),
                unavailableDestinationGroups: Set(
                    layout.destinationGroups.filter { !$0.isAvailable }.map(\.deviceUID)
                ),
                isCrosspointConnected: model.isConnected,
                onToggleCrosspoint: model.toggleCrosspoint,
                onCommitDiagonalDrag: model.commitDiagonalDragPatch,
                onHoverChange: updateHoveredCrosspoint,
                onExpandSource: model.toggleSourceGroupExpanded
            )
            .frame(
                width: max(paneWidth, layout.gridWidth),
                height: max(gridAreaHeight, layout.gridContentHeight),
                alignment: .topLeading
            )
        }
        .frame(width: paneWidth, height: gridAreaHeight, alignment: .topLeading)
        .onScrollGeometryChange(for: CGPoint.self) { geometry in
            CGPoint(x: geometry.contentOffset.x, y: geometry.contentOffset.y)
        } action: { _, newValue in
            scrollOffset = newValue
            let column = Int(newValue.x / MatrixTheme.cellColumnWidth)
            guard column != quantizedScrollColumn else { return }
            quantizedScrollColumn = column
            syncMeterVisibility(paneWidth: paneWidth)
        }
    }

    private func visibleSourceColumnIDs(paneWidth: CGFloat) -> Set<String> {
        MatrixVisibleColumns.visibleSourceColumnIDs(
            sourceColumns: layout.sourceColumns,
            scrollOffsetX: scrollOffset.x,
            paneWidth: paneWidth,
            cellColumnWidth: MatrixTheme.cellColumnWidth
        )
    }

    private func syncMeterVisibility(paneWidth: CGFloat) {
        guard model.vuMetersActive else {
            model.updateMeterVisibility(activeLevelKeys: [])
            return
        }
        let visibleColumns = visibleSourceColumnIDs(paneWidth: paneWidth)
        let activeKeys = MatrixVisibleColumns.meterActiveLevelKeys(
            sourceColumns: layout.sourceColumns,
            visibleColumnIDs: visibleColumns,
            isSourceGroupExpanded: model.isSourceGroupExpanded
        )
        model.updateMeterVisibility(activeLevelKeys: activeKeys)
    }

    private func updateHoveredCrosspoint(_ key: RouteKey, hovering: Bool) {
        if hovering {
            hoveredCrosspoint = key
        } else if hoveredCrosspoint == key {
            hoveredCrosspoint = nil
        }
    }
}

// MARK: - Receiver header (left frozen column)

private struct ReceiverHeaderRows: View {
    let destinationGroups: [MatrixDestinationGroup]
    let hoveredCrosspoint: RouteKey?
    let isDestinationGroupExpanded: (String) -> Bool
    let channelLabel: (String, Int) -> String
    let onRenameChannel: (String, Int) -> Void
    let onToggleExpand: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(destinationGroups) { group in
                ReceiverGroupRows(
                    group: group,
                    hoveredCrosspoint: hoveredCrosspoint,
                    isExpanded: isDestinationGroupExpanded(group.id),
                    channelLabel: channelLabel,
                    onRenameChannel: onRenameChannel,
                    onToggleExpand: { onToggleExpand(group.id) }
                )
            }
        }
        .frame(width: MatrixTheme.rowHeaderWidth, alignment: .topLeading)
    }
}

private struct ReceiverGroupRows: View {
    let group: MatrixDestinationGroup
    let hoveredCrosspoint: RouteKey?
    let isExpanded: Bool
    let channelLabel: (String, Int) -> String
    let onRenameChannel: (String, Int) -> Void
    let onToggleExpand: () -> Void

    @ViewBuilder var body: some View {
        MatrixDestinationGroupHeaderBlock(
            group: group,
            isExpanded: isExpanded,
            hoveredCrosspoint: hoveredCrosspoint,
            channelLabel: { channelLabel(group.deviceUID, $0) },
            onRenameChannel: { onRenameChannel(group.deviceUID, $0) },
            onToggleExpand: onToggleExpand
        )
    }
}

// MARK: - Transmitter header (top frozen row)

private struct TransmitterSourceBandsView: View {
    let segments: [MatrixSourceBandSegment]
    let gridWidth: CGFloat
    let hoveredCrosspoint: RouteKey?
    @Bindable var meters: MatrixMeterState
    let showVUMeters: Bool
    let isSourceGroupExpanded: (String) -> Bool
    let onToggleExpand: (String) -> Void
    let onShiftClick: (String) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(segments) { segment in
                TransmitterSourceBand(
                    group: segment.group,
                    columnSpan: segment.columnCount,
                    hoveredCrosspoint: hoveredCrosspoint,
                    meters: meters,
                    showVUMeters: showVUMeters,
                    isExpanded: isSourceGroupExpanded(segment.group.id),
                    onToggleExpand: { onToggleExpand(segment.group.id) },
                    onShiftClick: { onShiftClick(segment.group.id) }
                )
            }
        }
        .frame(width: gridWidth, alignment: .leading)
    }
}

private struct TransmitterSourceBand: View {
    let group: MatrixSourceGroup
    let columnSpan: Int
    let hoveredCrosspoint: RouteKey?
    @Bindable var meters: MatrixMeterState
    let showVUMeters: Bool
    let isExpanded: Bool
    let onToggleExpand: () -> Void
    let onShiftClick: () -> Void

    var body: some View {
        let bandWidth = MatrixLayoutBuilder.sourceBandWidth(
            columnSpan: columnSpan,
            cellColumnWidth: MatrixTheme.cellColumnWidth
        )

        MatrixSourceBandHeader(
            group: group,
            bandWidth: bandWidth,
            columnSpan: columnSpan,
            level: showVUMeters ? meters.level(for: group.id) : 0,
            showVUMeters: showVUMeters,
            isExpanded: isExpanded,
            isHighlighted: MatrixHoverHighlight.isColumnHighlighted(
                hovered: hoveredCrosspoint,
                bundleID: group.id,
                monoChannel: nil
            ),
            onToggleExpand: onToggleExpand,
            onShiftClick: onShiftClick
        )
    }
}

private struct TransmitterChannelHeadersView: View {
    let sourceColumns: [MatrixSourceColumn]
    let gridWidth: CGFloat
    let hoveredCrosspoint: RouteKey?
    @Bindable var meters: MatrixMeterState
    let showVUMeters: Bool
    let visibleSourceColumnIDs: Set<String>
    let isSourceGroupExpanded: (String) -> Bool
    let onExpandSource: (String) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(sourceColumns) { column in
                if isSourceGroupExpanded(column.groupID) {
                    MatrixSourceChannelColumnHeader(
                        label: String(format: "%02d", column.monoChannel),
                        level: showVUMeters && visibleSourceColumnIDs.contains(column.id)
                            ? meters.level(for: column.bundleID, monoChannel: column.monoChannel)
                            : nil,
                        isHighlighted: MatrixHoverHighlight.isColumnHighlighted(
                            hovered: hoveredCrosspoint,
                            bundleID: column.bundleID,
                            monoChannel: column.monoChannel
                        )
                    )
                } else {
                    MatrixExpandCell(
                        onExpand: { onExpandSource(column.groupID) },
                        slotHeight: MatrixTheme.rowHeight
                    )
                }
            }
        }
        .frame(width: gridWidth, height: MatrixTheme.rowHeight, alignment: .leading)
    }
}

// MARK: - Axis corner (Sources / Receivers diagonal split)

private struct MatrixAxisCornerCell: View {
    let width: CGFloat
    let height: CGFloat
    let sourceBandHeight: CGFloat

    private var channelBandHeight: CGFloat {
        max(height - sourceBandHeight, 0)
    }

    var body: some View {
        ZStack {
            MatrixTheme.headerBackground

            Canvas { context, size in
                var diagonal = Path()
                diagonal.move(to: .zero)
                diagonal.addLine(to: CGPoint(x: size.width, y: size.height))
                context.stroke(
                    diagonal,
                    with: .color(MatrixTheme.gridLine),
                    style: StrokeStyle(lineWidth: 1, lineCap: .square)
                )
            }

            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    axisLabel(title: "Sources", arrow: "→")
                        .padding(.top, 10)
                        .padding(.trailing, 12)
                }
                .frame(height: sourceBandHeight, alignment: .topTrailing)

                HStack(spacing: 0) {
                    axisLabel(title: "Receivers", arrow: "↓")
                        .padding(.leading, 12)
                        .padding(.bottom, 6)
                    Spacer(minLength: 0)
                }
                .frame(height: channelBandHeight, alignment: .bottomLeading)
            }
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .clipped()
        .overlay(alignment: .bottom) {
            MatrixTheme.gridLine.frame(width: width, height: 1)
        }
        .overlay(alignment: .trailing) {
            MatrixTheme.gridLine.frame(width: 1, height: height)
        }
    }

    private func axisLabel(title: String, arrow: String) -> some View {
        HStack(spacing: 2) {
            Text(title)
                .font(.system(size: 9, weight: .semibold))
            Text(arrow)
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(.tertiary)
        }
        .foregroundStyle(.secondary)
        .fixedSize()
    }
}
