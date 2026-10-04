import AudioMatrixCore
import AVFoundation
import CoreAudio
import Darwin
import Foundation
import os

public final class ProcessTapSource: @unchecked Sendable {
    public let bundleID: String
    /// Output devices this app routes to — excluded from tap clock selection.
    public let avoidDeviceUIDs: [String]
    /// When set, routed audio is rendered through the tap aggregate instead of a separate output sink.
    public let playthroughDeviceUID: String?

    private let logger = Logger(subsystem: "io.github.brekkeliten.openaudiomatrix", category: "ProcessTap")
    private let queue = DispatchQueue(label: "io.github.brekkeliten.openaudiomatrix.process-tap")

    private var tapID: AudioObjectID = kAudioObjectUnknown
    private var aggregateDeviceID: AudioObjectID = kAudioObjectUnknown
    private var ioProcID: AudioDeviceIOProcID?
    private var inputFormat: AVAudioFormat?
    private var outputFormat: AVAudioFormat?
    private var captureScratch = [Float](repeating: 0, count: 4096 * 16)
    private var trackedProcessObjects: [AudioObjectID] = []
    private var trackedAvoidDeviceUIDs: Set<String> = []
    private var trackedPlaythroughDeviceUID: String?
    private var isRunning = false

    public var onAudio: ((UnsafePointer<Float>, Int, Int, Double) -> Void)?
    public var playthroughRender: ((String, Int) -> (UnsafePointer<Float>?, Int))?
    public var onWillRestart: (() -> Void)?
    public private(set) var sampleRate: Double = 48_000
    public private(set) var channelCount: Int = 2

    public init(
        bundleID: String,
        avoidDeviceUIDs: [String],
        playthroughDeviceUID: String? = nil
    ) {
        self.bundleID = bundleID
        self.avoidDeviceUIDs = avoidDeviceUIDs
        self.playthroughDeviceUID = playthroughDeviceUID
    }

    /// Backward-compatible single-device initializer.
    public convenience init(bundleID: String, routeDeviceUID: String) {
        self.init(bundleID: bundleID, avoidDeviceUIDs: [routeDeviceUID])
    }

    public func start() throws {
        try queue.sync {
            guard !isRunning else { return }
            trackedProcessObjects = try ProcessEnumerator.processObjectIDs(matchingBundleID: bundleID)
            try createTap()
            isRunning = true
        }
    }

    public func stop() {
        queue.sync {
            guard isRunning else { return }
            teardownTap()
            trackedProcessObjects = []
            isRunning = false
        }
    }

    @discardableResult
    public func restartIfNeeded() throws -> Bool {
        try queue.sync {
            let processObjects = try ProcessEnumerator.processObjectIDs(matchingBundleID: bundleID)
            if !SourceCatalog.isSystemSoundsBundleID(bundleID), processObjects.isEmpty {
                return false
            }
            if isRunning,
               Set(processObjects) == Set(trackedProcessObjects),
               Set(avoidDeviceUIDs) == trackedAvoidDeviceUIDs,
               playthroughDeviceUID == trackedPlaythroughDeviceUID {
                return false
            }
            if isRunning {
                onWillRestart?()
                teardownTap()
            }
            trackedProcessObjects = processObjects
            try createTap()
            isRunning = true
            return true
        }
    }

    private func createTap() throws {
        let processObjects = try ProcessEnumerator.processObjectIDs(matchingBundleID: bundleID)
        // The aggregate clock stays on a stable built-in device. The tap itself uses a
        // device-independent mixdown so it captures the process regardless of which
        // device is the system default (a per-device tap only captures audio sent to
        // that one device and fails outright on virtual devices like NDI).
        let clockDeviceUID = try CoreAudioHelpers.tapClockDeviceUID(avoiding: avoidDeviceUIDs)
        trackedAvoidDeviceUIDs = Set(avoidDeviceUIDs)
        trackedPlaythroughDeviceUID = nil

        let description: CATapDescription
        if SourceCatalog.isSystemSoundsBundleID(bundleID) {
            if processObjects.isEmpty {
                let excludeObjects = try ProcessEnumerator.userFacingProcessObjectIDs()
                description = CATapDescription(stereoGlobalTapButExcludeProcesses: excludeObjects)
            } else {
                description = CATapDescription(stereoMixdownOfProcesses: processObjects)
            }
        } else {
            guard !processObjects.isEmpty else {
                throw ProcessTapError.noMatchingProcess(bundleID)
            }
            description = CATapDescription(stereoMixdownOfProcesses: processObjects)
        }

        let tapUUID = UUID()
        description.name = "OpenAudioMatrix-\(bundleID)"
        description.uuid = tapUUID
        description.isPrivate = true
        description.muteBehavior = CATapMuteBehavior.muted

        var createdTapID = AudioObjectID(kAudioObjectUnknown)
        try CoreAudioHelpers.checkOSStatus(
            AudioHardwareCreateProcessTap(description, &createdTapID),
            operation: "AudioHardwareCreateProcessTap"
        )
        tapID = createdTapID

        let aggregateUID = "io.github.brekkeliten.openaudiomatrix.aggregate.\(UUID().uuidString)"
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Open AudioMatrix Aggregate \(bundleID)",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey: clockDeviceUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: false,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: clockDeviceUID],
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUUID.uuidString,
                    kAudioSubTapDriftCompensationKey: true,
                ],
            ],
        ]

        var createdAggregateID = AudioObjectID(kAudioObjectUnknown)
        try CoreAudioHelpers.checkOSStatus(
            AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &createdAggregateID),
            operation: "AudioHardwareCreateAggregateDevice"
        )
        aggregateDeviceID = createdAggregateID

        Thread.sleep(forTimeInterval: 0.05)

        var asbd = AudioStreamBasicDescription()
        var address = CoreAudioHelpers.propertyAddress(selector: kAudioTapPropertyFormat)
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try CoreAudioHelpers.checkOSStatus(
            AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd),
            operation: "kAudioTapPropertyFormat"
        )

        guard let audioFormat = AVAudioFormat(streamDescription: &asbd) else {
            throw ProcessTapError.invalidFormat
        }
        inputFormat = audioFormat
        sampleRate = audioFormat.sampleRate
        channelCount = max(Int(audioFormat.channelCount), 1)

        var outputASBD = try AudioPCMConverter.readIODeviceStreamFormat(deviceID: aggregateDeviceID)
        guard let aggregateOutputFormat = AVAudioFormat(streamDescription: &outputASBD) else {
            throw ProcessTapError.invalidFormat
        }
        outputFormat = aggregateOutputFormat

        let scratchSamples = 4096 * channelCount
        if captureScratch.count < scratchSamples {
            captureScratch = [Float](repeating: 0, count: scratchSamples)
        }

        var procID: AudioDeviceIOProcID?
        try CoreAudioHelpers.checkOSStatus(
            AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateDeviceID, queue) { [weak self] _, inInput, _, outOutput, _ in
                guard let self else { return }
                self.handleIO(inputData: inInput, outputData: outOutput)
            },
            operation: "AudioDeviceCreateIOProcIDWithBlock"
        )
        ioProcID = procID

        if let procID {
            try CoreAudioHelpers.checkOSStatus(
                AudioDeviceStart(aggregateDeviceID, procID),
                operation: "AudioDeviceStart"
            )
        }

        logger.info(
            "Tap started for \(self.bundleID, privacy: .public): \(self.channelCount) ch @ \(self.sampleRate, privacy: .public) Hz"
        )
    }

    private func handleIO(
        inputData: UnsafePointer<AudioBufferList>,
        outputData: UnsafeMutablePointer<AudioBufferList>
    ) {
        let outputList = UnsafeMutableAudioBufferListPointer(outputData)
        for buffer in outputList {
            guard let data = buffer.mData else { continue }
            memset(data, 0, Int(buffer.mDataByteSize))
        }

        guard let inputFormat else { return }

        let result = AudioPCMConverter.interleavedMultichannelFloatIntoBuffer(
            from: inputData,
            format: inputFormat,
            maxFrames: 4096,
            buffer: &captureScratch
        )
        guard result.frameCount > 0, result.channelCount > 0 else { return }

        let deliveryRate = outputFormat?.sampleRate ?? sampleRate
        captureScratch.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return }
            onAudio?(base, result.frameCount, result.channelCount, deliveryRate)
        }
    }

    private func teardownTap() {
        if let procID = ioProcID, aggregateDeviceID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateDeviceID, procID)
            AudioDeviceDestroyIOProcID(aggregateDeviceID, procID)
        }
        ioProcID = nil

        if aggregateDeviceID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = kAudioObjectUnknown
        }

        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }

        inputFormat = nil
        outputFormat = nil
    }
}

public enum ProcessTapError: Error, CustomStringConvertible {
    case noMatchingProcess(String)
    case invalidFormat

    public var description: String {
        switch self {
        case .noMatchingProcess(let bundleID):
            "No active audio process found for bundle ID \(bundleID)"
        case .invalidFormat:
            "Unable to read tap audio format"
        }
    }
}
