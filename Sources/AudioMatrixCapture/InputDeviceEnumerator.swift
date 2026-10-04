import AudioMatrixCore
import CoreAudio
import Foundation

public enum InputDeviceEnumerator {
    public static func listInputDevices() throws -> [InputDeviceInfo] {
        let defaultUID = try? CoreAudioHelpers.defaultInputDeviceUID()
        let deviceIDs = try CoreAudioHelpers.getPropertyDataArray(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyDevices
        )

        var devices: [InputDeviceInfo] = []
        for deviceID in deviceIDs {
            let channelCount = (try? inputChannelCount(deviceID: deviceID)) ?? 0
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

            guard CoreAudioHelpers.isRoutableInputDevice(deviceID: deviceID, uid: uid, name: name) else {
                continue
            }

            devices.append(InputDeviceInfo(
                uid: uid,
                name: name,
                inputChannelCount: channelCount,
                isDefault: uid == defaultUID
            ))
        }

        return devices.sorted { lhs, rhs in
            if lhs.isDefault != rhs.isDefault { return lhs.isDefault }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    public static func resolveDeviceUID(_ query: String) throws -> InputDeviceInfo {
        if query.lowercased() == "default" {
            return try defaultInputDevice()
        }
        let devices = try listInputDevices()
        if let exact = devices.first(where: { $0.uid == query }) {
            return exact
        }
        let lowered = query.lowercased()
        let matches = devices.filter {
            $0.name.lowercased().contains(lowered) || $0.uid.lowercased().contains(lowered)
        }
        guard let match = matches.first else {
            throw InputDeviceError.notFound(query)
        }
        if matches.count > 1, !matches.contains(where: { $0.name.lowercased() == lowered }) {
            let names = matches.map(\.name).joined(separator: ", ")
            throw InputDeviceError.ambiguous(query, names)
        }
        return match
    }

    public static func defaultInputDevice() throws -> InputDeviceInfo {
        let devices = try listInputDevices()
        if let device = devices.first(where: \.isDefault) {
            return device
        }
        guard let first = devices.first else {
            throw InputDeviceError.noneAvailable
        }
        return first
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
        throw InputDeviceError.notFound(uid)
    }

    private static func inputChannelCount(deviceID: AudioObjectID) throws -> Int {
        var address = CoreAudioHelpers.propertyAddress(
            selector: kAudioDevicePropertyStreamConfiguration,
            scope: kAudioDevicePropertyScopeInput
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

public enum InputDeviceError: Error, CustomStringConvertible {
    case notFound(String)
    case ambiguous(String, String)
    case noneAvailable

    public var description: String {
        switch self {
        case .notFound(let query):
            "No input device matches '\(query)'"
        case .ambiguous(let query, let matches):
            "Input device '\(query)' is ambiguous. Matches: \(matches)"
        case .noneAvailable:
            "No input devices are available"
        }
    }
}
