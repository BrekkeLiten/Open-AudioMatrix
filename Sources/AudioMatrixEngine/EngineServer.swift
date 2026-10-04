import AudioMatrixCapture
import AudioMatrixCore
import Darwin
import Foundation

final class EngineServer {
    private let mixer: MixerEngine
    private let queue = DispatchQueue(label: "io.github.brekkeliten.openaudiomatrix.engine-server")
    private var serverFD: Int32 = -1

    init(mixer: MixerEngine) {
        self.mixer = mixer
    }

    func start() throws {
        unlink(EnginePaths.socketPath)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw EngineServerError.socketFailed(errno)
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        EnginePaths.socketPath.withCString { cstr in
            _ = strncpy(&addr.sun_path.0, cstr, MemoryLayout.size(ofValue: addr.sun_path) - 1)
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            close(fd)
            throw EngineServerError.bindFailed(errno)
        }

        guard listen(fd, 8) == 0 else {
            close(fd)
            throw EngineServerError.listenFailed(errno)
        }

        serverFD = fd
        queue.async { [weak self] in
            self?.acceptLoop()
        }
    }

    private func acceptLoop() {
        while serverFD >= 0 {
            let client = accept(serverFD, nil, nil)
            guard client >= 0 else { continue }
            handleClient(fd: client)
            close(client)
        }
    }

    private func handleClient(fd: Int32) {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        let bytesRead = read(fd, &buffer, buffer.count)
        guard bytesRead > 0 else { return }

        let data = Data(buffer.prefix(bytesRead))
        guard let command = try? JSONDecoder().decode(EngineCommand.self, from: data) else {
            writeResponse(fd: fd, EngineResponse(ok: false, message: "Invalid command"))
            return
        }

        let response = dispatch(command)
        writeResponse(fd: fd, response)
    }

    private func dispatch(_ command: EngineCommand) -> EngineResponse {
        switch command {
        case .ping:
            return EngineResponse(ok: true, message: "pong", running: mixer.isRunning)

        case .status:
            return EngineResponse(
                ok: true,
                message: "ok",
                session: mixer.currentSession,
                levels: mixer.levels,
                sourceChannelCounts: mixer.sourceChannelCounts,
                running: mixer.isRunning
            )

        case .levels:
            return EngineResponse(
                ok: true,
                message: "ok",
                levels: mixer.levels,
                running: mixer.isRunning
            )

        case .start:
            do {
                let session = mixer.currentSession
                guard !session.sources.isEmpty || session.testToneEnabled else {
                    return EngineResponse(
                        ok: false,
                        message: "No routes configured. Add a source first, e.g. audiomatrix add com.spotify.client --device default --ch 1"
                    )
                }
                try mixer.start(session: session)
                return EngineResponse(ok: true, message: "started", session: mixer.currentSession, running: true)
            } catch {
                return EngineResponse(ok: false, message: error.localizedDescription)
            }

        case .stop:
            mixer.stop()
            return EngineResponse(ok: true, message: "stopped", running: false)

        case .listProcesses:
            do {
                let catalog = try ProcessCatalog.buildCatalog()
                let processes = (catalog.playing + catalog.available).map { entry in
                    AudioProcessInfo(
                        bundleID: entry.bundleID,
                        pid: -1,
                        name: entry.name,
                        isRunningOutput: entry.isPlayingAudio,
                        isRunningInput: false
                    )
                }
                return EngineResponse(
                    ok: true,
                    message: "ok",
                    processes: processes,
                    sourceCatalog: catalog,
                    running: mixer.isRunning
                )
            } catch {
                return EngineResponse(ok: false, message: error.localizedDescription)
            }

        case .listOutputDevices:
            do {
                let devices = try OutputDeviceEnumerator.listOutputDevices()
                return EngineResponse(ok: true, message: "ok", outputDevices: devices, running: mixer.isRunning)
            } catch {
                return EngineResponse(ok: false, message: error.localizedDescription)
            }

        case .listInputDevices:
            do {
                let devices = try InputDeviceEnumerator.listInputDevices()
                return EngineResponse(ok: true, message: "ok", inputDevices: devices, running: mixer.isRunning)
            } catch {
                return EngineResponse(ok: false, message: error.localizedDescription)
            }

        case .addSource(let bundleID, let outputDeviceUID, let sourceChannel, let outputChannel):
            do {
                let device = try OutputDeviceEnumerator.resolveDeviceUID(outputDeviceUID)
                var session = mixer.currentSession
                let parent = BundleIDMatcher.parentBundleID(of: bundleID)
                let reported = mixer.sourceChannelCounts[bundleID]
                    ?? mixer.sourceChannelCounts[parent]
                    ?? 0
                let enumeratedInputCount: Int = {
                    guard let inputUID = SourceCatalog.inputDeviceUID(from: bundleID),
                          let inputDevice = try? InputDeviceEnumerator.resolveDeviceUID(inputUID) else {
                        return 0
                    }
                    return inputDevice.inputChannelCount
                }()
                // Allow routing before the tap reports its format (e.g. ch 6 while tap not yet running).
                let sourceChannelCount = max(reported, enumeratedInputCount, sourceChannel, outputChannel, 2)
                let router = ChannelRouter(channelCount: device.outputChannelCount)
                try router.validateAssignment(
                    sourceChannel: sourceChannel,
                    outputChannel: outputChannel,
                    sourceChannelCount: sourceChannelCount,
                    bundleID: bundleID,
                    sources: session.sources,
                    outputDeviceUID: device.uid,
                    outputChannelCount: device.outputChannelCount
                )

                session.sources.removeAll {
                    BundleIDMatcher.parentBundleID(of: $0.bundleID)
                        == BundleIDMatcher.parentBundleID(of: bundleID)
                        && $0.outputDeviceUID == device.uid
                        && $0.sourceChannel == sourceChannel
                        && $0.outputChannel == outputChannel
                }
                session.sources.append(SourceRoute(
                    bundleID: bundleID,
                    outputDeviceUID: device.uid,
                    sourceChannel: sourceChannel,
                    outputChannel: outputChannel
                ))
                try mixer.updateSession(session)
                return EngineResponse(
                    ok: true,
                    message: "added",
                    session: session,
                    sourceChannelCounts: mixer.sourceChannelCounts,
                    running: mixer.isRunning
                )
            } catch {
                return EngineResponse(ok: false, message: error.localizedDescription)
            }

        case .removeSource(let bundleID, let outputDeviceUID, let sourceChannel, let outputChannel):
            var session = mixer.currentSession
            session.sources.removeAll {
                BundleIDMatcher.parentBundleID(of: $0.bundleID)
                    == BundleIDMatcher.parentBundleID(of: bundleID)
                    && $0.outputDeviceUID == outputDeviceUID
                    && $0.sourceChannel == sourceChannel
                    && $0.outputChannel == outputChannel
            }
            do {
                try mixer.updateSession(session)
            } catch {
                return EngineResponse(ok: false, message: error.localizedDescription)
            }
            return EngineResponse(ok: true, message: "removed", session: session, running: mixer.isRunning)

        case .applyRouteChanges(let add, let remove):
            do {
                var session = mixer.currentSession
                for patch in remove {
                    session.sources.removeAll {
                        BundleIDMatcher.parentBundleID(of: $0.bundleID)
                            == BundleIDMatcher.parentBundleID(of: patch.bundleID)
                            && $0.outputDeviceUID == patch.outputDeviceUID
                            && $0.sourceChannel == patch.sourceChannel
                            && $0.outputChannel == patch.outputChannel
                    }
                }
                for patch in add {
                    try Self.appendRoute(patch, to: &session, mixer: mixer)
                }
                try mixer.updateSession(session)
                return EngineResponse(
                    ok: true,
                    message: "routes updated",
                    session: session,
                    sourceChannelCounts: mixer.sourceChannelCounts,
                    running: mixer.isRunning
                )
            } catch {
                return EngineResponse(ok: false, message: error.localizedDescription)
            }

        case .setRouteMuted(let bundleID, let outputDeviceUID, let sourceChannel, let outputChannel, let muted):
            var session = mixer.currentSession
            guard let index = session.sources.firstIndex(where: {
                BundleIDMatcher.parentBundleID(of: $0.bundleID)
                    == BundleIDMatcher.parentBundleID(of: bundleID)
                    && $0.outputDeviceUID == outputDeviceUID
                    && $0.sourceChannel == sourceChannel
                    && $0.outputChannel == outputChannel
            }) else {
                return EngineResponse(ok: false, message: "route not found")
            }
            session.sources[index].muted = muted
            do {
                try mixer.updateSession(session)
                return EngineResponse(
                    ok: true,
                    message: muted ? "route muted" : "route unmuted",
                    session: session,
                    running: mixer.isRunning
                )
            } catch {
                return EngineResponse(ok: false, message: error.localizedDescription)
            }

        case .applySession(let newSession):
            do {
                let wasRunning = mixer.isRunning
                if wasRunning {
                    mixer.stop()
                }
                try mixer.updateSession(newSession)
                if wasRunning {
                    try mixer.start(session: newSession)
                }
                return EngineResponse(
                    ok: true,
                    message: "session applied",
                    session: mixer.currentSession,
                    running: mixer.isRunning
                )
            } catch {
                return EngineResponse(ok: false, message: error.localizedDescription)
            }

        case .setTestTone(let outputDeviceUID, let channels, let signalKind, let enabled):
            do {
                let device = try OutputDeviceEnumerator.resolveDeviceUID(outputDeviceUID)
                var session = mixer.currentSession
                session.testToneOutputDeviceUID = device.uid
                if let channels, !channels.isEmpty {
                    session.testToneChannels = channels.sorted()
                } else if enabled {
                    session.testToneChannels = [1]
                }
                if let signalKind {
                    session.testToneSignalKind = signalKind
                }
                session.testToneEnabled = enabled
                try mixer.updateSession(session)
                if enabled, !mixer.isRunning {
                    try mixer.start(session: session)
                }
                return EngineResponse(
                    ok: true,
                    message: "test tone updated",
                    session: mixer.currentSession,
                    running: mixer.isRunning
                )
            } catch {
                return EngineResponse(ok: false, message: error.localizedDescription)
            }

        case .setChannelLabel(let deviceUID, let channelStart, let label):
            do {
                let device = try OutputDeviceEnumerator.resolveDeviceUID(deviceUID)
                var session = mixer.currentSession
                let key = RoutingSession.channelLabelKey(deviceUID: device.uid, channelStart: channelStart)
                if let label, !label.isEmpty {
                    session.channelLabels[key] = label
                } else {
                    session.channelLabels.removeValue(forKey: key)
                }
                try mixer.updateSession(session)
                return EngineResponse(ok: true, message: "channel label updated", session: session, running: mixer.isRunning)
            } catch {
                return EngineResponse(ok: false, message: error.localizedDescription)
            }

        case .updateGraph(let graph):
            do {
                var session = mixer.currentSession
                session.graph = graph
                if let graph, !graph.connections.isEmpty {
                    let compiled = try RoutingGraphCompiler.compileConnections(graph)
                    if !RoutingGraphCompiler.routesEqual(session.sources, compiled) {
                        session.sources = compiled
                    }
                }
                try mixer.updateSession(session)
                return EngineResponse(ok: true, message: "graph updated", session: session, running: mixer.isRunning)
            } catch {
                return EngineResponse(ok: false, message: error.localizedDescription)
            }

        case .savePreset(let name):
            do {
                try PresetManager.save(session: mixer.currentSession, name: name)
                return EngineResponse(ok: true, message: "preset saved", session: mixer.currentSession, running: mixer.isRunning)
            } catch {
                return EngineResponse(ok: false, message: error.localizedDescription)
            }

        case .loadPreset(let name):
            do {
                let wasRunning = mixer.isRunning
                if wasRunning {
                    mixer.stop()
                }
                let session = try PresetManager.load(name: name)
                try mixer.updateSession(session)
                if wasRunning {
                    try mixer.start(session: session)
                }
                return EngineResponse(ok: true, message: "preset loaded", session: session, running: mixer.isRunning)
            } catch {
                return EngineResponse(ok: false, message: error.localizedDescription)
            }

        case .listPresets:
            do {
                let presets = try PresetManager.listPresets()
                return EngineResponse(ok: true, message: "ok", presets: presets, running: mixer.isRunning)
            } catch {
                return EngineResponse(ok: false, message: error.localizedDescription)
            }

        case .shutdown:
            mixer.stop()
            exit(0)
        }
    }

    private func writeResponse(fd: Int32, _ response: EngineResponse) {
        guard let data = try? JSONEncoder().encode(response) else { return }
        var payload = data
        payload.append(0x0A)
        payload.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            _ = write(fd, base, payload.count)
        }
    }

    private static func appendRoute(
        _ patch: RoutePatchRequest,
        to session: inout RoutingSession,
        mixer: MixerEngine
    ) throws {
        let device = try OutputDeviceEnumerator.resolveDeviceUID(patch.outputDeviceUID)
        let parent = BundleIDMatcher.parentBundleID(of: patch.bundleID)
        let reported = mixer.sourceChannelCounts[patch.bundleID]
            ?? mixer.sourceChannelCounts[parent]
            ?? 0
        let enumeratedInputCount: Int = {
            guard let inputUID = SourceCatalog.inputDeviceUID(from: patch.bundleID),
                  let inputDevice = try? InputDeviceEnumerator.resolveDeviceUID(inputUID) else {
                return 0
            }
            return inputDevice.inputChannelCount
        }()
        let sourceChannelCount = max(
            reported,
            enumeratedInputCount,
            patch.sourceChannel,
            patch.outputChannel,
            2
        )
        let router = ChannelRouter(channelCount: device.outputChannelCount)
        try router.validateAssignment(
            sourceChannel: patch.sourceChannel,
            outputChannel: patch.outputChannel,
            sourceChannelCount: sourceChannelCount,
            bundleID: patch.bundleID,
            sources: session.sources,
            outputDeviceUID: device.uid,
            outputChannelCount: device.outputChannelCount
        )

        session.sources.removeAll {
            BundleIDMatcher.parentBundleID(of: $0.bundleID)
                == BundleIDMatcher.parentBundleID(of: patch.bundleID)
                && $0.outputDeviceUID == device.uid
                && $0.sourceChannel == patch.sourceChannel
                && $0.outputChannel == patch.outputChannel
        }
        session.sources.append(SourceRoute(
            bundleID: patch.bundleID,
            outputDeviceUID: device.uid,
            sourceChannel: patch.sourceChannel,
            outputChannel: patch.outputChannel
        ))
    }
}

enum EngineServerError: Error, CustomStringConvertible {
    case socketFailed(Int32)
    case bindFailed(Int32)
    case listenFailed(Int32)

    var description: String {
        switch self {
        case .socketFailed(let code):
            "socket() failed: \(String(cString: strerror(code)))"
        case .bindFailed(let code):
            "bind() failed: \(String(cString: strerror(code)))"
        case .listenFailed(let code):
            "listen() failed: \(String(cString: strerror(code)))"
        }
    }
}
