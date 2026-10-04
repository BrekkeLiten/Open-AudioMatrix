import AudioMatrixCore
import Foundation
import os

public final class ProcessTapManager: @unchecked Sendable {
    private let logger = Logger(subsystem: "io.github.brekkeliten.openaudiomatrix", category: "TapManager")
    private let lock = NSLock()
    private var taps: [String: ProcessTapSource] = [:]
    private var avoidUIDsByBundle: [String: Set<String>] = [:]
    private var playthroughUIDByBundle: [String: String?] = [:]

    public var onAudio: ((String, UnsafePointer<Float>, Int, Int, Double) -> Void)?
    public var onTapWillRestart: ((String) -> Void)?
    public var playthroughRender: ((String, Int) -> (UnsafePointer<Float>?, Int))?

    public init() {}

    public func apply(session: RoutingSession, playthroughDeviceUIDs: Set<String> = []) throws {
        lock.lock()
        defer { lock.unlock() }

        let enabledRoutes = session.sources.filter(\.enabled).filter {
            !SourceCatalog.isInputDeviceBundleID($0.bundleID)
        }
        var routesByBundle: [String: [SourceRoute]] = [:]
        for route in enabledRoutes {
            let key = BundleIDMatcher.parentBundleID(of: route.bundleID)
            routesByBundle[key, default: []].append(route)
        }

        let enabledBundleIDs = Set(routesByBundle.keys)

        for (bundleID, tap) in taps where !enabledBundleIDs.contains(bundleID) {
            tap.stop()
            taps.removeValue(forKey: bundleID)
            avoidUIDsByBundle.removeValue(forKey: bundleID)
            playthroughUIDByBundle.removeValue(forKey: bundleID)
        }

        for (bundleID, bundleRoutes) in routesByBundle {
            let avoidUIDs = Set(bundleRoutes.map(\.outputDeviceUID))
            let representativeRoute = bundleRoutes[0]
            let playthroughUID: String? = nil

            if taps[bundleID] != nil,
               avoidUIDsByBundle[bundleID] == avoidUIDs,
               playthroughUIDByBundle[bundleID] ?? nil == playthroughUID {
                continue
            }

            if taps[bundleID] != nil {
                let previousAvoid = Array(avoidUIDsByBundle[bundleID] ?? [])
                let previousAvoidSet = Set(previousAvoid)

                if avoidUIDs.isStrictSuperset(of: previousAvoidSet) {
                    avoidUIDsByBundle[bundleID] = avoidUIDs
                    playthroughUIDByBundle[bundleID] = playthroughUID
                    continue
                }

                let newClock = try CoreAudioHelpers.tapClockDeviceUID(avoiding: Array(avoidUIDs))
                let oldClock = try CoreAudioHelpers.tapClockDeviceUID(avoiding: previousAvoid)
                if newClock == oldClock, playthroughUIDByBundle[bundleID] ?? nil == playthroughUID {
                    avoidUIDsByBundle[bundleID] = avoidUIDs
                    playthroughUIDByBundle[bundleID] = playthroughUID
                    continue
                }

                onTapWillRestart?(bundleID)
                taps[bundleID]?.stop()
                taps.removeValue(forKey: bundleID)
            }

            let tap = ProcessTapSource(
                bundleID: representativeRoute.bundleID,
                avoidDeviceUIDs: Array(avoidUIDs),
                playthroughDeviceUID: playthroughUID
            )
            tap.onAudio = { [weak self] samples, frameCount, channelCount, deliveryRate in
                self?.onAudio?(bundleID, samples, frameCount, channelCount, deliveryRate)
            }
            tap.playthroughRender = { [weak self] deviceUID, maxFrames in
                self?.playthroughRender?(deviceUID, maxFrames) ?? (nil, 0)
            }
            tap.onWillRestart = { [weak self] in
                self?.onTapWillRestart?(bundleID)
            }
            try tap.start()
            taps[bundleID] = tap
            avoidUIDsByBundle[bundleID] = avoidUIDs
            playthroughUIDByBundle[bundleID] = playthroughUID
        }
    }

    public func sourceChannelCounts() -> [String: Int] {
        lock.lock()
        defer { lock.unlock() }
        return taps.mapValues(\.channelCount)
    }

    public func stopAll() {
        lock.lock()
        defer { lock.unlock() }
        for tap in taps.values {
            tap.stop()
        }
        taps.removeAll()
        avoidUIDsByBundle.removeAll()
        playthroughUIDByBundle.removeAll()
    }

    public func refreshTaps() {
        lock.lock()
        let currentTaps = taps
        lock.unlock()

        for (bundleID, tap) in currentTaps {
            do {
                _ = try tap.restartIfNeeded()
            } catch {
                logger.error("Failed to refresh tap for \(bundleID, privacy: .public): \(error.localizedDescription)")
            }
        }
    }

    private func resolvePlaythroughUID(
        for bundleID: String,
        routes: [SourceRoute],
        routesByBundle: [String: [SourceRoute]],
        playthroughDeviceUIDs: Set<String>
    ) -> String? {
        let routedUIDs = Set(routes.map(\.outputDeviceUID))
        let candidates = routedUIDs.intersection(playthroughDeviceUIDs)
        guard candidates.count == 1, let deviceUID = candidates.first else {
            return nil
        }

        // Only one tap may drive playthrough per output device.
        let owner = routesByBundle.keys.sorted().first { candidate in
            routesByBundle[candidate]?.contains { $0.outputDeviceUID == deviceUID } == true
        }
        guard owner == bundleID else { return nil }
        return deviceUID
    }
}
