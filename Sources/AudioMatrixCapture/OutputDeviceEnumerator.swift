import AudioMatrixCore
import CoreAudio
import Foundation

public enum OutputDeviceEnumerator {
    public static func listOutputDevices() throws -> [OutputDeviceInfo] {
        let defaultUID = try CoreAudioHelpers.defaultOutputDeviceUID()
        let deviceIDs = try CoreAudioHelpers.getPropertyDataArray(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyDevices
        )

        var devices: [OutputDeviceInfo] = []
        for deviceID in deviceIDs {
            let channelCount = (try? outputChannelCount(deviceID: deviceID)) ?? 0
            guard channelCount > 0 else { continue }

            let uid = (try? CoreAudioHelpers.readStringProperty(
                objectID: deviceID,
                selector: kAudioDevicePropertyDeviceUID
            )) ?? ""
            guard !uid.isEmpty else { continue }

            let name = (try? CoreAudioHelpers.readStringProperty(
                objectID: deviceID,
                selector: kAudioObjectPropertyName
            )) ?? uid

            guard CoreAudioHelpers.isRoutableOutputDevice(deviceID: deviceID, uid: uid, name: name) else {
                continue
            }

            devices.append(OutputDeviceInfo(
                uid: uid,
                name: name,
                outputChannelCount: channelCount,
                isDefault: uid == defaultUID
            ))
        }

        return devices.sorted { lhs, rhs in
            if lhs.isDefault != rhs.isDefault { return lhs.isDefault }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    public static func resolveDeviceUID(_ query: String) throws -> OutputDeviceInfo {
        if query.lowercased() == "default" {
            return try defaultOutputDevice()
        }
        let devices = try listOutputDevices()
        if let exact = devices.first(where: { $0.uid == query }) {
            return exact
        }
        let lowered = query.lowercased()
        let matches = devices.filter {
            $0.name.lowercased().contains(lowered) || $0.uid.lowercased().contains(lowered)
        }
        guard let match = matches.first else {
            throw OutputDeviceError.notFound(query)
        }
        if matches.count > 1, !matches.contains(where: { $0.name.lowercased() == lowered }) {
            let names = matches.map(\.name).joined(separator: ", ")
            throw OutputDeviceError.ambiguous(query, names)
        }
        return match
    }

    public static func defaultOutputDevice() throws -> OutputDeviceInfo {
        let devices = try listOutputDevices()
        if let device = devices.first(where: \.isDefault) {
            return device
        }
        guard let first = devices.first else {
            throw OutputDeviceError.noneAvailable
        }
        return first
    }

    public static func nominalSampleRate(uid: String) throws -> Double {
        let deviceID = try deviceID(forUID: uid)
        let asbd = try AudioPCMConverter.readIODeviceStreamFormat(deviceID: deviceID)
        guard asbd.mSampleRate > 0 else {
            throw OutputDeviceError.notFound(uid)
        }
        return asbd.mSampleRate
    }

    /// Devices that must use tap aggregate playthrough instead of a separate output sink.
    public static func playthroughDeviceUIDs(among routedDeviceUIDs: Set<String>) throws -> Set<String> {
        guard !routedDeviceUIDs.isEmpty else { return [] }
        var playthrough = Set<String>()
        for deviceUID in routedDeviceUIDs {
            let avoidUIDs = Array(routedDeviceUIDs.subtracting([deviceUID]))
            let clockUID = try CoreAudioHelpers.tapClockDeviceUID(avoiding: avoidUIDs)
            if clockUID == deviceUID {
                playthrough.insert(deviceUID)
            }
        }
        return playthrough
    }

    private static func deviceID(forUID uid: String) throws -> AudioObjectID {
        let deviceIDs = try CoreAudioHelpers.getPropertyDataArray(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyDevices
        )
        for deviceID in deviceIDs {
            let deviceUID = try CoreAudioHelpers.readStringProperty(
                objectID: deviceID,
                selector: kAudioDevicePropertyDeviceUID
            )
            if deviceUID == uid {
                return deviceID
            }
        }
        throw OutputDeviceError.notFound(uid)
    }

    private static func outputChannelCount(deviceID: AudioObjectID) throws -> Int {
        var address = CoreAudioHelpers.propertyAddress(
            selector: kAudioDevicePropertyStreamConfiguration,
            scope: kAudioDevicePropertyScopeOutput
        )
        var size: UInt32 = 0
        try CoreAudioHelpers.checkOSStatus(
            AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size),
            operation: "kAudioDevicePropertyStreamConfiguration size"
        )
        guard size > 0 else { return 0 }

        let bufferList = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(size))
        defer { bufferList.deallocate() }

        try CoreAudioHelpers.checkOSStatus(
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, bufferList),
            operation: "kAudioDevicePropertyStreamConfiguration"
        )

        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}

public enum OutputDeviceError: Error, CustomStringConvertible {
    case notFound(String)
    case ambiguous(String, String)
    case noneAvailable

    public var description: String {
        switch self {
        case .notFound(let query):
            "No output device matches '\(query)'"
        case .ambiguous(let query, let matches):
            "Output device '\(query)' is ambiguous. Matches: \(matches)"
        case .noneAvailable:
            "No output devices are available"
        }
    }
}
