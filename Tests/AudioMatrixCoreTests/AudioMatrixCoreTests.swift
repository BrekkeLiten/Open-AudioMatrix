import AudioMatrixCore
import XCTest

final class SourceCatalogTests: XCTestCase {
    func testInputDeviceBundleIDRoundTrip() {
        let uid = "BuiltInMicrophoneDevice"
        let bundleID = SourceCatalog.inputDeviceBundleID(uid: uid)
        XCTAssertTrue(SourceCatalog.isInputDeviceBundleID(bundleID))
        XCTAssertEqual(SourceCatalog.inputDeviceUID(from: bundleID), uid)
    }

    func testAppBundleIDIsNotInputDevice() {
        XCTAssertFalse(SourceCatalog.isInputDeviceBundleID("com.spotify.client"))
    }
}

final class BundleIDMatcherTests: XCTestCase {
    func testParentBundleIDStripsHelperSuffix() {
        XCTAssertEqual(
            BundleIDMatcher.parentBundleID(of: "com.google.Chrome.helper"),
            "com.google.Chrome"
        )
    }

    func testMatchesParentAndHelper() {
        XCTAssertTrue(BundleIDMatcher.matches(
            requestedBundleID: "com.google.Chrome",
            candidateBundleID: "com.google.Chrome.helper"
        ))
    }
}

final class ChannelRouterTests: XCTestCase {
    func testMonoAssignmentWritesExpectedChannel() {
        let router = ChannelRouter(channelCount: 16)
        var output = [Float](repeating: 0, count: 16)
        let source: [Float] = [1, 2, 3, 4, 5, 6]

        output.withUnsafeMutableBufferPointer { outPtr in
            source.withUnsafeBufferPointer { srcPtr in
                router.mixMonoChannel(
                    srcPtr.baseAddress!,
                    frameCount: 1,
                    sourceChannels: 6,
                    sourceChannel: 5,
                    outputChannel: 3,
                    into: outPtr.baseAddress!,
                    mixChannelCount: 16
                )
            }
        }

        XCTAssertEqual(output[2], 5)
        XCTAssertEqual(output[0], 0)
    }

    func testValidateAssignmentAllowsMultipleAppsOnSamePort() {
        let router = ChannelRouter(channelCount: 16)
        let existing = [
            SourceRoute(bundleID: "com.spotify.client", outputDeviceUID: "device-a", sourceChannel: 1, outputChannel: 1),
        ]
        XCTAssertNoThrow(try router.validateAssignment(
            sourceChannel: 2,
            outputChannel: 2,
            sourceChannelCount: 6,
            bundleID: "com.apple.Safari",
            sources: existing,
            outputDeviceUID: "device-a",
            outputChannelCount: 16
        ))
    }

    func testValidateAssignmentRejectsOutOfRangeSourceChannel() {
        let router = ChannelRouter(channelCount: 16)
        XCTAssertThrowsError(try router.validateAssignment(
            sourceChannel: 8,
            outputChannel: 1,
            sourceChannelCount: 6,
            bundleID: "com.apple.Safari",
            sources: [],
            outputDeviceUID: "device-a",
            outputChannelCount: 16
        ))
    }
}

final class MatrixRouteCodecTests: XCTestCase {
    func testSourceIdRoundTrip() {
        let id = MatrixRouteCodec.sourceId(bundleID: "com.spotify.client", monoChannel: 1)
        XCTAssertEqual(id, "com.spotify.client-Ch1")
        XCTAssertEqual(MatrixRouteCodec.parseSource(id)?.bundleID, "com.spotify.client")
        XCTAssertEqual(MatrixRouteCodec.parseSource(id)?.monoChannel, 1)
    }

    func testDestinationIdRoundTrip() {
        let id = MatrixRouteCodec.destinationId(deviceUID: "device-a", monoChannel: 3)
        XCTAssertEqual(MatrixRouteCodec.parseDestination(id)?.deviceUID, "device-a")
        XCTAssertEqual(MatrixRouteCodec.parseDestination(id)?.monoChannel, 3)
    }

    func testEngineRouteMapsMonoChannels() {
        let route = MatrixRouteCodec.engineRoute(
            sourceId: "com.spotify.client-Ch2",
            destinationId: "device-a-Ch4"
        )
        XCTAssertEqual(route?.bundleID, "com.spotify.client")
        XCTAssertEqual(route?.deviceUID, "device-a")
        XCTAssertEqual(route?.sourceChannel, 2)
        XCTAssertEqual(route?.outputChannel, 4)
    }

    func testDiagonalPatchCreatesOneRoutePerChannel() {
        let routes = MatrixRouteCodec.diagonalPatchEngineRoutes(
            sourceBundleID: "com.spotify.client",
            destinationDeviceUID: "device-a",
            sourceMonoChannels: [1, 2, 3, 4, 5, 6],
            destinationMonoChannels: [1, 2, 3, 4, 5, 6]
        )
        XCTAssertEqual(routes.count, 6)
        XCTAssertEqual(routes[0].sourceChannel, 1)
        XCTAssertEqual(routes[0].outputChannel, 1)
        XCTAssertEqual(routes[5].sourceChannel, 6)
        XCTAssertEqual(routes[5].outputChannel, 6)
    }

    func testDiagonalPatchFromAnchorUsesClickedStartingPoint() {
        let (source, destination) = MatrixRouteCodec.diagonalPatchChannels(
            sourceMonoChannels: [1, 2, 3, 4, 5, 6],
            destinationMonoChannels: [1, 2, 3, 4, 5, 6],
            anchorSourceChannel: 3,
            anchorDestinationChannel: 5,
            maxPairs: 2
        )
        XCTAssertEqual(source, [3, 4])
        XCTAssertEqual(destination, [5, 6])
    }
}

final class RoutingSessionTests: XCTestCase {
    func testRoundTripCodable() throws {
        let session = RoutingSession(
            sources: [SourceRoute(
                bundleID: "com.spotify.client",
                outputDeviceUID: "uid",
                sourceChannel: 3,
                outputChannel: 5
            )]
        )
        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(RoutingSession.self, from: data)
        XCTAssertEqual(decoded.sources.first?.sourceChannel, 3)
        XCTAssertEqual(decoded.sources.first?.outputChannel, 5)
    }

    func testLegacyChannelStartDecodesAsMonoRoute() throws {
        let json = """
        {"sources":[{"id":"\(UUID().uuidString)","bundleID":"com.spotify.client","outputDeviceUID":"uid","channelStart":3,"enabled":true}]}
        """
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(RoutingSession.self, from: data)
        XCTAssertEqual(decoded.sources.first?.sourceChannel, 1)
        XCTAssertEqual(decoded.sources.first?.outputChannel, 3)
    }
}

final class TestSignalTests: XCTestCase {
    func testSineSignalWritesTargetChannel() {
        let router = ChannelRouter(channelCount: 4)
        var buffer = [Float](repeating: 0, count: 16)
        var state = TestSignalGeneratorState()

        buffer.withUnsafeMutableBufferPointer { ptr in
            router.applyTestSignal(
                kind: .sine440,
                frameCount: 4,
                channelStart: 2,
                sampleRate: 48_000,
                state: &state,
                into: ptr.baseAddress!,
                mixChannelCount: 4
            )
        }

        // The sine starts at phase 0, so frame 0 is silent; check frame 1.
        XCTAssertNotEqual(buffer[5], 0)
        XCTAssertEqual(buffer[4], 0)
        XCTAssertEqual(buffer[6], 0)
    }

    func testWhiteNoiseGeneratesNonZeroSamples() {
        let router = ChannelRouter(channelCount: 2)
        var buffer = [Float](repeating: 0, count: 8)
        var state = TestSignalGeneratorState()

        buffer.withUnsafeMutableBufferPointer { ptr in
            router.applyTestSignal(
                kind: .whiteNoise,
                frameCount: 4,
                channelStart: 1,
                sampleRate: 48_000,
                state: &state,
                into: ptr.baseAddress!,
                mixChannelCount: 2
            )
        }

        XCTAssertTrue(buffer.contains { $0 != 0 })
    }

    func testMultiChannelSignalWritesAllTargets() {
        let router = ChannelRouter(channelCount: 4)
        var buffer = [Float](repeating: 0, count: 16)
        var state = TestSignalGeneratorState()

        buffer.withUnsafeMutableBufferPointer { ptr in
            router.applyTestSignal(
                kind: .sine440,
                frameCount: 4,
                outputChannels: [1, 3],
                sampleRate: 48_000,
                state: &state,
                into: ptr.baseAddress!,
                mixChannelCount: 4
            )
        }

        // The sine starts at phase 0, so frame 0 is silent; check frame 1.
        XCTAssertNotEqual(buffer[4], 0)
        XCTAssertEqual(buffer[5], 0)
        XCTAssertNotEqual(buffer[6], 0)
        XCTAssertEqual(buffer[7], 0)
    }

    func testLegacyTestToneChannelStartDecodes() throws {
        let json = """
        {"testToneChannelStart":4,"testToneEnabled":true}
        """
        let decoded = try JSONDecoder().decode(RoutingSession.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.testToneChannels, [4])
    }
}
