import Foundation

public enum SourceCatalog {
    /// Virtual bundle ID for aggregated macOS system sounds (non-user-facing com.apple.* processes).
    public static let systemSoundsBundleID = "io.github.brekkeliten.openaudiomatrix.system-sounds"
    public static let inputDevicePrefix = "io.github.brekkeliten.openaudiomatrix.input."

    public static func isSystemSoundsBundleID(_ bundleID: String) -> Bool {
        bundleID == systemSoundsBundleID
    }

    public static func inputDeviceBundleID(uid: String) -> String {
        inputDevicePrefix + uid
    }

    public static func isInputDeviceBundleID(_ bundleID: String) -> Bool {
        bundleID.hasPrefix(inputDevicePrefix)
    }

    public static func inputDeviceUID(from bundleID: String) -> String? {
        guard isInputDeviceBundleID(bundleID) else { return nil }
        let uid = String(bundleID.dropFirst(inputDevicePrefix.count))
        return uid.isEmpty ? nil : uid
    }
}

public enum SourceCategory: String, Codable, Sendable, Hashable {
    case systemSounds
    case userApplication
    case inputDevice
}

public struct SourceCatalogEntry: Codable, Sendable, Identifiable, Hashable, Equatable {
    public var id: String { bundleID }
    public var bundleID: String
    public var name: String
    public var isPlayingAudio: Bool
    public var category: SourceCategory

    public init(
        bundleID: String,
        name: String,
        isPlayingAudio: Bool,
        category: SourceCategory
    ) {
        self.bundleID = bundleID
        self.name = name
        self.isPlayingAudio = isPlayingAudio
        self.category = category
    }
}

public struct SourceCatalogSnapshot: Codable, Sendable, Equatable {
    public var playing: [SourceCatalogEntry]
    public var available: [SourceCatalogEntry]

    public init(playing: [SourceCatalogEntry] = [], available: [SourceCatalogEntry] = []) {
        self.playing = playing
        self.available = available
    }
}
