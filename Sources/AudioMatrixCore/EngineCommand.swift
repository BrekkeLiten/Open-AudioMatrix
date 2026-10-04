import Foundation

public enum EngineCommand: Codable, Sendable {
    case ping
    case status
    case levels
    case start
    case stop
    case listProcesses
    case listOutputDevices
    case listInputDevices
    case addSource(bundleID: String, outputDeviceUID: String, sourceChannel: Int, outputChannel: Int)
    case removeSource(bundleID: String, outputDeviceUID: String, sourceChannel: Int, outputChannel: Int)
    case applyRouteChanges(add: [RoutePatchRequest], remove: [RoutePatchRequest])
    case setRouteMuted(
        bundleID: String,
        outputDeviceUID: String,
        sourceChannel: Int,
        outputChannel: Int,
        muted: Bool
    )
    case applySession(RoutingSession)
    case setTestTone(outputDeviceUID: String, channels: [Int]?, signalKind: TestSignalKind?, enabled: Bool)
    case setChannelLabel(deviceUID: String, channelStart: Int, label: String?)
    case updateGraph(RoutingGraphDocument?)
    case savePreset(name: String)
    case loadPreset(name: String)
    case listPresets
    case shutdown
}

public struct EngineResponse: Codable, Sendable {
    public var ok: Bool
    public var message: String
    public var session: RoutingSession?
    public var processes: [AudioProcessInfo]?
    public var sourceCatalog: SourceCatalogSnapshot?
    public var outputDevices: [OutputDeviceInfo]?
    public var inputDevices: [InputDeviceInfo]?
    public var levels: [String: Float]?
    public var sourceChannelCounts: [String: Int]?
    public var presets: [String]?
    public var running: Bool

    public init(
        ok: Bool,
        message: String,
        session: RoutingSession? = nil,
        processes: [AudioProcessInfo]? = nil,
        sourceCatalog: SourceCatalogSnapshot? = nil,
        outputDevices: [OutputDeviceInfo]? = nil,
        inputDevices: [InputDeviceInfo]? = nil,
        levels: [String: Float]? = nil,
        sourceChannelCounts: [String: Int]? = nil,
        presets: [String]? = nil,
        running: Bool = false
    ) {
        self.ok = ok
        self.message = message
        self.session = session
        self.processes = processes
        self.sourceCatalog = sourceCatalog
        self.outputDevices = outputDevices
        self.inputDevices = inputDevices
        self.levels = levels
        self.sourceChannelCounts = sourceChannelCounts
        self.presets = presets
        self.running = running
    }
}

public struct AudioProcessInfo: Codable, Sendable, Identifiable, Hashable {
    public var id: String { bundleID }
    public var bundleID: String
    public var pid: Int32
    public var name: String
    public var isRunningOutput: Bool
    public var isRunningInput: Bool

    public init(
        bundleID: String,
        pid: Int32,
        name: String,
        isRunningOutput: Bool,
        isRunningInput: Bool
    ) {
        self.bundleID = bundleID
        self.pid = pid
        self.name = name
        self.isRunningOutput = isRunningOutput
        self.isRunningInput = isRunningInput
    }
}

public struct OutputDeviceInfo: Codable, Sendable, Identifiable, Hashable {
    public var id: String { uid }
    public var uid: String
    public var name: String
    public var outputChannelCount: Int
    public var isDefault: Bool

    public init(uid: String, name: String, outputChannelCount: Int, isDefault: Bool) {
        self.uid = uid
        self.name = name
        self.outputChannelCount = outputChannelCount
        self.isDefault = isDefault
    }
}

public struct InputDeviceInfo: Codable, Sendable, Identifiable, Hashable {
    public var id: String { uid }
    public var uid: String
    public var name: String
    public var inputChannelCount: Int
    public var isDefault: Bool

    public init(uid: String, name: String, inputChannelCount: Int, isDefault: Bool) {
        self.uid = uid
        self.name = name
        self.inputChannelCount = inputChannelCount
        self.isDefault = isDefault
    }
}

public struct RoutePatchRequest: Codable, Sendable, Equatable {
    public var bundleID: String
    public var outputDeviceUID: String
    public var sourceChannel: Int
    public var outputChannel: Int

    public init(
        bundleID: String,
        outputDeviceUID: String,
        sourceChannel: Int,
        outputChannel: Int
    ) {
        self.bundleID = bundleID
        self.outputDeviceUID = outputDeviceUID
        self.sourceChannel = sourceChannel
        self.outputChannel = outputChannel
    }
}

public enum EnginePaths {
    public static let socketPath = "/tmp/openaudiomatrix.engine.sock"
}
