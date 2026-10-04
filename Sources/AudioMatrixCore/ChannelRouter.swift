import Foundation

/// Routes multichannel source buffers into a multi-channel interleaved output buffer.
public struct ChannelRouter: Sendable {
    public let channelCount: Int

    public init(channelCount: Int = 16) {
        self.channelCount = channelCount
    }

    public func clear(_ buffer: inout [Float]) {
        guard !buffer.isEmpty else { return }
        buffer.withUnsafeMutableBufferPointer { ptr in
            ptr.initialize(repeating: 0)
        }
    }

    /// Mix one source channel into one output channel (mono routing).
    public func mixMonoChannel(
        _ source: UnsafePointer<Float>,
        frameCount: Int,
        sourceChannels: Int,
        sourceChannel: Int,
        outputChannel: Int,
        into buffer: UnsafeMutablePointer<Float>,
        mixChannelCount channels: Int? = nil
    ) {
        guard frameCount > 0, sourceChannels > 0 else { return }
        let mixChannels = channels ?? channelCount
        let sourceIndex = sourceChannel - 1
        let outputIndex = outputChannel - 1
        guard sourceIndex >= 0, sourceIndex < sourceChannels,
              outputIndex >= 0, outputIndex < mixChannels else { return }

        for frame in 0..<frameCount {
            buffer[frame * mixChannels + outputIndex] += source[frame * sourceChannels + sourceIndex]
        }
    }

    public func mixStereoSource(
        _ source: UnsafePointer<Float>,
        frameCount: Int,
        channelStart: Int,
        into buffer: inout [Float]
    ) {
        guard frameCount > 0, !buffer.isEmpty else { return }
        buffer.withUnsafeMutableBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return }
            mixStereoSource(source, frameCount: frameCount, channelStart: channelStart, into: base, mixChannelCount: channelCount)
        }
    }

    /// Realtime-safe stereo mix into a pre-allocated interleaved multichannel buffer.
    public func mixStereoSource(
        _ source: UnsafePointer<Float>,
        frameCount: Int,
        channelStart: Int,
        into buffer: UnsafeMutablePointer<Float>,
        mixChannelCount channels: Int? = nil
    ) {
        guard frameCount > 0 else { return }
        let mixChannels = channels ?? channelCount
        let leftIndex = channelStart - 1
        let rightIndex = channelStart
        guard leftIndex >= 0, rightIndex < mixChannels else { return }

        for frame in 0..<frameCount {
            let base = frame * mixChannels
            buffer[base + leftIndex] += source[frame * 2]
            buffer[base + rightIndex] += source[frame * 2 + 1]
        }
    }

    public func applyTestTone(
        frameCount: Int,
        channelStart: Int,
        sampleRate: Double,
        frequency: Double,
        phase: inout Double,
        into buffer: inout [Float]
    ) {
        guard !buffer.isEmpty else { return }
        buffer.withUnsafeMutableBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return }
            applyTestTone(
                frameCount: frameCount,
                channelStart: channelStart,
                sampleRate: sampleRate,
                frequency: frequency,
                phase: &phase,
                into: base,
                mixChannelCount: channelCount
            )
        }
    }

    public func applyTestTone(
        frameCount: Int,
        channelStart: Int,
        sampleRate: Double,
        frequency: Double,
        phase: inout Double,
        into buffer: UnsafeMutablePointer<Float>,
        mixChannelCount channels: Int? = nil
    ) {
        var state = TestSignalGeneratorState(sinePhase: phase)
        applyTestSignal(
            kind: .sine440,
            frameCount: frameCount,
            channelStart: channelStart,
            sampleRate: sampleRate,
            state: &state,
            into: buffer,
            mixChannelCount: channels
        )
        phase = state.sinePhase
    }

    public func applyTestSignal(
        kind: TestSignalKind,
        frameCount: Int,
        channelStart: Int,
        sampleRate: Double,
        state: inout TestSignalGeneratorState,
        into buffer: UnsafeMutablePointer<Float>,
        mixChannelCount channels: Int? = nil
    ) {
        applyTestSignal(
            kind: kind,
            frameCount: frameCount,
            outputChannels: [channelStart],
            sampleRate: sampleRate,
            state: &state,
            into: buffer,
            mixChannelCount: channels
        )
    }

    public func applyTestSignal(
        kind: TestSignalKind,
        frameCount: Int,
        outputChannels: [Int],
        sampleRate: Double,
        state: inout TestSignalGeneratorState,
        into buffer: UnsafeMutablePointer<Float>,
        mixChannelCount channels: Int? = nil
    ) {
        let mixChannels = channels ?? channelCount
        let indices = outputChannels
            .map { $0 - 1 }
            .filter { $0 >= 0 && $0 < mixChannels }
        guard !indices.isEmpty else { return }

        let sineAmplitude: Float = 0.2
        let noiseAmplitude: Float = 0.15
        let phaseIncrement = 2.0 * Double.pi * 440.0 / sampleRate

        for frame in 0..<frameCount {
            let sample: Float
            switch kind {
            case .sine440:
                sample = Float(sin(state.sinePhase)) * sineAmplitude
                state.sinePhase += phaseIncrement
                if state.sinePhase > 2.0 * Double.pi {
                    state.sinePhase -= 2.0 * Double.pi
                }
            case .whiteNoise:
                sample = Self.nextWhiteNoiseSample(seed: &state.whiteSeed, amplitude: noiseAmplitude)
            case .pinkNoise:
                sample = Self.nextPinkNoiseSample(state: &state, amplitude: noiseAmplitude)
            }

            let base = frame * mixChannels
            for index in indices {
                buffer[base + index] += sample
            }
        }
    }

    private static func nextWhiteNoiseSample(seed: inout UInt32, amplitude: Float) -> Float {
        seed ^= seed &<< 13
        seed ^= seed &>> 17
        seed ^= seed &<< 5
        let normalized = Float(Int32(bitPattern: seed)) / Float(Int32.max)
        return normalized * amplitude
    }

    /// Paul Kellet's economical pink-noise filter.
    private static func nextPinkNoiseSample(state: inout TestSignalGeneratorState, amplitude: Float) -> Float {
        let white = nextWhiteNoiseSample(seed: &state.whiteSeed, amplitude: 1)
        state.pinkB0 = 0.99886 * state.pinkB0 + white * 0.0555179
        state.pinkB1 = 0.99332 * state.pinkB1 + white * 0.0750759
        state.pinkB2 = 0.96900 * state.pinkB2 + white * 0.1538520
        state.pinkB3 = 0.86650 * state.pinkB3 + white * 0.3104856
        state.pinkB4 = 0.55000 * state.pinkB4 + white * 0.5329522
        state.pinkB5 = -0.7616 * state.pinkB5 - white * 0.0168980
        let pink = state.pinkB0 + state.pinkB1 + state.pinkB2 + state.pinkB3
            + state.pinkB4 + state.pinkB5 + state.pinkB6 + white * 0.5362
        state.pinkB6 = white * 0.115926
        return pink * amplitude
    }

    public func peakLevel(
        _ buffer: UnsafePointer<Float>,
        frameCount: Int,
        channelStart: Int,
        channelCount mixChannelCount: Int? = nil
    ) -> Float {
        let mixChannels = mixChannelCount ?? channelCount
        let leftIndex = channelStart - 1
        let rightIndex = channelStart
        guard leftIndex >= 0, rightIndex < mixChannels else { return 0 }

        var peak: Float = 0
        for frame in 0..<frameCount {
            let base = frame * mixChannels
            guard base + rightIndex < frameCount * mixChannels else { break }
            peak = max(peak, abs(buffer[base + leftIndex]))
            peak = max(peak, abs(buffer[base + rightIndex]))
        }
        return peak
    }

    public func validateMonoChannel(_ channel: Int, channelCount: Int) throws {
        guard channel >= 1 else {
            throw ChannelRouterError.invalidChannel(channel)
        }
        guard channel <= channelCount else {
            throw ChannelRouterError.channelOutOfRange(channel)
        }
    }

    public func validateAssignment(
        sourceChannel: Int,
        outputChannel: Int,
        sourceChannelCount: Int,
        bundleID: String,
        sources: [SourceRoute],
        outputDeviceUID: String,
        outputChannelCount: Int
    ) throws {
        try validateMonoChannel(sourceChannel, channelCount: sourceChannelCount)
        try validateMonoChannel(outputChannel, channelCount: outputChannelCount)
        let parent = BundleIDMatcher.parentBundleID(of: bundleID)
        for source in sources where source.enabled {
            if BundleIDMatcher.parentBundleID(of: source.bundleID) == parent,
               source.outputDeviceUID == outputDeviceUID,
               source.sourceChannel == sourceChannel,
               source.outputChannel == outputChannel {
                throw ChannelRouterError.duplicateRoute(bundleID)
            }
        }
    }
}

public enum ChannelRouterError: Error, CustomStringConvertible {
    case invalidChannel(Int)
    case channelOutOfRange(Int)
    case overlap
    case duplicateRoute(String)

    public var description: String {
        switch self {
        case .invalidChannel(let ch):
            "Channel must be >= 1; got \(ch)"
        case .channelOutOfRange(let ch):
            "Channel \(ch) exceeds device channel count"
        case .overlap:
            "Channel assignment overlaps an existing source"
        case .duplicateRoute(let bundleID):
            "Route already exists for \(bundleID) on this device and channel"
        }
    }
}
