import AudioMatrixCore
import AudioMatrixCapture
import Darwin
import Foundation
import os

/// Per-output-device render state — owned by one IO thread at a time via `lock`.
private final class DeviceRenderContext: @unchecked Sendable {
    let lock = NSLock()
    var primed = false
    var holdFrameCount = 0
    var holdBuffer: UnsafeMutablePointer<Float>?
    var holdCapacity = 0
    var mixBuffer: UnsafeMutablePointer<Float>?
    var mixCapacity = 0
    var outputSampleRate: Double = RealtimeMixer.fallbackSampleRate
    var channelCount = 2
    private(set) var scratchFrames: Int
    private(set) var scratchChannels: Int
    private var sourceScratch: UnsafeMutablePointer<Float>
    private var tapReadScratch: UnsafeMutablePointer<Float>

    init(scratchFrames: Int, scratchChannels: Int = 16) {
        self.scratchFrames = scratchFrames
        self.scratchChannels = scratchChannels
        sourceScratch = Self.allocateScratch(frames: scratchFrames, channels: scratchChannels)
        tapReadScratch = Self.allocateScratch(frames: scratchFrames, channels: scratchChannels)
    }

    deinit {
        mixBuffer?.deallocate()
        holdBuffer?.deallocate()
        sourceScratch.deallocate()
        tapReadScratch.deallocate()
    }

    func sourceScratchPtr() -> UnsafeMutablePointer<Float> { sourceScratch }
    func tapReadScratchPtr() -> UnsafeMutablePointer<Float> { tapReadScratch }

    func ensureScratchFrames(_ required: Int, channelCount: Int) {
        let neededFrames = max(scratchFrames, required)
        let neededChannels = max(scratchChannels, channelCount)
        guard neededFrames > scratchFrames || neededChannels > scratchChannels else { return }
        sourceScratch.deallocate()
        tapReadScratch.deallocate()
        scratchFrames = neededFrames
        scratchChannels = neededChannels
        sourceScratch = Self.allocateScratch(frames: neededFrames, channels: neededChannels)
        tapReadScratch = Self.allocateScratch(frames: neededFrames, channels: neededChannels)
    }

    func ensureMixBuffer(channelCount: Int, sampleCount: Int) {
        guard mixCapacity < sampleCount else { return }
        mixBuffer?.deallocate()
        let ptr = UnsafeMutablePointer<Float>.allocate(capacity: sampleCount)
        ptr.initialize(repeating: 0, count: sampleCount)
        mixBuffer = ptr
        mixCapacity = sampleCount
    }

    func ensureHoldBuffer(channelCount: Int, sampleCount: Int) -> UnsafeMutablePointer<Float>? {
        if holdCapacity >= sampleCount, let ptr = holdBuffer {
            return ptr
        }
        holdBuffer?.deallocate()
        let ptr = UnsafeMutablePointer<Float>.allocate(capacity: sampleCount)
        ptr.initialize(repeating: 0, count: sampleCount)
        holdBuffer = ptr
        holdCapacity = sampleCount
        return ptr
    }

    func clearHoldBuffer() {
        holdFrameCount = 0
        if holdCapacity > 0, let holdPtr = holdBuffer {
            memset(holdPtr, 0, holdCapacity * MemoryLayout<Float>.size)
        }
    }

    private static func allocateScratch(frames: Int, channels: Int) -> UnsafeMutablePointer<Float> {
        let ptr = UnsafeMutablePointer<Float>.allocate(capacity: frames * channels)
        ptr.initialize(repeating: 0, count: frames * channels)
        return ptr
    }
}

private struct FadingRouteState {
    let route: SourceRoute
    var remainingFrames: Int
}

/// Central realtime mixer: N tap sources → per-device summed multichannel output.
final class RealtimeMixer: @unchecked Sendable {
    static let fallbackSampleRate: Double = 48_000
    static let ringFrameCapacity = 8192
    static let maxRingLatencyFrames = 6144
    static let maxRenderFrames = 1024
    static let minPrimingFrames = 512
    static let fadeOutFrames = 480
    static let defaultSourceChannels = 2

    private let logger = Logger(subsystem: "io.github.brekkeliten.openaudiomatrix", category: "RealtimeMixer")
    private let configLock = NSLock()

    private var sourceRings: [String: SPSCChannelRing] = [:]
    private var bundleRings: [String: [SPSCChannelRing]] = [:]
    private var tapSampleRates: [String: Double] = [:]
    private var tapChannelCounts: [String: Int] = [:]
    private var fadingRoutes: [String: FadingRouteState] = [:]
    private(set) var playthroughDeviceUIDs: Set<String> = []
    private var activeSnapshot = MixerSnapshot.empty
    private var testSignalState = TestSignalGeneratorState()
    private let outputManager = PhysicalOutputManager()
    private let deviceListener = DeviceChangeListener()
    private var deviceContexts: [String: DeviceRenderContext] = [:]
    private var lastSyncedOutputUIDs: Set<String> = []

    var onFadingRoutesChanged: (() -> Void)?
    var onDeviceOutputsNeedResync: (() -> Void)?

    init() {
        deviceListener.onChange = { [weak self] in
            self?.onDeviceOutputsNeedResync?()
        }
        deviceListener.start()
    }

    deinit {
        deviceListener.stop()
        outputManager.stopAll()
        configLock.lock()
        deviceContexts.removeAll()
        configLock.unlock()
    }

    private static func bundleKey(for bundleID: String) -> String {
        BundleIDMatcher.parentBundleID(of: bundleID)
    }

    static func ringKey(bundleID: String, deviceUID: String) -> String {
        "\(bundleKey(for: bundleID))|\(deviceUID)"
    }

    private static func fadingKey(for route: SourceRoute) -> String {
        route.id.uuidString
    }

    func fadingRoutesForRetention() -> [SourceRoute] {
        configLock.lock()
        defer { configLock.unlock() }
        return fadingRoutes.values.map(\.route)
    }

    func sourceChannelCounts() -> [String: Int] {
        configLock.lock()
        defer { configLock.unlock() }
        return tapChannelCounts
    }

    func setTapChannelCounts(_ counts: [String: Int]) {
        configLock.lock()
        for (bundleID, count) in counts where count > 0 {
            if tapChannelCounts[bundleID] != count {
                tapChannelCounts[bundleID] = count
                recreateRings(forBundle: bundleID, channelCount: count)
            } else {
                tapChannelCounts[bundleID] = count
            }
        }
        configLock.unlock()
    }

    private func recreateRings(forBundle bundleID: String, channelCount: Int) {
        let prefix = "\(bundleID)|"
        for ringKey in Array(sourceRings.keys) where ringKey.hasPrefix(prefix) {
            let ring = SPSCChannelRing(frameCapacity: Self.ringFrameCapacity, channelCount: channelCount)
            ring.discardAll()
            sourceRings[ringKey] = ring
        }
        if bundleRings[bundleID] != nil {
            bundleRings[bundleID] = sourceRings
                .filter { $0.key.hasPrefix(prefix) }
                .map(\.value)
        }
    }

    private func rebuildBundleRings(from routes: [SourceRoute]) {
        var rebuilt: [String: [SPSCChannelRing]] = [:]
        for route in routes {
            let bundle = Self.bundleKey(for: route.bundleID)
            let ringKey = Self.ringKey(bundleID: bundle, deviceUID: route.outputDeviceUID)
            guard let ring = sourceRings[ringKey] else { continue }
            if rebuilt[bundle]?.contains(where: { $0 === ring }) != true {
                rebuilt[bundle, default: []].append(ring)
            }
        }
        bundleRings = rebuilt
    }

    static func sourceFramesNeeded(outputFrames: Int, tapRate: Double, outputRate: Double) -> Int {
        guard outputFrames > 0, tapRate > 0, outputRate > 0 else { return outputFrames }
        if abs(tapRate - outputRate) < 0.5 { return outputFrames }
        return Int(ceil(Double(outputFrames) * tapRate / outputRate))
    }

    static func scratchFrameCapacity(tapRate: Double, outputRate: Double) -> Int {
        max(
            maxRenderFrames,
            sourceFramesNeeded(outputFrames: maxRenderFrames, tapRate: tapRate, outputRate: outputRate)
        )
    }

    func apply(session: RoutingSession, playthroughDeviceUIDs: Set<String> = []) throws {
        try configure(session: session, playthroughDeviceUIDs: playthroughDeviceUIDs)
        try activateOutputs(session: session, playthroughDeviceUIDs: playthroughDeviceUIDs)
    }

    func prepare(session: RoutingSession, playthroughDeviceUIDs: Set<String> = []) throws {
        try configure(session: session, playthroughDeviceUIDs: playthroughDeviceUIDs)
    }

    func activateOutputs(session: RoutingSession, playthroughDeviceUIDs: Set<String> = []) throws {
        configLock.lock()
        let enabledRoutes = session.sources.filter(\.enabled)
        var activeDeviceUIDs = Set(enabledRoutes.map(\.outputDeviceUID))
        for state in fadingRoutes.values {
            activeDeviceUIDs.insert(state.route.outputDeviceUID)
        }
        if session.testToneEnabled, let deviceUID = session.testToneOutputDeviceUID {
            activeDeviceUIDs.insert(deviceUID)
        }
        configLock.unlock()

        // Always prepare buffers and sync IO procs — test tone can target a device
        // that was not in the last route set, and the render callback must stay current.
        refreshDeviceOutputInfo(activeDeviceUIDs: activeDeviceUIDs, purgeStale: false)
        ensureDeviceContexts(for: activeDeviceUIDs, purgeStale: false)

        try outputManager.syncOutputs(activeDeviceUIDs: activeDeviceUIDs) { [weak self] deviceUID, maxFrames in
            self?.renderDevice(deviceUID: deviceUID, maxFrames: maxFrames) ?? (nil, 0)
        }

        configLock.lock()
        lastSyncedOutputUIDs = activeDeviceUIDs
        configLock.unlock()

        purgeStaleDeviceContexts(activeDeviceUIDs: activeDeviceUIDs)
    }

    private func configure(session: RoutingSession, playthroughDeviceUIDs: Set<String> = []) throws {
        configLock.lock()
        let enabledRoutes = session.sources.filter(\.enabled)
        let previousRoutes = activeSnapshot.routes
        let enabledRouteIDs = Set(enabledRoutes.map(\.id))
        var activeBundleIDs = Set(enabledRoutes.map { Self.bundleKey(for: $0.bundleID) })
        var activeDeviceUIDs = Set(enabledRoutes.map(\.outputDeviceUID))

        for route in previousRoutes where !enabledRouteIDs.contains(route.id) {
            let key = Self.fadingKey(for: route)
            if fadingRoutes[key] == nil {
                fadingRoutes[key] = FadingRouteState(route: route, remainingFrames: Self.fadeOutFrames)
                let bundle = Self.bundleKey(for: route.bundleID)
                let ringKey = Self.ringKey(bundleID: bundle, deviceUID: route.outputDeviceUID)
                sourceRings[ringKey]?.discardAll()
                if let context = deviceContexts[route.outputDeviceUID] {
                    context.lock.lock()
                    context.clearHoldBuffer()
                    if let mixPtr = context.mixBuffer, context.mixCapacity > 0 {
                        memset(mixPtr, 0, context.mixCapacity * MemoryLayout<Float>.size)
                    }
                    context.lock.unlock()
                }
            }
        }

        for route in enabledRoutes {
            fadingRoutes.removeValue(forKey: Self.fadingKey(for: route))
        }

        for state in fadingRoutes.values {
            activeDeviceUIDs.insert(state.route.outputDeviceUID)
            activeBundleIDs.insert(Self.bundleKey(for: state.route.bundleID))
        }

        if session.testToneEnabled, let deviceUID = session.testToneOutputDeviceUID {
            activeDeviceUIDs.insert(deviceUID)
        }

        self.playthroughDeviceUIDs = []

        var neededRingKeys = Set<String>()
        for route in enabledRoutes {
            let bundle = Self.bundleKey(for: route.bundleID)
            neededRingKeys.insert(Self.ringKey(bundleID: bundle, deviceUID: route.outputDeviceUID))
        }
        for state in fadingRoutes.values {
            let bundle = Self.bundleKey(for: state.route.bundleID)
            neededRingKeys.insert(Self.ringKey(bundleID: bundle, deviceUID: state.route.outputDeviceUID))
        }

        let fadingRingKeys = Set(fadingRoutes.values.map {
            Self.ringKey(
                bundleID: Self.bundleKey(for: $0.route.bundleID),
                deviceUID: $0.route.outputDeviceUID
            )
        })
        let staleRingKeys = Set(sourceRings.keys).subtracting(neededRingKeys).subtracting(fadingRingKeys)
        for key in staleRingKeys {
            sourceRings.removeValue(forKey: key)
        }
        for key in neededRingKeys where sourceRings[key] == nil {
            let bundle = String(key.split(separator: "|", maxSplits: 1).first ?? Substring(key))
            let channels = tapChannelCounts[bundle] ?? Self.defaultSourceChannels
            let ring = SPSCChannelRing(frameCapacity: Self.ringFrameCapacity, channelCount: channels)
            ring.discardAll()
            sourceRings[key] = ring
        }

        rebuildBundleRings(from: enabledRoutes + fadingRoutes.values.map(\.route))

        let fadingBundles = Set(fadingRoutes.values.map { Self.bundleKey(for: $0.route.bundleID) })
        for bundleID in tapSampleRates.keys where !activeBundleIDs.contains(bundleID) && !fadingBundles.contains(bundleID) {
            tapSampleRates.removeValue(forKey: bundleID)
            tapChannelCounts.removeValue(forKey: bundleID)
        }

        let previousSnapshot = activeSnapshot

        activeSnapshot = MixerSnapshot(
            routes: enabledRoutes,
            testToneEnabled: session.testToneEnabled,
            testToneDeviceUID: session.testToneOutputDeviceUID,
            testToneChannelStart: session.testToneChannels.first ?? 1,
            testToneChannels: session.testToneChannels,
            testToneSignalKind: session.testToneSignalKind,
            sampleRate: session.sampleRate
        )

        if session.testToneEnabled {
            if !previousSnapshot.testToneEnabled
                || previousSnapshot.testToneSignalKind != session.testToneSignalKind
                || previousSnapshot.testToneDeviceUID != session.testToneOutputDeviceUID
                || previousSnapshot.testToneChannels != session.testToneChannels {
                testSignalState = TestSignalGeneratorState()
            }
        } else {
            testSignalState = TestSignalGeneratorState()
        }

        for uid in activeDeviceUIDs where deviceContexts[uid] == nil {
            deviceContexts[uid] = DeviceRenderContext(scratchFrames: Self.maxRenderFrames)
        }
        configLock.unlock()
    }

    func push(
        bundleID: String,
        samples: UnsafePointer<Float>,
        frameCount: Int,
        channelCount: Int,
        sampleRate: Double
    ) {
        let key = Self.bundleKey(for: bundleID)
        configLock.lock()
        tapSampleRates[key] = sampleRate
        let resolvedCount: Int
        if SourceCatalog.isInputDeviceBundleID(key) {
            // Hardware inputs (e.g. BlackHole 64ch) can report a smaller stream format than their channel layout.
            resolvedCount = max(tapChannelCounts[key] ?? 0, channelCount)
        } else {
            resolvedCount = channelCount
        }
        if tapChannelCounts[key] != resolvedCount {
            tapChannelCounts[key] = resolvedCount
            recreateRings(forBundle: key, channelCount: resolvedCount)
        }
        let rings = bundleRings[key] ?? []
        configLock.unlock()

        for ring in rings {
            ring.write(samples, frameCount: frameCount)
        }
    }

    func renderPlaythrough(deviceUID: String, maxFrames: Int) -> (UnsafePointer<Float>?, Int) {
        renderDevice(deviceUID: deviceUID, maxFrames: maxFrames)
    }

    private func uniqueDeviceContexts(for routes: [SourceRoute]) -> [DeviceRenderContext] {
        var seen = Set<ObjectIdentifier>()
        var contexts: [DeviceRenderContext] = []
        for route in routes {
            guard let context = deviceContexts[route.outputDeviceUID] else { continue }
            let id = ObjectIdentifier(context)
            guard seen.insert(id).inserted else { continue }
            contexts.append(context)
        }
        return contexts
    }

    func resetForTapRestart(bundleID: String) {
        let key = Self.bundleKey(for: bundleID)
        configLock.lock()
        let rings = bundleRings[key] ?? []
        let routes = activeSnapshot.routes.filter { Self.bundleKey(for: $0.bundleID) == key }
        let contexts = uniqueDeviceContexts(for: routes)
        configLock.unlock()

        for context in contexts {
            context.lock.lock()
        }
        defer {
            for context in contexts {
                context.lock.unlock()
            }
        }

        for ring in rings {
            ring.discardAll()
        }
        for context in contexts {
            context.primed = false
            context.clearHoldBuffer()
        }

        configLock.lock()
        tapSampleRates.removeValue(forKey: key)
        configLock.unlock()
    }

    func stop() {
        configLock.lock()
        sourceRings.removeAll()
        bundleRings.removeAll()
        tapSampleRates.removeAll()
        tapChannelCounts.removeAll()
        fadingRoutes.removeAll()
        playthroughDeviceUIDs.removeAll()
        deviceContexts.removeAll()
        activeSnapshot = .empty
        testSignalState = TestSignalGeneratorState()
        lastSyncedOutputUIDs = []
        configLock.unlock()
        outputManager.stopAll()
    }

    func channelCount(for deviceUID: String) -> Int? {
        outputManager.channelCount(for: deviceUID)
    }
    private func ensureDeviceContexts(for deviceUIDs: Set<String>, purgeStale: Bool = true) {
        configLock.lock()
        var pending: [(DeviceRenderContext, Int, Int)] = []
        for uid in deviceUIDs {
            let context = deviceContexts[uid] ?? DeviceRenderContext(scratchFrames: Self.maxRenderFrames)
            if deviceContexts[uid] == nil {
                deviceContexts[uid] = context
            }
            let channels = context.channelCount
            let sampleCount = Self.maxRenderFrames * channels
            pending.append((context, channels, sampleCount))
        }
        let stale = purgeStale ? Set(deviceContexts.keys).subtracting(deviceUIDs) : []
        configLock.unlock()

        for (context, channels, sampleCount) in pending {
            context.lock.lock()
            context.ensureMixBuffer(channelCount: channels, sampleCount: sampleCount)
            context.lock.unlock()
        }

        guard !stale.isEmpty else { return }
        configLock.lock()
        for uid in stale {
            deviceContexts.removeValue(forKey: uid)
        }
        configLock.unlock()
    }

    private func purgeStaleDeviceContexts(activeDeviceUIDs: Set<String>) {
        configLock.lock()
        let stale = Set(deviceContexts.keys).subtracting(activeDeviceUIDs)
        configLock.unlock()
        guard !stale.isEmpty else { return }
        configLock.lock()
        for uid in stale {
            deviceContexts.removeValue(forKey: uid)
        }
        configLock.unlock()
    }

    private func refreshDeviceOutputInfo(activeDeviceUIDs: Set<String>, purgeStale: Bool = true) {
        let listed = (try? OutputDeviceEnumerator.listOutputDevices()) ?? []

        configLock.lock()
        let tapRate = tapSampleRates.values.max() ?? Self.fallbackSampleRate
        let maxSourceChannels = max(tapChannelCounts.values.max() ?? Self.defaultSourceChannels, Self.defaultSourceChannels)

        struct DeviceRefresh {
            let context: DeviceRenderContext
            let outputSampleRate: Double
            let channelCount: Int
        }
        var refreshes: [DeviceRefresh] = []
        for uid in activeDeviceUIDs {
            let context = deviceContexts[uid] ?? DeviceRenderContext(scratchFrames: Self.maxRenderFrames)
            if deviceContexts[uid] == nil {
                deviceContexts[uid] = context
            }

            let outputSampleRate: Double
            if let sinkRate = outputManager.sampleRate(for: uid) {
                outputSampleRate = sinkRate
            } else if let rate = try? OutputDeviceEnumerator.nominalSampleRate(uid: uid) {
                outputSampleRate = rate
            } else {
                outputSampleRate = Self.fallbackSampleRate
            }
            let channelCount = outputManager.channelCount(for: uid)
                ?? listed.first(where: { $0.uid == uid })?.outputChannelCount
                ?? 2
            refreshes.append(DeviceRefresh(context: context, outputSampleRate: outputSampleRate, channelCount: channelCount))
        }
        let stale = purgeStale ? Set(deviceContexts.keys).subtracting(activeDeviceUIDs) : []
        configLock.unlock()

        for refresh in refreshes {
            refresh.context.lock.lock()
            refresh.context.outputSampleRate = refresh.outputSampleRate
            refresh.context.channelCount = refresh.channelCount
            let sampleCount = Self.maxRenderFrames * refresh.channelCount
            refresh.context.ensureMixBuffer(channelCount: refresh.channelCount, sampleCount: sampleCount)
            refresh.context.ensureScratchFrames(
                Self.scratchFrameCapacity(tapRate: tapRate, outputRate: refresh.outputSampleRate),
                channelCount: maxSourceChannels
            )
            refresh.context.lock.unlock()
        }

        guard !stale.isEmpty else { return }
        configLock.lock()
        for uid in stale {
            deviceContexts.removeValue(forKey: uid)
        }
        configLock.unlock()
    }

    private static func applyLinearFadeGain(
        to buffer: UnsafeMutablePointer<Float>,
        frameCount: Int,
        channelCount: Int,
        startGain: Float,
        endGain: Float
    ) {
        guard frameCount > 0, channelCount > 0 else { return }
        if frameCount == 1 {
            for channel in 0..<channelCount {
                buffer[channel] *= startGain
            }
            return
        }
        let step = (endGain - startGain) / Float(frameCount - 1)
        for frame in 0..<frameCount {
            let gain = startGain + step * Float(frame)
            let base = frame * channelCount
            for channel in 0..<channelCount {
                buffer[base + channel] *= gain
            }
        }
    }

    private func deviceProducesOutput(
        deviceUID: String,
        snapshot: MixerSnapshot,
        fadingSnapshot: [String: FadingRouteState]
    ) -> Bool {
        if snapshot.routes.contains(where: { $0.outputDeviceUID == deviceUID }) {
            return true
        }
        if fadingSnapshot.values.contains(where: {
            $0.route.outputDeviceUID == deviceUID && $0.remainingFrames > 0
        }) {
            return true
        }
        if snapshot.testToneEnabled, snapshot.testToneDeviceUID == deviceUID {
            return true
        }
        return false
    }

    private func clearIdleDeviceOutput(context: DeviceRenderContext) {
        context.clearHoldBuffer()
        context.primed = false
    }

    private func finishCompletedFades(_ keys: [String]) {
        guard !keys.isEmpty else { return }

        configLock.lock()
        var devicesBecameIdle: [String] = []
        for key in keys {
            guard let state = fadingRoutes.removeValue(forKey: key) else { continue }
            let bundle = Self.bundleKey(for: state.route.bundleID)
            let deviceUID = state.route.outputDeviceUID
            let ringKey = Self.ringKey(bundleID: bundle, deviceUID: deviceUID)
            let ringStillNeeded = activeSnapshot.routes.contains {
                Self.bundleKey(for: $0.bundleID) == bundle && $0.outputDeviceUID == deviceUID
            } || fadingRoutes.values.contains {
                Self.bundleKey(for: $0.route.bundleID) == bundle && $0.route.outputDeviceUID == deviceUID
            }
            if !ringStillNeeded {
                sourceRings.removeValue(forKey: ringKey)
            }

            let deviceStillNeeded = activeSnapshot.routes.contains { $0.outputDeviceUID == deviceUID }
                || fadingRoutes.values.contains { $0.route.outputDeviceUID == deviceUID }
                || (activeSnapshot.testToneEnabled && activeSnapshot.testToneDeviceUID == deviceUID)
            if !deviceStillNeeded {
                devicesBecameIdle.append(deviceUID)
            }
        }
        rebuildBundleRings(from: activeSnapshot.routes + fadingRoutes.values.map(\.route))
        let idleContexts = devicesBecameIdle.compactMap { deviceContexts[$0] }
        configLock.unlock()

        for context in idleContexts {
            context.lock.lock()
            clearIdleDeviceOutput(context: context)
            context.lock.unlock()
        }

        guard !devicesBecameIdle.isEmpty else { return }
        onFadingRoutesChanged?()
    }

    private func renderBundleRoutes(
        bundleID: String,
        routes: [SourceRoute],
        ring: SPSCChannelRing,
        sourceChannels: Int,
        frames: Int,
        outputSampleRate: Double,
        tapRate: Double,
        context: DeviceRenderContext,
        router: ChannelRouter,
        mixPtr: UnsafeMutablePointer<Float>,
        outputChannelCount: Int,
        producedFrames: inout Int,
        resampleStarved: inout Bool
    ) {
        let needsResample = abs(tapRate - outputSampleRate) >= 0.5

        let tapFramesToRead: Int
        if needsResample {
            let requiredSource = Self.sourceFramesNeeded(
                outputFrames: frames,
                tapRate: tapRate,
                outputRate: outputSampleRate
            )
            context.ensureScratchFrames(requiredSource, channelCount: sourceChannels)
            guard ring.usedFrames() >= requiredSource else {
                resampleStarved = true
                return
            }
            tapFramesToRead = requiredSource
        } else {
            ring.consumerReadDebt = 0
            ring.consumerResamplePhase = 0
            tapFramesToRead = min(frames, ring.usedFrames())
            guard tapFramesToRead > 0 else { return }
        }

        let tapScratch = context.tapReadScratchPtr()
        memset(tapScratch, 0, tapFramesToRead * sourceChannels * MemoryLayout<Float>.size)
        let readFrames = ring.read(into: tapScratch, maxFrames: tapFramesToRead)
        guard readFrames == tapFramesToRead else {
            resampleStarved = true
            return
        }
        ring.trimToMaximumFrames(Self.maxRingLatencyFrames)

        let sourceScratch = context.sourceScratchPtr()
        memset(sourceScratch, 0, frames * sourceChannels * MemoryLayout<Float>.size)
        let (mixFrames, _) = AudioPCMConverter.resampleInterleavedLinear(
            source: UnsafePointer(tapScratch),
            sourceFrames: readFrames,
            sourceChannels: sourceChannels,
            sourceRate: tapRate,
            into: sourceScratch,
            destinationFrames: frames,
            destinationRate: outputSampleRate,
            sourcePhase: 0
        )
        if needsResample {
            ring.consumerResamplePhase = 0
            ring.consumerReadDebt = 0
        }
        guard mixFrames > 0 else { return }
        producedFrames = max(producedFrames, mixFrames)

        for route in routes where !route.muted {
            router.mixMonoChannel(
                sourceScratch,
                frameCount: mixFrames,
                sourceChannels: sourceChannels,
                sourceChannel: route.sourceChannel,
                outputChannel: route.outputChannel,
                into: mixPtr,
                mixChannelCount: outputChannelCount
            )
        }
    }

    private func renderDevice(deviceUID: String, maxFrames: Int) -> (UnsafePointer<Float>?, Int) {
        let frames = min(maxFrames, Self.maxRenderFrames)
        guard frames > 0 else { return (nil, 0) }

        configLock.lock()
        guard let context = deviceContexts[deviceUID] else {
            configLock.unlock()
            return (nil, 0)
        }
        let snapshot = activeSnapshot
        let rings = sourceRings
        let tapRates = tapSampleRates
        let tapChannels = tapChannelCounts
        let fadingSnapshot = fadingRoutes
        context.lock.lock()
        configLock.unlock()
        defer { context.lock.unlock() }

        let outputChannelCount = context.channelCount
        let outputSampleRate = context.outputSampleRate
        guard let mixPtr = context.mixBuffer, context.mixCapacity >= frames * outputChannelCount else {
            return (nil, 0)
        }

        let router = ChannelRouter(channelCount: outputChannelCount)

        if snapshot.testToneEnabled, snapshot.testToneDeviceUID == deviceUID {
            let routesOnDevice = snapshot.routes.filter { $0.outputDeviceUID == deviceUID && !$0.muted }
            if routesOnDevice.isEmpty {
                memset(mixPtr, 0, frames * outputChannelCount * MemoryLayout<Float>.size)
                applyTestSignal(
                    router: router,
                    snapshot: snapshot,
                    frames: frames,
                    outputSampleRate: outputSampleRate,
                    outputChannelCount: outputChannelCount,
                    mixPtr: mixPtr
                )
                return (UnsafePointer(mixPtr), frames)
            }
        }

        var routesByBundle: [String: [SourceRoute]] = [:]
        for route in snapshot.routes where route.outputDeviceUID == deviceUID {
            let bundleID = Self.bundleKey(for: route.bundleID)
            routesByBundle[bundleID, default: []].append(route)
        }

        var ringFill = 0
        for bundleID in routesByBundle.keys {
            let ringKey = Self.ringKey(bundleID: bundleID, deviceUID: deviceUID)
            if let ring = rings[ringKey] {
                ringFill = max(ringFill, ring.usedFrames())
            }
        }
        if ringFill >= Self.minPrimingFrames {
            context.primed = true
        }
        if snapshot.testToneEnabled, snapshot.testToneDeviceUID == deviceUID {
            context.primed = true
        }
        guard context.primed else { return (nil, 0) }

        memset(mixPtr, 0, frames * outputChannelCount * MemoryLayout<Float>.size)

        var producedFrames = 0
        var resampleStarved = false
        for (bundleID, routes) in routesByBundle {
            let ringKey = Self.ringKey(bundleID: bundleID, deviceUID: deviceUID)
            guard let ring = rings[ringKey] else {
                continue
            }
            let sourceChannels = tapChannels[bundleID] ?? ring.channelCount
            let tapRate = tapRates[bundleID] ?? outputSampleRate
            renderBundleRoutes(
                bundleID: bundleID,
                routes: routes,
                ring: ring,
                sourceChannels: sourceChannels,
                frames: frames,
                outputSampleRate: outputSampleRate,
                tapRate: tapRate,
                context: context,
                router: router,
                mixPtr: mixPtr,
                outputChannelCount: outputChannelCount,
                producedFrames: &producedFrames,
                resampleStarved: &resampleStarved
            )
        }

        var completedFadeKeys: [String] = []
        var fadingUpdates: [(String, Int)] = []
        for (fadeKey, fadingState) in fadingSnapshot where fadingState.route.outputDeviceUID == deviceUID {
            let route = fadingState.route
            let bundleID = Self.bundleKey(for: route.bundleID)
            let remainingAfter = max(0, fadingState.remainingFrames - frames)

            guard let ring = rings[Self.ringKey(bundleID: bundleID, deviceUID: deviceUID)], fadingState.remainingFrames > 0 else {
                completedFadeKeys.append(fadeKey)
                continue
            }

            let sourceChannels = tapChannels[bundleID] ?? ring.channelCount
            let tapRate = tapRates[bundleID] ?? outputSampleRate
            let needsResample = abs(tapRate - outputSampleRate) >= 0.5

            let tapFramesToRead: Int
            if needsResample {
                let requiredSource = Self.sourceFramesNeeded(
                    outputFrames: frames,
                    tapRate: tapRate,
                    outputRate: outputSampleRate
                )
                context.ensureScratchFrames(requiredSource, channelCount: sourceChannels)
                guard ring.usedFrames() >= requiredSource else {
                    completedFadeKeys.append(fadeKey)
                    continue
                }
                tapFramesToRead = requiredSource
            } else {
                tapFramesToRead = min(frames, ring.usedFrames())
                guard tapFramesToRead > 0 else {
                    completedFadeKeys.append(fadeKey)
                    continue
                }
            }

            let tapScratch = context.tapReadScratchPtr()
            memset(tapScratch, 0, tapFramesToRead * sourceChannels * MemoryLayout<Float>.size)
            let readFrames = ring.read(into: tapScratch, maxFrames: tapFramesToRead)
            guard readFrames == tapFramesToRead else {
                completedFadeKeys.append(fadeKey)
                continue
            }
            ring.trimToMaximumFrames(Self.maxRingLatencyFrames)

            let sourceScratch = context.sourceScratchPtr()
            memset(sourceScratch, 0, frames * sourceChannels * MemoryLayout<Float>.size)
            let (mixFrames, _) = AudioPCMConverter.resampleInterleavedLinear(
                source: UnsafePointer(tapScratch),
                sourceFrames: readFrames,
                sourceChannels: sourceChannels,
                sourceRate: tapRate,
                into: sourceScratch,
                destinationFrames: frames,
                destinationRate: outputSampleRate,
                sourcePhase: 0
            )
            guard mixFrames > 0 else {
                completedFadeKeys.append(fadeKey)
                continue
            }

            let startGain = Float(fadingState.remainingFrames) / Float(Self.fadeOutFrames)
            let endGain = Float(remainingAfter) / Float(Self.fadeOutFrames)
            Self.applyLinearFadeGain(
                to: sourceScratch,
                frameCount: mixFrames,
                channelCount: sourceChannels,
                startGain: startGain,
                endGain: endGain
            )

            if !route.muted {
                router.mixMonoChannel(
                    sourceScratch,
                    frameCount: mixFrames,
                    sourceChannels: sourceChannels,
                    sourceChannel: route.sourceChannel,
                    outputChannel: route.outputChannel,
                    into: mixPtr,
                    mixChannelCount: outputChannelCount
                )
                producedFrames = max(producedFrames, mixFrames)
            }

            fadingUpdates.append((fadeKey, remainingAfter))
            if remainingAfter <= 0 {
                completedFadeKeys.append(fadeKey)
            }
        }

        if !fadingUpdates.isEmpty || !completedFadeKeys.isEmpty {
            context.lock.unlock()
            configLock.lock()
            for (fadeKey, remainingAfter) in fadingUpdates {
                guard var state = fadingRoutes[fadeKey] else { continue }
                state.remainingFrames = remainingAfter
                fadingRoutes[fadeKey] = state
            }
            configLock.unlock()
            finishCompletedFades(completedFadeKeys)
            context.lock.lock()
        }

        if snapshot.testToneEnabled, snapshot.testToneDeviceUID == deviceUID {
            applyTestSignal(
                router: router,
                snapshot: snapshot,
                frames: frames,
                outputSampleRate: outputSampleRate,
                outputChannelCount: outputChannelCount,
                mixPtr: mixPtr
            )
            producedFrames = max(producedFrames, frames)
        }

        if producedFrames > 0 {
            return (UnsafePointer(mixPtr), producedFrames)
        }

        if resampleStarved {
            return (nil, 0)
        }

        guard deviceProducesOutput(
            deviceUID: deviceUID,
            snapshot: snapshot,
            fadingSnapshot: fadingSnapshot
        ) else {
            clearIdleDeviceOutput(context: context)
            return (nil, 0)
        }

        return (nil, 0)
    }

    private func applyTestSignal(
        router: ChannelRouter,
        snapshot: MixerSnapshot,
        frames: Int,
        outputSampleRate: Double,
        outputChannelCount: Int,
        mixPtr: UnsafeMutablePointer<Float>
    ) {
        configLock.lock()
        var state = testSignalState
        configLock.unlock()
        router.applyTestSignal(
            kind: snapshot.testToneSignalKind,
            frameCount: frames,
            outputChannels: snapshot.testToneChannels,
            sampleRate: outputSampleRate,
            state: &state,
            into: mixPtr,
            mixChannelCount: outputChannelCount
        )
        configLock.lock()
        testSignalState = state
        configLock.unlock()
    }
}

private struct MixerSnapshot: Sendable {
    var routes: [SourceRoute]
    var testToneEnabled: Bool
    var testToneDeviceUID: String?
    var testToneChannelStart: Int
    var testToneChannels: [Int]
    var testToneSignalKind: TestSignalKind
    var sampleRate: Double

    static let empty = MixerSnapshot(
        routes: [],
        testToneEnabled: false,
        testToneDeviceUID: nil,
        testToneChannelStart: 1,
        testToneChannels: [1],
        testToneSignalKind: .sine440,
        sampleRate: RealtimeMixer.fallbackSampleRate
    )
}
