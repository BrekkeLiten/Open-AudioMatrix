import Foundation
import Synchronization

/// Lock-free single-producer / single-consumer ring for interleaved multichannel float samples.
final class SPSCChannelRing: @unchecked Sendable {
    let channelCount: Int
    private let frameCapacity: Int
    private let storage: UnsafeMutablePointer<Float>
    private let writeIndex = Atomic<UInt32>(0)
    private let readIndex = Atomic<UInt32>(0)

    /// Consumer-only resampling bookkeeping (one IO thread per ring).
    var consumerReadDebt: Double = 0
    var consumerResamplePhase: Double = 0

    init(frameCapacity: Int, channelCount: Int) {
        self.channelCount = max(channelCount, 1)
        self.frameCapacity = max(frameCapacity, 64)
        storage = UnsafeMutablePointer<Float>.allocate(capacity: self.frameCapacity * self.channelCount)
        storage.initialize(repeating: 0, count: self.frameCapacity * self.channelCount)
    }

    deinit {
        storage.deallocate()
    }

    func write(_ samples: UnsafePointer<Float>, frameCount: Int) {
        guard frameCount > 0 else { return }
        let write = writeIndex.load(ordering: .acquiring)
        let read = readIndex.load(ordering: .acquiring)
        let used = write &- read
        let available = UInt32(frameCapacity) &- used
        let toWrite = min(UInt32(frameCount), available)
        guard toWrite > 0 else { return }

        let channels = channelCount
        for frame in 0..<Int(toWrite) {
            let dstFrame = Int((write &+ UInt32(frame)) % UInt32(frameCapacity))
            let dstBase = dstFrame * channels
            let srcBase = frame * channels
            for ch in 0..<channels {
                storage[dstBase + ch] = samples[srcBase + ch]
            }
        }
        writeIndex.store(write &+ toWrite, ordering: .releasing)
    }

    func read(into destination: UnsafeMutablePointer<Float>, maxFrames: Int) -> Int {
        guard maxFrames > 0 else { return 0 }
        let write = writeIndex.load(ordering: .acquiring)
        let read = readIndex.load(ordering: .acquiring)
        let available = write &- read
        let toRead = min(UInt32(maxFrames), available)
        guard toRead > 0 else { return 0 }

        let channels = channelCount
        for frame in 0..<Int(toRead) {
            let srcFrame = Int((read &+ UInt32(frame)) % UInt32(frameCapacity))
            let srcBase = srcFrame * channels
            let dstBase = frame * channels
            for ch in 0..<channels {
                destination[dstBase + ch] = storage[srcBase + ch]
            }
        }
        readIndex.store(read &+ toRead, ordering: .releasing)
        return Int(toRead)
    }

    func trimToMaximumFrames(_ maxFrames: Int) {
        guard maxFrames > 0 else { return }
        let write = writeIndex.load(ordering: .acquiring)
        let read = readIndex.load(ordering: .acquiring)
        let used = Int(write &- read)
        guard used > maxFrames else { return }
        readIndex.store(write &- UInt32(maxFrames), ordering: .releasing)
    }

    func usedFrames() -> Int {
        let write = writeIndex.load(ordering: .acquiring)
        let read = readIndex.load(ordering: .acquiring)
        return Int(write &- read)
    }

    func discardAll() {
        readIndex.store(writeIndex.load(ordering: .acquiring), ordering: .releasing)
        consumerReadDebt = 0
        consumerResamplePhase = 0
    }
}
