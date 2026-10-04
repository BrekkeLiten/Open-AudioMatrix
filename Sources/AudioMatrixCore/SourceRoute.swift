import Foundation

public struct SourceRoute: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var bundleID: String
    public var outputDeviceUID: String
    public var sourceChannel: Int
    public var outputChannel: Int
    public var enabled: Bool
    /// When true the route stays active but the mixer skips it (Option+click mute).
    public var muted: Bool

    public init(
        id: UUID = UUID(),
        bundleID: String,
        outputDeviceUID: String,
        sourceChannel: Int,
        outputChannel: Int,
        enabled: Bool = true,
        muted: Bool = false
    ) {
        self.id = id
        self.bundleID = bundleID
        self.outputDeviceUID = outputDeviceUID
        self.sourceChannel = sourceChannel
        self.outputChannel = outputChannel
        self.enabled = enabled
        self.muted = muted
    }

    /// Legacy stereo-pair presets stored only `channelStart` (output pair start).
    public init(
        id: UUID = UUID(),
        bundleID: String,
        outputDeviceUID: String,
        channelStart: Int,
        enabled: Bool = true
    ) {
        self.init(
            id: id,
            bundleID: bundleID,
            outputDeviceUID: outputDeviceUID,
            sourceChannel: 1,
            outputChannel: channelStart,
            enabled: enabled
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id, bundleID, outputDeviceUID, sourceChannel, outputChannel, channelStart, enabled, muted
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        bundleID = try container.decode(String.self, forKey: .bundleID)
        outputDeviceUID = try container.decode(String.self, forKey: .outputDeviceUID)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        muted = try container.decodeIfPresent(Bool.self, forKey: .muted) ?? false

        if let sourceChannel = try container.decodeIfPresent(Int.self, forKey: .sourceChannel),
           let outputChannel = try container.decodeIfPresent(Int.self, forKey: .outputChannel) {
            self.sourceChannel = sourceChannel
            self.outputChannel = outputChannel
        } else {
            let legacyStart = try container.decode(Int.self, forKey: .channelStart)
            sourceChannel = 1
            outputChannel = legacyStart
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(bundleID, forKey: .bundleID)
        try container.encode(outputDeviceUID, forKey: .outputDeviceUID)
        try container.encode(sourceChannel, forKey: .sourceChannel)
        try container.encode(outputChannel, forKey: .outputChannel)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(muted, forKey: .muted)
    }
}
