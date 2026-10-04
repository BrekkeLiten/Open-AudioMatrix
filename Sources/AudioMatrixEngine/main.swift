import AudioMatrixCore
import Foundation
import os

let logger = Logger(subsystem: "io.github.brekkeliten.openaudiomatrix", category: "Engine")

let mixer = MixerEngine()
let server = EngineServer(mixer: mixer)

do {
    try server.start()
    logger.info("AudioMatrixEngine listening at \(EnginePaths.socketPath, privacy: .public)")
    RunLoop.main.run()
} catch {
    logger.error("Engine failed to start: \(error.localizedDescription, privacy: .public)")
    fputs("Engine failed to start: \(error)\n", stderr)
    exit(1)
}
