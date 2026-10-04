import AudioMatrixCore
import Foundation
import SwiftUI

enum MatrixVisibleColumns {
    static func visibleSourceColumnIDs(
        sourceColumns: [MatrixSourceColumn],
        scrollOffsetX: CGFloat,
        paneWidth: CGFloat,
        cellColumnWidth: CGFloat,
        slopColumns: Int = 1
    ) -> Set<String> {
        let slop = CGFloat(slopColumns) * cellColumnWidth
        let visibleMinX = scrollOffsetX - slop
        let visibleMaxX = scrollOffsetX + paneWidth + slop

        var visible: Set<String> = []
        var x: CGFloat = 0
        for column in sourceColumns {
            let columnMaxX = x + cellColumnWidth
            if columnMaxX > visibleMinX, x < visibleMaxX {
                visible.insert(column.id)
            }
            x = columnMaxX
        }
        return visible
    }

    static func meterActiveLevelKeys(
        sourceColumns: [MatrixSourceColumn],
        visibleColumnIDs: Set<String>,
        isSourceGroupExpanded: (String) -> Bool
    ) -> Set<String> {
        var keys: Set<String> = []
        for column in sourceColumns {
            guard visibleColumnIDs.contains(column.id) else { continue }
            if isSourceGroupExpanded(column.groupID) {
                keys.insert(
                    SourceLevelCodec.channelKey(
                        bundleID: column.bundleID,
                        monoChannel: column.monoChannel
                    )
                )
            } else {
                keys.insert(column.groupID)
            }
        }
        return keys
    }
}
