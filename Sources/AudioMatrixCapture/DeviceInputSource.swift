import AudioMatrixCore
import AVFoundation
import CoreAudio
import Darwin
import Foundation

public final class DeviceInputSource: @unchecked Sendable {
    public let bundleID: String
    public let deviceUID: String

    public private(set) var channelCount: Int = 2
    public private(set) var sampleRate: Double = 48_000

    private let queue = DispatchQueue(label: "io.github.brekkeliten.openaudiomatrix.device-input")

    private var deviceID: AudioObjectID = kAudioObjectUnknown
    private var streamFormat = AudioStreamBasicDescription()
    private var audioFormat: AVAudioFormat?
    private var ioProcID: AudioDeviceIOProcID?
    private var isRunning = false
    private var captureScratch = [Float](repeating: 0, count: 4096 * 64)

    public var onAudio: ((UnsafePointer<Float>, Int, Int, Double) -> Void)?

    public init(bundleID: String, deviceUID: String) {
        self.bundleID = bundleID
        self.deviceUID = deviceUID
    }

    public func start() throws {
        try queue.sync {
            guard !isRunning else { return }
            deviceID = try Self.deviceID(forUID: deviceUID)
            streamFormat = try AudioPCMConverter.readInputDeviceStreamFormat(deviceID: deviceID)
            sampleRate = streamFormat.mSampleRate
            channelCount = try Self.inputChannelCount(deviceID: deviceID)
            guard channelCount > 0 else {
                throw InputDeviceError.notFound(deviceUID)
            }

            audioFormat = withUnsafePointer(to: &streamFormat) { ptr in
                AVAudioFormat(streamDescription: ptr)
            } ?? AVAudioFormat(
                standardFormatWithSampleRate: sampleRate,
                channels: AVAudioChannelCount(min(channelCount, 64))
            )

            var procID: AudioDeviceIOProcID?
            try CoreAudioHelpers.checkOSStatus(
                AudioDeviceCreateIOProcIDWithBlock(&procID, deviceID, queue) { [weak self] _, inInputData, _, outOutputData, _ in
                    guard let self else { return }
                    self.handleInput(inInputData)
                    self.silenceOutput(outOutputData)
                },
                operation: "AudioDeviceCreateIOProcIDWithBlock"
            )
            ioProcID = procID

            if let procID {
                try CoreAudioHelpers.checkOSStatus(
                    AudioDeviceStart(deviceID, procID),
                    operation: "AudioDeviceStart"
                )
            }
            isRunning = true
        }
    }

    public func stop() {
        queue.sync {
            guard isRunning else { return }
            if let procID = ioProcID, deviceID != kAudioObjectUnknown {
                AudioDeviceStop(deviceID, procID)
                AudioDeviceDestroyIOProcID(deviceID, procID)
            }
            ioProcID = nil
            deviceID = kAudioObjectUnknown
            audioFormat = nil
            isRunning = false
        }
    }

    private func handleInput(_ inputData: UnsafePointer<AudioBufferList>) {
        guard let audioFormat else { return }
        let result = AudioPCMConverter.interleavedMultichannelFloatIntoBuffer(
            from: inputData,
            format: audioFormat,
            maxFrames: 4096,
            buffer: &captureScratch
        )
        guard result.frameCount > 0, result.channelCount > 0 else { return }
        captureScratch.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            onAudio?(base, result.frameCount, result.channelCount, sampleRate)
        }
    }

    private func silenceOutput(_ outputData: UnsafeMutablePointer<AudioBufferList>) {
        let bufferList = UnsafeMutableAudioBufferListPointer(outputData)
        for buffer in bufferList {
            guard let data = buffer.mData else { continue }
            memset(data, 0, Int(buffer.mDataByteSize))
        }
    }

    private static func deviceID(forUID uid: String) throws -> AudioObjectID {
        let deviceIDs = try CoreAudioHelpers.getPropertyDataArray(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyDevices
        )
        for deviceID in deviceIDs {
            let deviceUID = try CoreAudioHelpers.readStringProperty(
                objectID: deviceID,
                selector: kAudioDevicePropertyDeviceUID
            )
            if deviceUID == uid {
                return deviceID
            }
        }
        throw InputDeviceError.notFound(uid)
    }

    private static func inputChannelCount(deviceID: AudioObjectID) throws -> Int {
        var address = CoreAudioHelpers.propertyAddress(
            selector: kAudioDevicePropertyStreamConfiguration,
            scope: kAudioDevicePropertyScopeInput
        )
        var size: UInt32 = 0
        try CoreAudioHelpers.checkOSStatus(
            AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size),
            operation: "stream configuration size"
        )
        guard size > 0 else { return 0 }

        let bufferList = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(size))
        defer { bufferList.deallocate() }

        try CoreAudioHelpers.checkOSStatus(
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, bufferList),
            operation: "stream configuration"
        )

        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}
