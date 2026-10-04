import AudioMatrixCore
import CoreAudio
import Darwin
import Foundation

public final class PhysicalOutputSink: @unchecked Sendable {
    public typealias RenderCallback = (String, Int) -> (UnsafePointer<Float>?, Int)

    public let deviceUID: String
    public private(set) var channelCount: Int = 2

    public private(set) var sampleRate: Double = 48_000

    private let queue = DispatchQueue(label: "io.github.brekkeliten.openaudiomatrix.output-sink")

    private var deviceID: AudioObjectID = kAudioObjectUnknown
    private var streamFormat = AudioStreamBasicDescription()
    private var ioProcID: AudioDeviceIOProcID?
    private var isRunning = false
    private var renderCallback: RenderCallback?

    public init(deviceUID: String) {
        self.deviceUID = deviceUID
    }

    func setRenderCallback(_ callback: @escaping RenderCallback) {
        renderCallback = callback
    }

    public func start() throws {
        try queue.sync {
            guard !isRunning else { return }
            deviceID = try Self.deviceID(forUID: deviceUID)
            streamFormat = try AudioPCMConverter.readIODeviceStreamFormat(deviceID: deviceID)
            sampleRate = streamFormat.mSampleRate
            channelCount = try Self.outputChannelCount(deviceID: deviceID)

            var procID: AudioDeviceIOProcID?
            try CoreAudioHelpers.checkOSStatus(
                AudioDeviceCreateIOProcIDWithBlock(&procID, deviceID, queue) { [weak self] _, _, _, outOutputData, _ in
                    guard let self else { return }
                    self.fillOutput(outOutputData)
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
            isRunning = false
        }
    }

    private func fillOutput(_ outputData: UnsafeMutablePointer<AudioBufferList>) {
        let bufferList = UnsafeMutableAudioBufferListPointer(outputData)

        var requestedFrames = 512
        if let first = bufferList.first, first.mDataByteSize > 0 {
            let bytesPerFrame = max(Int(streamFormat.mBytesPerFrame), MemoryLayout<Float>.size * channelCount)
            requestedFrames = max(64, Int(first.mDataByteSize) / bytesPerFrame)
        }

        let format = streamFormat
        let channels = channelCount
        let (sourcePtr, frames) = renderCallback?(deviceUID, requestedFrames) ?? (nil, 0)

        guard let sourcePtr, frames > 0 else {
            for buffer in bufferList {
                guard let data = buffer.mData else { continue }
                memset(data, 0, Int(buffer.mDataByteSize))
            }
            return
        }

        AudioPCMConverter.writeInterleavedFloatFromPointer(
            sourcePtr,
            frameCount: frames,
            channelCount: channels,
            format: format,
            to: bufferList
        )
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
        throw OutputDeviceError.notFound(uid)
    }

    private static func outputChannelCount(deviceID: AudioObjectID) throws -> Int {
        var address = CoreAudioHelpers.propertyAddress(
            selector: kAudioDevicePropertyStreamConfiguration,
            scope: kAudioDevicePropertyScopeOutput
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

public final class PhysicalOutputManager: @unchecked Sendable {
    private var sinks: [String: PhysicalOutputSink] = [:]
    private let lock = NSLock()
    private var renderCallback: PhysicalOutputSink.RenderCallback?

    public init() {}

    public func syncOutputs(
        activeDeviceUIDs: Set<String>,
        render: @escaping PhysicalOutputSink.RenderCallback
    ) throws {
        renderCallback = render

        lock.lock()
        let existing = Set(sinks.keys)
        lock.unlock()

        if existing == activeDeviceUIDs {
            lock.lock()
            for sink in sinks.values {
                sink.setRenderCallback { [weak self] deviceUID, maxFrames in
                    self?.renderCallback?(deviceUID, maxFrames) ?? (nil, 0)
                }
            }
            lock.unlock()
            return
        }

        lock.lock()
        let existingForDiff = existing
        lock.unlock()

        for uid in existingForDiff.subtracting(activeDeviceUIDs) {
            lock.lock()
            sinks.removeValue(forKey: uid)?.stop()
            lock.unlock()
        }

        for uid in activeDeviceUIDs.subtracting(existingForDiff).sorted(by: Self.preferredSinkStartOrder) {
            let sink = PhysicalOutputSink(deviceUID: uid)
            sink.setRenderCallback { [weak self] deviceUID, maxFrames in
                self?.renderCallback?(deviceUID, maxFrames) ?? (nil, 0)
            }
            try sink.start()
            lock.lock()
            sinks[uid] = sink
            lock.unlock()
        }

        lock.lock()
        for sink in sinks.values {
            sink.setRenderCallback { [weak self] deviceUID, maxFrames in
                self?.renderCallback?(deviceUID, maxFrames) ?? (nil, 0)
            }
        }
        lock.unlock()
    }

    public func channelCount(for deviceUID: String) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        return sinks[deviceUID]?.channelCount
    }

    public func sampleRate(for deviceUID: String) -> Double? {
        lock.lock()
        defer { lock.unlock() }
        return sinks[deviceUID]?.sampleRate
    }

    public func stopAll() {
        lock.lock()
        let all = sinks.values
        sinks.removeAll()
        lock.unlock()
        for sink in all {
            sink.stop()
        }
    }

    private static func preferredSinkStartOrder(_ lhs: String, _ rhs: String) -> Bool {
        let lhsHeadphone = lhs.localizedCaseInsensitiveContains("headphone")
        let rhsHeadphone = rhs.localizedCaseInsensitiveContains("headphone")
        if lhsHeadphone != rhsHeadphone { return lhsHeadphone && !rhsHeadphone }
        return lhs < rhs
    }
}
