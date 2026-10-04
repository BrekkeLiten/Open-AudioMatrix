import AudioMatrixCore
import Foundation

enum CLI {
    static func run() {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let command = args.first else {
            printUsage()
            exit(1)
        }

        do {
            switch command {
            case "help", "--help", "-h":
                printUsage()
            case "start":
                try handleStart(args: Array(args.dropFirst()))
            case "stop":
                try handleStop()
            case "status":
                try handleStatus()
            case "list":
                try handleList()
            case "list-devices":
                try handleListDevices()
            case "add":
                try handleAdd(args: Array(args.dropFirst()))
            case "remove":
                try handleRemove(args: Array(args.dropFirst()))
            case "test-tone":
                try handleTestTone(args: Array(args.dropFirst()))
            case "ping":
                try handlePing()
            case "preset":
                try handlePreset(args: Array(args.dropFirst()))
            case "label":
                try handleLabel(args: Array(args.dropFirst()))
            default:
                fputs("Unknown command: \(command)\n", stderr)
                printUsage()
                exit(1)
            }
        } catch {
            fputs("Error: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func handleStart(args: [String]) throws {
        if args.contains("--foreground") {
            fputs("Use `swift run AudioMatrixEngine` for foreground engine.\n", stderr)
            exit(1)
        }
        try EngineClient.ensureEngineRunning()
        let response = try EngineClient.send(.start)
        print(response.message)
        if !response.ok { exit(1) }
    }

    private static func handleStop() throws {
        let response = try EngineClient.send(.stop)
        print(response.message)
        if !response.ok { exit(1) }
    }

    private static func handleStatus() throws {
        let response = try EngineClient.send(.status)
        guard response.ok else {
            print(response.message)
            exit(1)
        }
        print("running: \(response.running)")
        if let session = response.session {
            print("sources:")
            for source in session.sources {
                let label = session.channelLabel(
                    deviceUID: source.outputDeviceUID,
                    channelStart: source.outputChannel
                )
                let labelSuffix = label.map { " (\($0))" } ?? ""
                print("  - \(source.bundleID) -> \(source.outputDeviceUID) src \(source.sourceChannel) out \(source.outputChannel)\(labelSuffix) enabled=\(source.enabled)")
            }
            if session.testToneEnabled,
               !session.testToneChannels.isEmpty,
               let device = session.testToneOutputDeviceUID {
                let chList = session.testToneChannels.map(String.init).joined(separator: ", ")
                print("test-signal: \(session.testToneSignalKind.displayName) on \(device) ch \(chList)")
            }
        }
        if let levels = response.levels, !levels.isEmpty {
            print("levels:")
            for (key, value) in levels.sorted(by: { $0.key < $1.key }) {
                print("  - \(key): \(String(format: "%.3f", value))")
            }
        }
    }

    private static func handleList() throws {
        try EngineClient.ensureEngineRunning()
        let response = try EngineClient.send(.listProcesses)
        guard response.ok, let processes = response.processes else {
            print(response.message)
            exit(1)
        }
        for process in processes {
            let flags = [
                process.isRunningOutput ? "out" : nil,
                process.isRunningInput ? "in" : nil,
            ].compactMap { $0 }.joined(separator: ",")
            print("\(process.name)\t\(process.bundleID)\tpid=\(process.pid)\t[\(flags)]")
        }
    }

    private static func handleListDevices() throws {
        try EngineClient.ensureEngineRunning()
        let response = try EngineClient.send(.listOutputDevices)
        guard response.ok, let devices = response.outputDevices else {
            print(response.message)
            exit(1)
        }
        for device in devices {
            let marker = device.isDefault ? "*" : " "
            print("\(marker) \(device.name)\t\(device.uid)\t\(device.outputChannelCount)ch")
        }
    }

    private static func handleAdd(args: [String]) throws {
        guard let bundleID = args.first else {
            fputs("Usage: audiomatrix add <bundleID> --device <output> --ch <channelStart>\n", stderr)
            exit(1)
        }
        guard let deviceIndex = args.firstIndex(of: "--device"), deviceIndex + 1 < args.count else {
            fputs("Missing --device <output name or UID>\n", stderr)
            exit(1)
        }
        guard let chIndex = args.firstIndex(of: "--ch"), chIndex + 1 < args.count,
              let outputChannel = Int(args[chIndex + 1]) else {
            fputs("Missing --ch <outputChannel>\n", stderr)
            exit(1)
        }

        var sourceChannel = outputChannel
        if let srcIndex = args.firstIndex(of: "--src-ch"), srcIndex + 1 < args.count,
           let parsed = Int(args[srcIndex + 1]) {
            sourceChannel = parsed
        }

        let outputDevice = args[deviceIndex + 1]
        try EngineClient.ensureEngineRunning()
        let response = try EngineClient.send(.addSource(
            bundleID: bundleID,
            outputDeviceUID: outputDevice,
            sourceChannel: sourceChannel,
            outputChannel: outputChannel
        ))
        print(response.message)
        if !response.ok { exit(1) }
    }

    private static func handleRemove(args: [String]) throws {
        guard let bundleID = args.first else {
            fputs("Usage: audiomatrix remove <bundleID>\n", stderr)
            exit(1)
        }
        try EngineClient.ensureEngineRunning()
        let status = try EngineClient.send(.status)
        let parent = BundleIDMatcher.parentBundleID(of: bundleID)
        let routes = status.session?.sources.filter {
            BundleIDMatcher.parentBundleID(of: $0.bundleID) == parent
        } ?? []
        guard !routes.isEmpty else {
            print("No routes for \(bundleID)")
            return
        }
        for route in routes {
            let response = try EngineClient.send(.removeSource(
                bundleID: route.bundleID,
                outputDeviceUID: route.outputDeviceUID,
                sourceChannel: route.sourceChannel,
                outputChannel: route.outputChannel
            ))
            print(response.message)
            if !response.ok { exit(1) }
        }
    }

    private static func handleTestTone(args: [String]) throws {
        var channelList = [1]
        var enabled = true
        var outputDevice = "default"
        var signalKind: TestSignalKind = .sine440

        if args.contains("--off") {
            enabled = false
        }
        if let chIndex = args.firstIndex(of: "--ch"), chIndex + 1 < args.count {
            channelList = parseChannelList(args[chIndex + 1])
        }
        if let deviceIndex = args.firstIndex(of: "--device"), deviceIndex + 1 < args.count {
            outputDevice = args[deviceIndex + 1]
        }
        if let signalIndex = args.firstIndex(of: "--signal"), signalIndex + 1 < args.count {
            switch args[signalIndex + 1].lowercased() {
            case "sine", "440", "tone": signalKind = .sine440
            case "white", "white-noise": signalKind = .whiteNoise
            case "pink", "pink-noise": signalKind = .pinkNoise
            default:
                fputs("Unknown --signal value. Use sine, white, or pink.\n", stderr)
                exit(1)
            }
        }

        try EngineClient.ensureEngineRunning()
        let response = try EngineClient.send(.setTestTone(
            outputDeviceUID: outputDevice,
            channels: channelList,
            signalKind: signalKind,
            enabled: enabled
        ))
        print(response.message)
        if !response.ok { exit(1) }
    }

    private static func parseChannelList(_ value: String) -> [Int] {
        value.split(separator: ",")
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            .filter { $0 >= 1 }
            .sorted()
    }

    private static func handlePing() throws {
        let response = try EngineClient.send(.ping)
        print(response.message)
        if !response.ok { exit(1) }
    }

    private static func handleLabel(args: [String]) throws {
        guard let deviceIndex = args.firstIndex(of: "--device"), deviceIndex + 1 < args.count else {
            fputs("Usage: audiomatrix label --device <output> --ch <channelStart> \"Label text\"\n", stderr)
            exit(1)
        }
        guard let chIndex = args.firstIndex(of: "--ch"), chIndex + 1 < args.count,
              let channelStart = Int(args[chIndex + 1]) else {
            fputs("Missing --ch <channelStart>\n", stderr)
            exit(1)
        }

        let device = args[deviceIndex + 1]
        var label: String?
        let labelArgs = args.enumerated().compactMap { index, arg -> String? in
            if index == deviceIndex || index == deviceIndex + 1 { return nil }
            if index == chIndex || index == chIndex + 1 { return nil }
            if arg == "--device" || arg == "--ch" { return nil }
            return arg
        }
        if !labelArgs.isEmpty {
            label = labelArgs.joined(separator: " ")
        }

        try EngineClient.ensureEngineRunning()
        let response = try EngineClient.send(.setChannelLabel(
            deviceUID: device,
            channelStart: channelStart,
            label: label
        ))
        print(response.message)
        if !response.ok { exit(1) }
    }

    private static func handlePreset(args: [String]) throws {
        guard let subcommand = args.first else {
            fputs("Usage: audiomatrix preset <save|load|list> [name]\n", stderr)
            exit(1)
        }
        try EngineClient.ensureEngineRunning()

        switch subcommand {
        case "save":
            guard let name = args.dropFirst().first else {
                fputs("Usage: audiomatrix preset save <name>\n", stderr)
                exit(1)
            }
            let response = try EngineClient.send(.savePreset(name: name))
            print(response.message)
            if !response.ok { exit(1) }

        case "load":
            guard let name = args.dropFirst().first else {
                fputs("Usage: audiomatrix preset load <name>\n", stderr)
                exit(1)
            }
            let response = try EngineClient.send(.loadPreset(name: name))
            print(response.message)
            if !response.ok { exit(1) }

        case "list":
            let response = try EngineClient.send(.listPresets)
            guard response.ok, let presets = response.presets else {
                print(response.message)
                exit(1)
            }
            if presets.isEmpty {
                print("(no presets)")
            } else {
                for preset in presets {
                    print(preset)
                }
            }

        default:
            fputs("Unknown preset subcommand: \(subcommand)\n", stderr)
            exit(1)
        }
    }

    private static func printUsage() {
        print("""
        Open AudioMatrix CLI

        Route application audio to physical output devices and channel pairs.

        Usage:
          audiomatrix start
          audiomatrix stop
          audiomatrix status
          audiomatrix list
          audiomatrix list-devices
          audiomatrix add <bundleID> --device <output> --ch <channelStart>
          audiomatrix remove <bundleID>
          audiomatrix test-tone --device <output> [--ch <channelStart>] [--off]
          audiomatrix preset save <name>
          audiomatrix preset load <name>
          audiomatrix preset list
          audiomatrix label --device <output> --ch <channelStart> "Label text"
          audiomatrix ping

        Examples:
          swift run AudioMatrixEngine
          swift run audiomatrix list-devices
          swift run audiomatrix test-tone --device "MacBook Pro Speakers" --ch 1
          swift run audiomatrix add com.spotify.client --device default --ch 1
          swift run audiomatrix add com.apple.Safari --device "USB Audio" --ch 5
        """)
    }
}
