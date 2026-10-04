import AudioMatrixCore
import Foundation

struct MatrixLayoutSnapshot: Equatable, Sendable {
    var sourceGroups: [MatrixSourceGroup]
    var destinationGroups: [MatrixDestinationGroup]
    var sourceColumns: [MatrixSourceColumn]
    var sourceBandSegments: [MatrixSourceBandSegment]
    var destinationRows: [MatrixDestinationRow]
    var gridRows: [MatrixGridRowLayout]
    var gridContentHeight: CGFloat
    var gridWidth: CGFloat

    static let empty = MatrixLayoutSnapshot(
        sourceGroups: [],
        destinationGroups: [],
        sourceColumns: [],
        sourceBandSegments: [],
        destinationRows: [],
        gridRows: [],
        gridContentHeight: 0,
        gridWidth: MatrixTheme.cellColumnWidth
    )
}

enum MatrixLayoutCache {
    struct Inputs: Sendable {
        var devices: [OutputDeviceInfo]
        var sourceCatalog: SourceCatalogSnapshot
        var matrixSourceOrder: [String]
        var matrixDestinationOrder: [String]
        var collapsedSourceGroups: Set<String>
        var collapsedDestinationGroups: Set<String>
        var sourceDisplayNames: [String: String]
        var destinationDisplayNames: [String: String]
        var destinationChannelCounts: [String: Int]
        var sourceChannelCounts: [String: Int]
        var availableSourceIDs: Set<String>
        var availableDestinationUIDs: Set<String>
    }

    static func fingerprint(from inputs: Inputs) -> Int {
        var hasher = Hasher()
        hasher.combine(inputs.matrixSourceOrder)
        hasher.combine(inputs.matrixDestinationOrder)
        hasher.combine(inputs.collapsedSourceGroups)
        hasher.combine(inputs.collapsedDestinationGroups)
        hasher.combine(inputs.sourceChannelCounts)
        for device in inputs.devices {
            hasher.combine(device.uid)
            hasher.combine(device.outputChannelCount)
        }
        for entry in inputs.sourceCatalog.playing + inputs.sourceCatalog.available {
            hasher.combine(entry.bundleID)
            hasher.combine(entry.name)
        }
        for sourceID in inputs.matrixSourceOrder {
            hasher.combine(inputs.sourceDisplayNames[sourceID])
            hasher.combine(inputs.availableSourceIDs.contains(sourceID))
        }
        for uid in inputs.matrixDestinationOrder {
            hasher.combine(inputs.destinationDisplayNames[uid])
            hasher.combine(inputs.destinationChannelCounts[uid])
            hasher.combine(inputs.availableDestinationUIDs.contains(uid))
        }
        return hasher.finalize()
    }

    static func build(from inputs: Inputs) -> MatrixLayoutSnapshot {
        let expandedSourceGroups = Set(inputs.matrixSourceOrder).subtracting(inputs.collapsedSourceGroups)
        let expandedDestinationGroups = Set(inputs.matrixDestinationOrder)
            .subtracting(inputs.collapsedDestinationGroups)

        let sourceGroups = MatrixLayoutBuilder.sourceGroups(
            catalog: inputs.sourceCatalog,
            sourceOrder: inputs.matrixSourceOrder,
            displayNames: inputs.sourceDisplayNames,
            sourceChannelCounts: inputs.sourceChannelCounts,
            availableSourceIDs: inputs.availableSourceIDs
        )
        let destinationGroups = MatrixLayoutBuilder.destinationGroups(
            devices: inputs.devices,
            destinationOrder: inputs.matrixDestinationOrder,
            displayNames: inputs.destinationDisplayNames,
            channelCounts: inputs.destinationChannelCounts
        )
        let sourceColumns = MatrixLayoutBuilder.sourceColumns(
            from: sourceGroups,
            expandedGroupIDs: expandedSourceGroups
        )
        let sourceBandSegments = MatrixLayoutBuilder.sourceBandSegments(
            groups: sourceGroups,
            sourceColumns: sourceColumns
        )
        let destinationRows = MatrixLayoutBuilder.destinationRows(
            from: destinationGroups,
            expandedGroupIDs: expandedDestinationGroups
        )

        let gridWidth = max(
            CGFloat(sourceColumns.count) * MatrixTheme.cellColumnWidth,
            MatrixTheme.cellColumnWidth
        )
        let gridContentHeight = destinationGroups.reduce(into: CGFloat(0)) { total, group in
            if expandedDestinationGroups.contains(group.id) {
                total += MatrixTheme.destinationBlockHeight(
                    channelCount: group.monoChannels.count,
                    expanded: true
                )
            } else {
                total += MatrixTheme.rowHeight
            }
        }

        let gridRows = MatrixGridLayoutBuilder.buildRows(
            destinationGroups: destinationGroups,
            sourceColumns: sourceColumns,
            expandedDestinationGroups: expandedDestinationGroups,
            expandedSourceGroups: expandedSourceGroups
        )

        return MatrixLayoutSnapshot(
            sourceGroups: sourceGroups,
            destinationGroups: destinationGroups,
            sourceColumns: sourceColumns,
            sourceBandSegments: sourceBandSegments,
            destinationRows: destinationRows,
            gridRows: gridRows,
            gridContentHeight: gridContentHeight,
            gridWidth: gridWidth
        )
    }
}
