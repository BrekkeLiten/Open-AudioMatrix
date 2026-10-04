import AVFoundation
import CoreAudio
import Foundation

public enum AudioPCMConverter {
    static func readIODeviceStreamFormat(deviceID: AudioObjectID) throws -> AudioStreamBasicDescription {
        try readDeviceStreamFormat(deviceID: deviceID, scope: kAudioDevicePropertyScopeOutput)
    }

    static func readInputDeviceStreamFormat(deviceID: AudioObjectID) throws -> AudioStreamBasicDescription {
        try readDeviceStreamFormat(deviceID: deviceID, scope: kAudioDevicePropertyScopeInput)
    }

    private static func readDeviceStreamFormat(
        deviceID: AudioObjectID,
        scope: AudioObjectPropertyScope
    ) throws -> AudioStreamBasicDescription {
        var address = CoreAudioHelpers.propertyAddress(
            selector: kAudioDevicePropertyStreamFormat,
            scope: scope
        )
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try CoreAudioHelpers.checkOSStatus(
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &asbd),
            operation: "kAudioDevicePropertyStreamFormat"
        )
        return asbd
    }

    static func readOutputStreamFormat(deviceID: AudioObjectID) throws -> AudioStreamBasicDescription {
        let streams = try CoreAudioHelpers.getPropertyDataArray(
            objectID: deviceID,
            selector: kAudioDevicePropertyStreams,
            scope: kAudioDevicePropertyScopeOutput
        )
        guard let streamID = streams.first else {
            throw AudioPCMError.noOutputStream
        }

        var address = CoreAudioHelpers.propertyAddress(
            selector: kAudioStreamPropertyPhysicalFormat,
            scope: kAudioObjectPropertyScopeGlobal
        )
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try CoreAudioHelpers.checkOSStatus(
            AudioObjectGetPropertyData(streamID, &address, 0, nil, &size, &asbd),
            operation: "kAudioStreamPropertyPhysicalFormat"
        )
        return asbd
    }

    static func interleavedFloat(
        from bufferList: UnsafePointer<AudioBufferList>,
        format: AVAudioFormat,
        maxFrames: Int
    ) -> (samples: [Float], frameCount: Int) {
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
        guard let first = list.first, let data = first.mData else {
            return ([], 0)
        }

        let channels = Int(format.channelCount)
        let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
        guard bytesPerFrame > 0, channels > 0 else { return ([], 0) }

        let frameCount = min(maxFrames, Int(first.mDataByteSize) / bytesPerFrame)
        guard frameCount > 0 else { return ([], 0) }

        var output = [Float](repeating: 0, count: frameCount * 2)

        switch format.commonFormat {
        case .pcmFormatFloat32:
            let src = data.assumingMemoryBound(to: Float.self)
            if format.isInterleaved {
                for frame in 0..<frameCount {
                    output[frame * 2] = src[frame * channels]
                    output[frame * 2 + 1] = channels > 1 ? src[frame * channels + 1] : src[frame * channels]
                }
            } else {
                guard let interleavedFormat = AVAudioFormat(
                    commonFormat: .pcmFormatFloat32,
                    sampleRate: format.sampleRate,
                    channels: format.channelCount,
                    interleaved: true
                ), let buffer = AVAudioPCMBuffer(
                    pcmFormat: interleavedFormat,
                    frameCapacity: AVAudioFrameCount(frameCount)
                ) else {
                    return ([], 0)
                }
                buffer.frameLength = AVAudioFrameCount(frameCount)
                memcpy(buffer.mutableAudioBufferList.pointee.mBuffers.mData, data, frameCount * bytesPerFrame)
                guard let left = buffer.floatChannelData?[0] else { return ([], 0) }
                let right = buffer.floatChannelData?[min(1, channels - 1)]
                for frame in 0..<frameCount {
                    output[frame * 2] = left[frame]
                    output[frame * 2 + 1] = right.map { $0[frame] } ?? left[frame]
                }
            }

        case .pcmFormatInt16:
            let src = data.assumingMemoryBound(to: Int16.self)
            for frame in 0..<frameCount {
                output[frame * 2] = Float(src[frame * channels]) / Float(Int16.max)
                output[frame * 2 + 1] = channels > 1
                    ? Float(src[frame * channels + 1]) / Float(Int16.max)
                    : output[frame * 2]
            }

        case .pcmFormatInt32:
            let src = data.assumingMemoryBound(to: Int32.self)
            for frame in 0..<frameCount {
                output[frame * 2] = Float(src[frame * channels]) / Float(Int32.max)
                output[frame * 2 + 1] = channels > 1
                    ? Float(src[frame * channels + 1]) / Float(Int32.max)
                    : output[frame * 2]
            }

        default:
            return ([], 0)
        }

        return (output, frameCount)
    }

    /// Writes interleaved stereo float into a pre-allocated buffer (no heap allocation).
    static func interleavedFloatIntoBuffer(
        from bufferList: UnsafePointer<AudioBufferList>,
        format: AVAudioFormat,
        maxFrames: Int,
        buffer: inout [Float]
    ) -> Int {
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
        guard let first = list.first, let data = first.mData else {
            return 0
        }

        let channels = Int(format.channelCount)
        let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
        guard bytesPerFrame > 0, channels > 0 else { return 0 }

        let frameCount: Int
        if format.isInterleaved {
            frameCount = min(maxFrames, Int(first.mDataByteSize) / bytesPerFrame)
        } else {
            let bytesPerSample = max(bytesPerFrame, MemoryLayout<Float>.size)
            frameCount = min(maxFrames, Int(first.mDataByteSize) / bytesPerSample)
        }
        guard frameCount > 0 else { return 0 }

        let needed = frameCount * 2
        if buffer.count < needed {
            buffer = [Float](repeating: 0, count: needed)
        }

        switch format.commonFormat {
        case .pcmFormatFloat32:
            let src = data.assumingMemoryBound(to: Float.self)
            if format.isInterleaved {
                for frame in 0..<frameCount {
                    buffer[frame * 2] = src[frame * channels]
                    buffer[frame * 2 + 1] = channels > 1 ? src[frame * channels + 1] : src[frame * channels]
                }
            } else if list.count >= 2,
                      let rightData = list[1].mData?.assumingMemoryBound(to: Float.self) {
                for frame in 0..<frameCount {
                    buffer[frame * 2] = src[frame]
                    buffer[frame * 2 + 1] = rightData[frame]
                }
            } else {
                for frame in 0..<frameCount {
                    buffer[frame * 2] = src[frame]
                    buffer[frame * 2 + 1] = src[frame]
                }
            }

        case .pcmFormatInt16:
            if format.isInterleaved {
                let src = data.assumingMemoryBound(to: Int16.self)
                for frame in 0..<frameCount {
                    buffer[frame * 2] = Float(src[frame * channels]) / Float(Int16.max)
                    buffer[frame * 2 + 1] = channels > 1
                        ? Float(src[frame * channels + 1]) / Float(Int16.max)
                        : buffer[frame * 2]
                }
            } else if list.count >= 2,
                      let rightData = list[1].mData?.assumingMemoryBound(to: Int16.self) {
                let left = data.assumingMemoryBound(to: Int16.self)
                for frame in 0..<frameCount {
                    buffer[frame * 2] = Float(left[frame]) / Float(Int16.max)
                    buffer[frame * 2 + 1] = Float(rightData[frame]) / Float(Int16.max)
                }
            } else {
                let src = data.assumingMemoryBound(to: Int16.self)
                for frame in 0..<frameCount {
                    let sample = Float(src[frame]) / Float(Int16.max)
                    buffer[frame * 2] = sample
                    buffer[frame * 2 + 1] = sample
                }
            }

        case .pcmFormatInt32:
            if format.isInterleaved {
                let src = data.assumingMemoryBound(to: Int32.self)
                for frame in 0..<frameCount {
                    buffer[frame * 2] = Float(src[frame * channels]) / Float(Int32.max)
                    buffer[frame * 2 + 1] = channels > 1
                        ? Float(src[frame * channels + 1]) / Float(Int32.max)
                        : buffer[frame * 2]
                }
            } else if list.count >= 2,
                      let rightData = list[1].mData?.assumingMemoryBound(to: Int32.self) {
                let left = data.assumingMemoryBound(to: Int32.self)
                for frame in 0..<frameCount {
                    buffer[frame * 2] = Float(left[frame]) / Float(Int32.max)
                    buffer[frame * 2 + 1] = Float(rightData[frame]) / Float(Int32.max)
                }
            } else {
                let src = data.assumingMemoryBound(to: Int32.self)
                for frame in 0..<frameCount {
                    let sample = Float(src[frame]) / Float(Int32.max)
                    buffer[frame * 2] = sample
                    buffer[frame * 2 + 1] = sample
                }
            }

        default:
            return 0
        }

        return frameCount
    }

    static func writeInterleavedFloat(
        _ samples: [Float],
        frameCount: Int,
        channelCount: Int,
        format: AudioStreamBasicDescription,
        to bufferList: UnsafeMutableAudioBufferListPointer
    ) {
        samples.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return }
            writeInterleavedFloatFromPointer(
                base,
                frameCount: frameCount,
                channelCount: channelCount,
                format: format,
                to: bufferList
            )
        }
    }

    static func writeInterleavedFloatFromPointer(
        _ samples: UnsafePointer<Float>,
        frameCount: Int,
        channelCount: Int,
        format: AudioStreamBasicDescription,
        to bufferList: UnsafeMutableAudioBufferListPointer
    ) {
        for buffer in bufferList {
            guard let data = buffer.mData else { continue }
            memset(data, 0, Int(buffer.mDataByteSize))
        }

        guard frameCount > 0 else { return }

        let isFloat = format.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let isSigned = format.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0
        let bitsPerChannel = Int(format.mBitsPerChannel)

        var channelBase = 0
        for buffer in bufferList {
            guard let data = buffer.mData else { continue }
            let outChannels = Int(buffer.mNumberChannels)
            let bytesPerSample = max(bitsPerChannel / 8, 1)
            let bytesPerFrame = outChannels * bytesPerSample
            let capacityFrames = Int(buffer.mDataByteSize) / max(bytesPerFrame, 1)
            let framesToWrite = min(frameCount, capacityFrames)

            for frame in 0..<framesToWrite {
                for channel in 0..<outChannels {
                    let sourceChannelIndex = channelBase + channel
                    let sample: Float
                    if sourceChannelIndex < channelCount {
                        sample = max(-1.0, min(1.0, samples[frame * channelCount + sourceChannelIndex]))
                    } else if channelCount == 1 {
                        sample = max(-1.0, min(1.0, samples[frame * channelCount]))
                    } else {
                        sample = 0
                    }
                    let byteOffset = frame * bytesPerFrame + channel * bytesPerSample

                    if isFloat, bitsPerChannel == 32 {
                        data.advanced(by: byteOffset).assumingMemoryBound(to: Float.self).pointee = sample
                    } else if isSigned, bitsPerChannel == 16 {
                        data.advanced(by: byteOffset).assumingMemoryBound(to: Int16.self).pointee =
                            Int16(sample * Float(Int16.max))
                    } else if isSigned, bitsPerChannel == 32 {
                        data.advanced(by: byteOffset).assumingMemoryBound(to: Int32.self).pointee =
                            Int32(sample * Float(Int32.max))
                    }
                }
            }
            channelBase += outChannels
        }
    }

    /// Writes all interleaved channels into a pre-allocated buffer (no heap allocation when sized correctly).
    static func interleavedMultichannelFloatIntoBuffer(
        from bufferList: UnsafePointer<AudioBufferList>,
        format: AVAudioFormat,
        maxFrames: Int,
        buffer: inout [Float]
    ) -> (frameCount: Int, channelCount: Int) {
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
        guard let first = list.first, let data = first.mData else {
            return (0, 0)
        }

        let channels = Int(format.channelCount)
        let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
        guard bytesPerFrame > 0, channels > 0 else { return (0, 0) }

        let frameCount: Int
        if format.isInterleaved {
            frameCount = min(maxFrames, Int(first.mDataByteSize) / bytesPerFrame)
        } else {
            let bytesPerSample = max(bytesPerFrame, MemoryLayout<Float>.size)
            frameCount = min(maxFrames, Int(first.mDataByteSize) / bytesPerSample)
        }
        guard frameCount > 0 else { return (0, 0) }

        let needed = frameCount * channels
        if buffer.count < needed {
            buffer = [Float](repeating: 0, count: needed)
        }

        switch format.commonFormat {
        case .pcmFormatFloat32:
            let src = data.assumingMemoryBound(to: Float.self)
            if format.isInterleaved {
                for index in 0..<needed {
                    buffer[index] = src[index]
                }
            } else {
                for frame in 0..<frameCount {
                    for channel in 0..<channels {
                        let plane = list[min(channel, list.count - 1)].mData?.assumingMemoryBound(to: Float.self)
                        buffer[frame * channels + channel] = plane?[frame] ?? 0
                    }
                }
            }

        case .pcmFormatInt16:
            if format.isInterleaved {
                let src = data.assumingMemoryBound(to: Int16.self)
                for index in 0..<needed {
                    buffer[index] = Float(src[index]) / Float(Int16.max)
                }
            } else {
                for frame in 0..<frameCount {
                    for channel in 0..<channels {
                        let plane = list[min(channel, list.count - 1)].mData?.assumingMemoryBound(to: Int16.self)
                        let sample = plane.map { Float($0[frame]) / Float(Int16.max) } ?? 0
                        buffer[frame * channels + channel] = sample
                    }
                }
            }

        case .pcmFormatInt32:
            if format.isInterleaved {
                let src = data.assumingMemoryBound(to: Int32.self)
                for index in 0..<needed {
                    buffer[index] = Float(src[index]) / Float(Int32.max)
                }
            } else {
                for frame in 0..<frameCount {
                    for channel in 0..<channels {
                        let plane = list[min(channel, list.count - 1)].mData?.assumingMemoryBound(to: Int32.self)
                        let sample = plane.map { Float($0[frame]) / Float(Int32.max) } ?? 0
                        buffer[frame * channels + channel] = sample
                    }
                }
            }

        default:
            return (0, 0)
        }

        return (frameCount, channels)
    }

    /// Realtime-safe multichannel linear resampler.
    public static func resampleInterleavedLinear(
        source: UnsafePointer<Float>,
        sourceFrames: Int,
        sourceChannels: Int,
        sourceRate: Double,
        into destination: UnsafeMutablePointer<Float>,
        destinationFrames: Int,
        destinationRate: Double,
        sourcePhase: Double = 0
    ) -> (frames: Int, endPhase: Double) {
        guard sourceFrames > 0, destinationFrames > 0, sourceChannels > 0,
              sourceRate > 0, destinationRate > 0 else {
            return (0, sourcePhase)
        }
        if abs(sourceRate - destinationRate) < 0.5 {
            let frames = min(sourceFrames, destinationFrames)
            memcpy(destination, source, frames * sourceChannels * MemoryLayout<Float>.size)
            return (frames, sourcePhase + Double(frames))
        }

        let ratio = sourceRate / destinationRate
        for frame in 0..<destinationFrames {
            let srcPos = sourcePhase + Double(frame) * ratio
            let srcIndex = Int(srcPos)
            let frac = Float(srcPos - Double(srcIndex))
            let i0 = min(srcIndex, sourceFrames - 1)
            let i1 = min(srcIndex + 1, sourceFrames - 1)
            for channel in 0..<sourceChannels {
                let s0 = source[i0 * sourceChannels + channel]
                let s1 = source[i1 * sourceChannels + channel]
                destination[frame * sourceChannels + channel] = s0 * (1 - frac) + s1 * frac
            }
        }
        let endPhase = sourcePhase + Double(destinationFrames) * ratio
        return (destinationFrames, endPhase)
    }

    /// Realtime-safe stereo linear resampler (tap-rate → device-rate).
    public static func resampleStereoLinear(
        source: UnsafePointer<Float>,
        sourceFrames: Int,
        sourceRate: Double,
        into destination: UnsafeMutablePointer<Float>,
        destinationFrames: Int,
        destinationRate: Double,
        sourcePhase: Double = 0
    ) -> (frames: Int, endPhase: Double) {
        guard sourceFrames > 0, destinationFrames > 0, sourceRate > 0, destinationRate > 0 else {
            return (0, sourcePhase)
        }
        if abs(sourceRate - destinationRate) < 0.5 {
            let frames = min(sourceFrames, destinationFrames)
            memcpy(destination, source, frames * 2 * MemoryLayout<Float>.size)
            return (frames, sourcePhase + Double(frames))
        }

        let ratio = sourceRate / destinationRate
        for frame in 0..<destinationFrames {
            let srcPos = sourcePhase + Double(frame) * ratio
            let srcIndex = Int(srcPos)
            let frac = Float(srcPos - Double(srcIndex))
            let i0 = min(srcIndex, sourceFrames - 1)
            let i1 = min(srcIndex + 1, sourceFrames - 1)
            destination[frame * 2] = source[i0 * 2] * (1 - frac) + source[i1 * 2] * frac
            destination[frame * 2 + 1] = source[i0 * 2 + 1] * (1 - frac) + source[i1 * 2 + 1] * frac
        }
        let endPhase = sourcePhase + Double(destinationFrames) * ratio
        return (destinationFrames, endPhase)
    }
}

enum AudioPCMError: Error, CustomStringConvertible {
    case noOutputStream

    var description: String {
        switch self {
        case .noOutputStream:
            "Device has no output stream"
        }
    }
}
