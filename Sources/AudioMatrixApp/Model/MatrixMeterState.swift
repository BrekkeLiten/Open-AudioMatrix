import AudioMatrixCore
import Foundation
import Observation

@MainActor
@Observable
final class MatrixMeterState {
    var levels: [String: Float] = [:]

    func level(for bundleID: String) -> Float {
        if let direct = levels[bundleID] { return direct }
        let parent = BundleIDMatcher.parentBundleID(of: bundleID)
        if parent != bundleID, let parentLevel = levels[parent] {
            return parentLevel
        }
        return maxChannelLevel(for: bundleID)
    }

    func level(for bundleID: String, monoChannel: Int) -> Float {
        let key = SourceLevelCodec.channelKey(bundleID: bundleID, monoChannel: monoChannel)
        if let direct = levels[key] { return direct }
        let parent = BundleIDMatcher.parentBundleID(of: bundleID)
        guard parent != bundleID else { return 0 }
        return levels[SourceLevelCodec.channelKey(bundleID: parent, monoChannel: monoChannel)] ?? 0
    }

    /// Updates only `activeKeys` from `newLevels` when values move by more than `epsilon`.
    func applyIfChanged(
        _ newLevels: [String: Float],
        activeKeys: Set<String>,
        epsilon: Float = 0.001
    ) {
        if newLevels.isEmpty, activeKeys.isEmpty {
            guard !levels.isEmpty else { return }
            levels = [:]
            return
        }

        var changed = false
        for key in activeKeys {
            let newValue = resolvedLevel(for: key, in: newLevels)
            let oldValue = levels[key] ?? 0
            guard abs(newValue - oldValue) > epsilon else { continue }
            if newValue <= epsilon {
                if levels[key] != nil {
                    levels.removeValue(forKey: key)
                    changed = true
                }
            } else {
                levels[key] = newValue
                changed = true
            }
        }
        guard changed else { return }
    }

    private func resolvedLevel(for key: String, in newLevels: [String: Float]) -> Float {
        if let value = newLevels[key] { return value }
        if SourceLevelCodec.parseChannelKey(key) != nil { return 0 }
        let parent = BundleIDMatcher.parentBundleID(of: key)
        if parent != key, let parentLevel = newLevels[parent] {
            return parentLevel
        }
        return maxChannelLevel(for: key, in: newLevels)
    }

    private func maxChannelLevel(for bundleID: String, in source: [String: Float]? = nil) -> Float {
        let lookup = source ?? levels
        let prefix = "\(bundleID)|"
        var peak: Float = 0
        for (key, value) in lookup where key.hasPrefix(prefix) {
            peak = max(peak, value)
        }
        return peak
    }
}
