import AudioMatrixCore
import AudioMatrixCapture
import Foundation
import os

final class MixerEngine: @unchecked Sendable {
    private let tapManager = ProcessTapManager()
    private let inputCaptureManager = InputCaptureManager()
    private let mixer = RealtimeMixer()
    private let stateLock = NSLock()
    private let applyQueue = DispatchQueue(label: "io.github.brekkeliten.openaudiomatrix.mixer-apply")
    private var suppressSelfInflictedDeviceResync = false
    private var pendingOutputResync = false

    private var session = RoutingSession()
    private var running = false
    private var processWatchTimer: DispatchSourceTimer?
    private var levelDecayTimer: DispatchSourceTimer?
    private var latestLevels: [String: Float] = [:]

    init() {
        tapManager.playthroughRender = { [weak self] deviceUID, maxFrames in
            guard let self else { return (nil, 0) }
            return self.mixer.renderPlaythrough(deviceUID: deviceUID, maxFrames: maxFrames)
        }
        tapManager.onTapWillRestart = { [weak self] bundleID in
            self?.mixer.resetForTapRestart(bundleID: bundleID)
        }
        mixer.onFadingRoutesChanged = { [weak self] in
            self?.enqueueOutputSync()
        }
        mixer.onDeviceOutputsNeedResync = { [weak self] in
            self?.enqueueOutputResync()
        }
        tapManager.onAudio = { [weak self] bundleID, samples, frameCount, channelCount, sampleRate in
            guard let self else { return }
            self.deliverSourceAudio(
                bundleID: bundleID,
                samples: samples,
                frameCount: frameCount,
                channelCount: channelCount,
                sampleRate: sampleRate
            )
        }
        inputCaptureManager.onAudio = { [weak self] bundleID, samples, frameCount, channelCount, sampleRate in
            guard let self else { return }
            self.deliverSourceAudio(
                bundleID: bundleID,
                samples: samples,
                frameCount: frameCount,
                channelCount: channelCount,
                sampleRate: sampleRate
            )
        }
    }

    private func deliverSourceAudio(
        bundleID: String,
        samples: UnsafePointer<Float>,
        frameCount: Int,
        channelCount: Int,
        sampleRate: Double
    ) {
        mixer.push(
            bundleID: bundleID,
            samples: samples,
            frameCount: frameCount,
            channelCount: channelCount,
            sampleRate: sampleRate
        )
        let channels = max(channelCount, 1)
        stateLock.lock()
        var bundlePeak: Float = latestLevels[bundleID] ?? 0
        for channel in 0..<channels {
            var peak: Float = 0
            for frame in 0..<frameCount {
                peak = max(peak, abs(samples[frame * channels + channel]))
            }
            guard peak > 0 else { continue }
            let key = SourceLevelCodec.channelKey(bundleID: bundleID, monoChannel: channel + 1)
            let current = latestLevels[key] ?? 0
            let updated = max(peak, current)
            latestLevels[key] = updated
            bundlePeak = max(bundlePeak, updated)
        }
        if bundlePeak > 0 {
            latestLevels[bundleID] = bundlePeak
        }
        stateLock.unlock()
    }

    private func decayLevels() {
        stateLock.lock()
        var keysToRemove: [String] = []
        for (bundleID, level) in latestLevels {
            let decayed = level * 0.72
            if decayed < 0.002 {
                keysToRemove.append(bundleID)
            } else {
                latestLevels[bundleID] = decayed
            }
        }
        for bundleID in keysToRemove {
            latestLevels.removeValue(forKey: bundleID)
        }
        stateLock.unlock()
    }

    var currentSession: RoutingSession {
        stateLock.lock()
        defer { stateLock.unlock() }
        return session
    }

    var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return running
    }

    var levels: [String: Float] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return latestLevels
    }

    var sourceChannelCounts: [String: Int] {
        var counts = tapManager.sourceChannelCounts()
        for (bundleID, channelCount) in inputCaptureManager.sourceChannelCounts() {
            counts[bundleID] = channelCount
        }
        return counts
    }

    func updateSession(_ newSession: RoutingSession) throws {
        stateLock.lock()
        session = newSession
        let activeSession = session
        let shouldRun = running
        stateLock.unlock()

        if shouldRun {
            try enqueueApplySession(session: activeSession)
        } else {
            try applyQueue.sync {
                try mixer.prepare(session: activeSession)
            }
        }
    }

    func start(session: RoutingSession) throws {
        stateLock.lock()
        self.session = session
        let alreadyRunning = running
        running = true
        stateLock.unlock()

        try enqueueApplySession(session: session)

        if !alreadyRunning {
            startProcessWatcher()
            startLevelDecay()
        }
    }

    func stop() {
        applyQueue.sync {
            stateLock.lock()
            running = false
            latestLevels = [:]
            stateLock.unlock()

            processWatchTimer?.cancel()
            processWatchTimer = nil
            levelDecayTimer?.cancel()
            levelDecayTimer = nil

            tapManager.stopAll()
            inputCaptureManager.stopAll()
            mixer.stop()
        }
    }

    private func enqueueApplySession(session: RoutingSession) throws {
        try applyQueue.sync {
            try applySession(session)
        }
    }

    private func enqueueOutputSync() {
        applyQueue.async { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            let session = self.session
            let shouldRun = self.running
            self.stateLock.unlock()
            guard shouldRun else { return }
            try? self.mixer.activateOutputs(session: session, playthroughDeviceUIDs: [])
        }
    }

    private func enqueueOutputResync() {
        let skip = suppressSelfInflictedDeviceResync
        applyQueue.async { [weak self] in
            guard let self else { return }
            if skip {
                return
            }
            if self.pendingOutputResync {
                return
            }
            self.pendingOutputResync = true
            defer { self.pendingOutputResync = false }

            self.stateLock.lock()
            let session = self.session
            let shouldRun = self.running
            self.stateLock.unlock()
            guard shouldRun else { return }

            try? self.mixer.activateOutputs(session: session, playthroughDeviceUIDs: [])
        }
    }

    private func applySession(_ session: RoutingSession) throws {
        try mixer.prepare(session: session, playthroughDeviceUIDs: [])
        var tapSession = session
        tapSession.sources.append(contentsOf: mixer.fadingRoutesForRetention())
        try tapManager.apply(session: tapSession, playthroughDeviceUIDs: [])
        try inputCaptureManager.apply(session: session)
        var channelCounts = tapManager.sourceChannelCounts()
        for (bundleID, count) in inputCaptureManager.sourceChannelCounts() {
            channelCounts[bundleID] = count
        }
        mixer.setTapChannelCounts(channelCounts)
        suppressSelfInflictedDeviceResync = true
        try mixer.activateOutputs(session: session, playthroughDeviceUIDs: [])
        suppressSelfInflictedDeviceResync = false
    }

    private func startProcessWatcher() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in
            self?.applyQueue.async {
                self?.tapManager.refreshTaps()
            }
        }
        timer.resume()
        processWatchTimer = timer
    }

    private func startLevelDecay() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInteractive))
        timer.schedule(deadline: .now() + .milliseconds(33), repeating: .milliseconds(33))
        timer.setEventHandler { [weak self] in
            self?.decayLevels()
        }
        timer.resume()
        levelDecayTimer = timer
    }
}
