import Foundation

public struct RoutingSession: Codable, Sendable {
    public var sampleRate: Double
    public var bufferFrames: UInt32
    public var sources: [SourceRoute]
    public var channelLabels: [String: String]
    public var graph: RoutingGraphDocument?
    public var testToneOutputDeviceUID: String?
    /// Mono output channels (1-based) receiving the test signal.
    public var testToneChannels: [Int]
    public var testToneSignalKind: TestSignalKind
    public var testToneEnabled: Bool

    public init(
        sampleRate: Double = 48_000,
        bufferFrames: UInt32 = 512,
        sources: [SourceRoute] = [],
        channelLabels: [String: String] = [:],
        graph: RoutingGraphDocument? = nil,
        testToneOutputDeviceUID: String? = nil,
        testToneChannels: [Int] = [],
        testToneSignalKind: TestSignalKind = .sine440,
        testToneEnabled: Bool = false
    ) {
        self.sampleRate = sampleRate
        self.bufferFrames = bufferFrames
        self.sources = sources
        self.channelLabels = channelLabels
        self.graph = graph
        self.testToneOutputDeviceUID = testToneOutputDeviceUID
        self.testToneChannels = testToneChannels
        self.testToneSignalKind = testToneSignalKind
        self.testToneEnabled = testToneEnabled
    }

    /// First selected test channel (legacy single-channel callers).
    public var testToneChannelStart: Int? {
        testToneChannels.first
    }

    enum CodingKeys: String, CodingKey {
        case sampleRate
        case bufferFrames
        case sources
        case channelLabels
        case graph
        case testToneOutputDeviceUID
        case testToneChannels
        case testToneChannelStart
        case testToneSignalKind
        case testToneEnabled
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sampleRate = try container.decodeIfPresent(Double.self, forKey: .sampleRate) ?? 48_000
        bufferFrames = try container.decodeIfPresent(UInt32.self, forKey: .bufferFrames) ?? 512
        sources = try container.decodeIfPresent([SourceRoute].self, forKey: .sources) ?? []
        channelLabels = try container.decodeIfPresent([String: String].self, forKey: .channelLabels) ?? [:]
        graph = try container.decodeIfPresent(RoutingGraphDocument.self, forKey: .graph)
        testToneOutputDeviceUID = try container.decodeIfPresent(String.self, forKey: .testToneOutputDeviceUID)
        if let channels = try container.decodeIfPresent([Int].self, forKey: .testToneChannels), !channels.isEmpty {
            testToneChannels = channels
        } else if let legacy = try container.decodeIfPresent(Int.self, forKey: .testToneChannelStart) {
            testToneChannels = [legacy]
        } else {
            testToneChannels = []
        }
        testToneSignalKind = try container.decodeIfPresent(TestSignalKind.self, forKey: .testToneSignalKind) ?? .sine440
        testToneEnabled = try container.decodeIfPresent(Bool.self, forKey: .testToneEnabled) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sampleRate, forKey: .sampleRate)
        try container.encode(bufferFrames, forKey: .bufferFrames)
        try container.encode(sources, forKey: .sources)
        try container.encode(channelLabels, forKey: .channelLabels)
        try container.encodeIfPresent(graph, forKey: .graph)
        try container.encodeIfPresent(testToneOutputDeviceUID, forKey: .testToneOutputDeviceUID)
        try container.encode(testToneChannels, forKey: .testToneChannels)
        try container.encode(testToneSignalKind, forKey: .testToneSignalKind)
        try container.encode(testToneEnabled, forKey: .testToneEnabled)
    }

    public static func channelLabelKey(deviceUID: String, channelStart: Int) -> String {
        "\(deviceUID):\(channelStart)"
    }

    public func channelLabel(deviceUID: String, channelStart: Int) -> String? {
        channelLabels[Self.channelLabelKey(deviceUID: deviceUID, channelStart: channelStart)]
    }
}
