import Foundation

/// Full show snapshot: engine routing session plus matrix layout metadata.
public struct ShowPreset: Codable, Sendable {
    public var session: RoutingSession
    public var matrix: MatrixPresetSnapshot

    public init(session: RoutingSession, matrix: MatrixPresetSnapshot = .empty) {
        self.session = session
        self.matrix = matrix
    }
}
