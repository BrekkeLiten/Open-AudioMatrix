import Foundation

public enum TestSignalKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case sine440
    case whiteNoise
    case pinkNoise

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .sine440: "440 Hz"
        case .whiteNoise: "White noise"
        case .pinkNoise: "Pink noise"
        }
    }
}

public struct TestSignalGeneratorState: Sendable {
    public var sinePhase: Double
    public var whiteSeed: UInt32
    public var pinkB0: Float
    public var pinkB1: Float
    public var pinkB2: Float
    public var pinkB3: Float
    public var pinkB4: Float
    public var pinkB5: Float
    public var pinkB6: Float

    public init(
        sinePhase: Double = 0,
        whiteSeed: UInt32 = 0xC0FFEE01,
        pinkB0: Float = 0,
        pinkB1: Float = 0,
        pinkB2: Float = 0,
        pinkB3: Float = 0,
        pinkB4: Float = 0,
        pinkB5: Float = 0,
        pinkB6: Float = 0
    ) {
        self.sinePhase = sinePhase
        self.whiteSeed = whiteSeed
        self.pinkB0 = pinkB0
        self.pinkB1 = pinkB1
        self.pinkB2 = pinkB2
        self.pinkB3 = pinkB3
        self.pinkB4 = pinkB4
        self.pinkB5 = pinkB5
        self.pinkB6 = pinkB6
    }
}
