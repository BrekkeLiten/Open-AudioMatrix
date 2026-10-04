import AudioMatrixCore
import Foundation

public final class InputCaptureManager: @unchecked Sendable {
    private let lock = NSLock()
    private var captures: [String: DeviceInputSource] = [:]

    public var onAudio: ((String, UnsafePointer<Float>, Int, Int, Double) -> Void)?

    public init() {}

    public func apply(session: RoutingSession) throws {
        lock.lock()
        defer { lock.unlock() }

        let enabledRoutes = session.sources.filter(\.enabled).filter {
            SourceCatalog.isInputDeviceBundleID($0.bundleID)
        }
        var bundlesNeeded = Set<String>()
        for route in enabledRoutes {
            bundlesNeeded.insert(BundleIDMatcher.parentBundleID(of: route.bundleID))
        }

        for (bundleID, capture) in captures where !bundlesNeeded.contains(bundleID) {
            capture.stop()
            captures.removeValue(forKey: bundleID)
        }

        for bundleID in bundlesNeeded {
            guard captures[bundleID] == nil,
                  let deviceUID = SourceCatalog.inputDeviceUID(from: bundleID) else {
                continue
            }
            let source = DeviceInputSource(bundleID: bundleID, deviceUID: deviceUID)
            source.onAudio = { [weak self] samples, frameCount, channelCount, sampleRate in
                self?.onAudio?(bundleID, samples, frameCount, channelCount, sampleRate)
            }
            try source.start()
            captures[bundleID] = source
        }
    }

    public func sourceChannelCounts() -> [String: Int] {
        lock.lock()
        defer { lock.unlock() }
        return captures.mapValues(\.channelCount)
    }

    public func stopAll() {
        lock.lock()
        let all = captures.values
        captures.removeAll()
        lock.unlock()
        for capture in all {
            capture.stop()
        }
    }
}
