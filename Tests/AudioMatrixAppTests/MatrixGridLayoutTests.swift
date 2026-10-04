import AudioMatrixCore
import XCTest

@testable import AudioMatrixApp

final class MatrixGridLayoutTests: XCTestCase {
    private let sourceGroup = MatrixSourceGroup(
        id: "com.spotify.client",
        displayName: "Spotify",
        monoChannels: [1, 2, 3],
        isAvailable: true
    )

    private let destinationGroup = MatrixDestinationGroup(
        deviceUID: "device-a",
        displayName: "Speakers",
        outputChannelCount: 3,
        isAvailable: true
    )

    private var rows: [MatrixGridRowLayout] {
        MatrixGridLayoutBuilder.buildRows(
            destinationGroups: [destinationGroup],
            sourceColumns: MatrixLayoutBuilder.sourceColumns(
                from: [sourceGroup],
                expandedGroupIDs: [sourceGroup.id]
            ),
            expandedDestinationGroups: [destinationGroup.id],
            expandedSourceGroups: [sourceGroup.id]
        )
    }

    func testDiagonalCrosspointKeysFollowsPrimaryDiagonal() {
        let keys = MatrixGridLayoutBuilder.diagonalCrosspointKeys(
            from: (gridColumn: 0, gridRow: 0),
            to: (gridColumn: 2, gridRow: 2),
            in: rows
        )

        XCTAssertEqual(keys.count, 3)
        XCTAssertEqual(MatrixRouteCodec.parseSource(keys[0].sourceId)?.monoChannel, 1)
        XCTAssertEqual(MatrixRouteCodec.parseDestination(keys[0].destinationId)?.monoChannel, 1)
        XCTAssertEqual(MatrixRouteCodec.parseSource(keys[2].sourceId)?.monoChannel, 3)
        XCTAssertEqual(MatrixRouteCodec.parseDestination(keys[2].destinationId)?.monoChannel, 3)
    }

    func testDiagonalCrosspointKeysIgnoresUpwardDrag() {
        let keys = MatrixGridLayoutBuilder.diagonalCrosspointKeys(
            from: (gridColumn: 2, gridRow: 2),
            to: (gridColumn: 0, gridRow: 0),
            in: rows
        )

        XCTAssertEqual(keys.count, 1)
        XCTAssertEqual(MatrixRouteCodec.parseSource(keys[0].sourceId)?.monoChannel, 3)
        XCTAssertEqual(MatrixRouteCodec.parseDestination(keys[0].destinationId)?.monoChannel, 3)
    }
}
