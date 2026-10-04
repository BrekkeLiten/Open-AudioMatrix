import AudioMatrixCore
import Foundation

struct MatrixPatchState {
    var connections: [RouteKey: Bool] = [:]
    var mutedRoutes: Set<RouteKey> = []
}
