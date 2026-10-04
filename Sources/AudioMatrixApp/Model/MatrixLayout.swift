import AudioMatrixCore
import Foundation

struct MatrixSourceGroup: Identifiable, Hashable, Sendable {
    let id: String
    let displayName: String
    let monoChannels: [Int]
    let isAvailable: Bool

    init(id: String, displayName: String, monoChannels: [Int] = [1, 2], isAvailable: Bool = true) {
        self.id = id
        self.displayName = displayName
        self.monoChannels = monoChannels
        self.isAvailable = isAvailable
    }
}

struct MatrixDestinationGroup: Identifiable, Hashable, Sendable {
    let id: String
    let deviceUID: String
    let displayName: String
    let monoChannels: [Int]
    let isAvailable: Bool

    init(deviceUID: String, displayName: String, outputChannelCount: Int, isAvailable: Bool = true) {
        self.id = deviceUID
        self.deviceUID = deviceUID
        self.displayName = displayName
        self.monoChannels = Array(1...max(1, outputChannelCount))
        self.isAvailable = isAvailable
    }
}

/// Transmitter column (app channel) — top axis.
struct MatrixSourceColumn: Identifiable, Hashable, Sendable {
    let id: String
    let groupID: String
    let displayName: String
    let monoChannel: Int
    let bundleID: String
}

/// One source device header spanning a contiguous run of matrix columns.
struct MatrixSourceBandSegment: Identifiable, Hashable, Sendable {
    let group: MatrixSourceGroup
    let columnCount: Int

    var id: String { group.id }
}

/// Receiver row (device channel) — left axis.
struct MatrixDestinationRow: Identifiable, Hashable, Sendable {
    let id: String
    let groupID: String
    let displayName: String
    let monoChannel: Int
    let deviceUID: String
}

enum MatrixLayoutBuilder {
    static let defaultSourceMonoChannels = [1, 2]

    static func sourceGroups(
        catalog: SourceCatalogSnapshot,
        sourceOrder: [String],
        displayNames: [String: String],
        sourceChannelCounts: [String: Int] = [:],
        availableSourceIDs: Set<String> = []
    ) -> [MatrixSourceGroup] {
        var nameByID: [String: String] = displayNames
        for entry in catalog.playing + catalog.available {
            let parent = BundleIDMatcher.parentBundleID(of: entry.bundleID)
            nameByID[parent] = entry.name
        }

        return sourceOrder.map { parent in
            let channelCount = sourceChannelCounts[parent] ?? defaultSourceMonoChannels.count
            let monoChannels = Array(1...max(1, channelCount))
            return MatrixSourceGroup(
                id: parent,
                displayName: nameByID[parent] ?? parent,
                monoChannels: monoChannels,
                isAvailable: availableSourceIDs.contains(parent)
            )
        }
    }

    static func destinationGroups(
        devices: [OutputDeviceInfo],
        destinationOrder: [String],
        displayNames: [String: String] = [:],
        channelCounts: [String: Int] = [:]
    ) -> [MatrixDestinationGroup] {
        let deviceByUID = Dictionary(uniqueKeysWithValues: devices.map { ($0.uid, $0) })
        return destinationOrder.map { uid in
            if let device = deviceByUID[uid] {
                return MatrixDestinationGroup(
                    deviceUID: device.uid,
                    displayName: device.name,
                    outputChannelCount: device.outputChannelCount,
                    isAvailable: true
                )
            }
            let name = displayNames[uid] ?? offlineDestinationLabel(for: uid)
            let channelCount = channelCounts[uid] ?? defaultSourceMonoChannels.count
            return MatrixDestinationGroup(
                deviceUID: uid,
                displayName: name,
                outputChannelCount: channelCount,
                isAvailable: false
            )
        }
    }

    private static func offlineDestinationLabel(for uid: String) -> String {
        if uid.count > 28 {
            return String(uid.prefix(25)) + "…"
        }
        return uid
    }

    static func sourceColumns(
        from groups: [MatrixSourceGroup],
        expandedGroupIDs: Set<String>
    ) -> [MatrixSourceColumn] {
        groups.flatMap { group in
            if expandedGroupIDs.contains(group.id) {
                return group.monoChannels.map { channel in
                    MatrixSourceColumn(
                        id: "\(group.id)-ch\(channel)",
                        groupID: group.id,
                        displayName: group.displayName,
                        monoChannel: channel,
                        bundleID: group.id
                    )
                }
            }
            return [
                MatrixSourceColumn(
                    id: "\(group.id)-summary",
                    groupID: group.id,
                    displayName: group.displayName,
                    monoChannel: 1,
                    bundleID: group.id
                )
            ]
        }
    }

    static func destinationRows(
        from groups: [MatrixDestinationGroup],
        expandedGroupIDs: Set<String>
    ) -> [MatrixDestinationRow] {
        groups.flatMap { group in
            if expandedGroupIDs.contains(group.id) {
                return group.monoChannels.map { channel in
                    MatrixDestinationRow(
                        id: "\(group.id)-ch\(channel)",
                        groupID: group.id,
                        displayName: group.displayName,
                        monoChannel: channel,
                        deviceUID: group.deviceUID
                    )
                }
            }
            return [
                MatrixDestinationRow(
                    id: "\(group.id)-summary",
                    groupID: group.id,
                    displayName: group.displayName,
                    monoChannel: 1,
                    deviceUID: group.deviceUID
                )
            ]
        }
    }

    static func sourceBandColumnSpan(
        groupID: String,
        sourceColumns: [MatrixSourceColumn]
    ) -> Int {
        max(sourceColumns.filter { $0.groupID == groupID }.count, 1)
    }

    static func sourceBandSegments(
        groups: [MatrixSourceGroup],
        sourceColumns: [MatrixSourceColumn]
    ) -> [MatrixSourceBandSegment] {
        let groupByID = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) })
        var segments: [MatrixSourceBandSegment] = []
        var index = sourceColumns.startIndex

        while index < sourceColumns.endIndex {
            let groupID = sourceColumns[index].groupID
            var count = 0
            while index < sourceColumns.endIndex, sourceColumns[index].groupID == groupID {
                count += 1
                index = sourceColumns.index(after: index)
            }
            guard count > 0, let group = groupByID[groupID] else { continue }
            segments.append(MatrixSourceBandSegment(group: group, columnCount: count))
        }

        return segments
    }

    static func sourceBandWidth(
        columnSpan: Int,
        cellColumnWidth: CGFloat
    ) -> CGFloat {
        CGFloat(max(columnSpan, 1)) * cellColumnWidth
    }

    static func sourceBandWidth(
        for group: MatrixSourceGroup,
        expanded: Bool,
        cellColumnWidth: CGFloat,
        sourceColumns: [MatrixSourceColumn] = []
    ) -> CGFloat {
        let span = sourceColumns.isEmpty
            ? (expanded ? group.monoChannels.count : 1)
            : sourceBandColumnSpan(groupID: group.id, sourceColumns: sourceColumns)
        return sourceBandWidth(columnSpan: span, cellColumnWidth: cellColumnWidth)
    }

    static func destinationBandHeight(
        for group: MatrixDestinationGroup,
        expanded: Bool,
        rowHeight: CGFloat
    ) -> CGFloat {
        MatrixTheme.destinationBlockHeight(
            channelCount: group.monoChannels.count,
            expanded: expanded
        )
    }
}
