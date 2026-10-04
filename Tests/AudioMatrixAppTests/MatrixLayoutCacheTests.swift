import AudioMatrixCore
@testable import AudioMatrixApp
import XCTest

final class MatrixLayoutCacheTests: XCTestCase {
    func testFingerprintStableForIdenticalInputs() {
        let inputs = Self.sampleInputs()
        XCTAssertEqual(
            MatrixLayoutCache.fingerprint(from: inputs),
            MatrixLayoutCache.fingerprint(from: inputs)
        )
    }

    func testFingerprintChangesWhenSourceCollapsed() {
        let expanded = Self.sampleInputs()
        var collapsed = expanded
        collapsed.collapsedSourceGroups = ["com.spotify.client"]
        XCTAssertNotEqual(
            MatrixLayoutCache.fingerprint(from: expanded),
            MatrixLayoutCache.fingerprint(from: collapsed)
        )
    }

    func testFingerprintChangesWhenChannelCountsChange() {
        let baseline = Self.sampleInputs()
        var changed = baseline
        changed.sourceChannelCounts["com.spotify.client"] = 8
        XCTAssertNotEqual(
            MatrixLayoutCache.fingerprint(from: baseline),
            MatrixLayoutCache.fingerprint(from: changed)
        )
    }

    func testFingerprintChangesWhenDestinationGoesOffline() {
        let online = Self.sampleInputs()
        var offline = online
        offline.availableDestinationUIDs = []
        XCTAssertNotEqual(
            MatrixLayoutCache.fingerprint(from: online),
            MatrixLayoutCache.fingerprint(from: offline)
        )
    }

    func testCollapsedSourceReducesCrosspointColumns() {
        // Expand the destination so its channel rows carry crosspoint cells.
        var expandedInputs = Self.sampleInputs()
        expandedInputs.collapsedDestinationGroups = []
        let expanded = MatrixLayoutCache.build(from: expandedInputs)
        var collapsedInputs = expandedInputs
        collapsedInputs.collapsedSourceGroups = ["com.spotify.client"]
        let collapsed = MatrixLayoutCache.build(from: collapsedInputs)

        XCTAssertGreaterThan(expanded.sourceColumns.count, collapsed.sourceColumns.count)
        XCTAssertTrue(expanded.gridRows.contains { !$0.cells.isEmpty })
        XCTAssertFalse(collapsed.gridRows.contains { row in
            row.cells.contains { cell in
                if case .crosspoint = cell.kind { return true }
                return false
            }
        })
    }

    func testExpandedDestinationIncreasesGridHeight() {
        let baseline = MatrixLayoutCache.build(from: Self.sampleInputs())
        var expandedInputs = Self.sampleInputs()
        expandedInputs.collapsedDestinationGroups = []
        let expanded = MatrixLayoutCache.build(from: expandedInputs)

        XCTAssertGreaterThanOrEqual(expanded.gridContentHeight, baseline.gridContentHeight)
        XCTAssertGreaterThanOrEqual(expanded.gridRows.count, baseline.gridRows.count)
    }

    func testSourceBandWidthMatchesExpandedColumnSpan() {
        var inputs = Self.sampleInputs()
        inputs.sourceChannelCounts["com.spotify.client"] = 24
        inputs.collapsedSourceGroups = []
        let layout = MatrixLayoutCache.build(from: inputs)
        let span = MatrixLayoutBuilder.sourceBandColumnSpan(
            groupID: "com.spotify.client",
            sourceColumns: layout.sourceColumns
        )
        let bandWidth = MatrixLayoutBuilder.sourceBandWidth(
            columnSpan: span,
            cellColumnWidth: MatrixTheme.cellColumnWidth
        )
        XCTAssertEqual(span, 24)
        XCTAssertEqual(bandWidth, MatrixTheme.cellColumnWidth * 24)
        XCTAssertEqual(
            bandWidth,
            CGFloat(layout.sourceColumns.filter { $0.groupID == "com.spotify.client" }.count)
                * MatrixTheme.cellColumnWidth
        )
    }

    func testSourceBandSegmentsMatchExpandedColumnRuns() {
        var inputs = Self.sampleInputs()
        inputs.sourceChannelCounts["com.spotify.client"] = 24
        inputs.collapsedSourceGroups = []
        let layout = MatrixLayoutCache.build(from: inputs)
        XCTAssertEqual(layout.sourceBandSegments.count, 1)
        XCTAssertEqual(layout.sourceBandSegments[0].columnCount, 24)
        XCTAssertEqual(
            MatrixLayoutBuilder.sourceBandWidth(
                columnSpan: layout.sourceBandSegments[0].columnCount,
                cellColumnWidth: MatrixTheme.cellColumnWidth
            ),
            MatrixTheme.cellColumnWidth * 24
        )
    }

    private static func sampleInputs() -> MatrixLayoutCache.Inputs {
        let device = OutputDeviceInfo(
            uid: "built-in-output",
            name: "MacBook Speakers",
            outputChannelCount: 2,
            isDefault: true
        )
        let catalog = SourceCatalogSnapshot(
            playing: [
                SourceCatalogEntry(
                    bundleID: "com.spotify.client",
                    name: "Spotify",
                    isPlayingAudio: true,
                    category: .userApplication
                ),
            ],
            available: []
        )
        return MatrixLayoutCache.Inputs(
            devices: [device],
            sourceCatalog: catalog,
            matrixSourceOrder: ["com.spotify.client"],
            matrixDestinationOrder: [device.uid],
            collapsedSourceGroups: [],
            collapsedDestinationGroups: [device.uid],
            sourceDisplayNames: ["com.spotify.client": "Spotify"],
            destinationDisplayNames: [device.uid: device.name],
            destinationChannelCounts: [device.uid: device.outputChannelCount],
            sourceChannelCounts: ["com.spotify.client": 2],
            availableSourceIDs: ["com.spotify.client"],
            availableDestinationUIDs: [device.uid]
        )
    }
}
