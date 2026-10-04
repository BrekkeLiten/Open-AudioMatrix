import CoreAudio
import Foundation

enum CoreAudioHelpers {
    static func propertyAddress(
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: element
        )
    }

    static func readAudioObjectID(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) throws -> AudioObjectID {
        var address = propertyAddress(selector: selector, scope: scope)
        var value = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value)
        guard status == noErr else {
            throw CoreAudioError.propertyReadFailed(selector: selector, status: status)
        }
        return value
    }

    static func readUInt32Property(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) throws -> UInt32 {
        var address = propertyAddress(selector: selector, scope: scope)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value)
        guard status == noErr else {
            throw CoreAudioError.propertyReadFailed(selector: selector, status: status)
        }
        return value
    }

    static func readPID(objectID: AudioObjectID) throws -> pid_t {
        var address = propertyAddress(selector: kAudioProcessPropertyPID)
        var value: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value)
        guard status == noErr else {
            throw CoreAudioError.propertyReadFailed(selector: kAudioProcessPropertyPID, status: status)
        }
        return value
    }

    static func getPropertyDataArray(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) throws -> [AudioObjectID] {
        var address = propertyAddress(selector: selector, scope: scope)
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size)
        guard status == noErr, size > 0 else {
            return []
        }

        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var values = [AudioObjectID](repeating: 0, count: count)
        status = values.withUnsafeMutableBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return kAudioHardwareUnspecifiedError }
            return AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, base)
        }
        guard status == noErr else {
            throw CoreAudioError.propertyReadFailed(selector: selector, status: status)
        }
        return values
    }

    static func readStringProperty(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) throws -> String {
        var address = propertyAddress(selector: selector, scope: scope)
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size)
        guard status == noErr, size > 0 else {
            throw CoreAudioError.propertyReadFailed(selector: selector, status: status)
        }

        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<CFString>.alignment)
        defer { buffer.deallocate() }

        status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, buffer)
        guard status == noErr else {
            throw CoreAudioError.propertyReadFailed(selector: selector, status: status)
        }

        let cfValue = buffer.load(as: CFString.self)
        return cfValue as String
    }

    static func defaultOutputDeviceUID() throws -> String {
        let deviceID = try readAudioObjectID(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyDefaultOutputDevice
        )
        guard deviceID != kAudioObjectUnknown else {
            throw CoreAudioError.noDefaultOutputDevice
        }
        return try readStringProperty(objectID: deviceID, selector: kAudioDevicePropertyDeviceUID)
    }

    static func defaultInputDeviceUID() throws -> String {
        let deviceID = try readAudioObjectID(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyDefaultInputDevice
        )
        guard deviceID != kAudioObjectUnknown else {
            throw CoreAudioError.noDefaultInputDevice
        }
        return try readStringProperty(objectID: deviceID, selector: kAudioDevicePropertyDeviceUID)
    }

    /// Device used only as the tap aggregate clock — never a routed output device.
    /// When every physical output is routed, built-in is reused as clock so the tap
    /// runs at 44.1 kHz; higher-rate outputs (48/96 kHz, etc.) resample per device.
    static func tapClockDeviceUID(avoiding excludedUIDs: [String]) throws -> String {
        let excluded = Set(excludedUIDs)

        // Keep the tap clock on built-in speakers when present so route changes between
        // built-in headphone and speaker outputs do not tear down the process tap.
        if let speakerUID = try builtInSpeakerDeviceUID(),
           let deviceID = try? deviceID(forUID: speakerUID),
           isUsableTapClockDevice(deviceID: deviceID, uid: speakerUID) {
            return speakerUID
        }

        if let builtInUID = try builtInOutputDeviceUID(), !excluded.contains(builtInUID) {
            return builtInUID
        }

        let deviceIDs = try getPropertyDataArray(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyDevices
        )
        for deviceID in deviceIDs {
            guard let uid = try? readStringProperty(
                objectID: deviceID,
                selector: kAudioDevicePropertyDeviceUID
            ), !uid.isEmpty, !excluded.contains(uid) else {
                continue
            }
            guard isUsableTapClockDevice(deviceID: deviceID, uid: uid) else { continue }
            return uid
        }

        // All routed outputs are excluded — prefer built-in speaker as a stable clock
        // (builtInOutputDeviceUID() shifts to headphones when they are plugged in).
        for uid in excluded.sorted() where uid.localizedCaseInsensitiveContains("speaker") {
            if let deviceID = try? deviceID(forUID: uid),
               isUsableTapClockDevice(deviceID: deviceID, uid: uid) {
                return uid
            }
        }

        if let builtInUID = try builtInOutputDeviceUID(), excluded.contains(builtInUID) {
            return builtInUID
        }

        for uid in excluded.sorted() {
            if let deviceID = try? deviceID(forUID: uid),
               isUsableTapClockDevice(deviceID: deviceID, uid: uid) {
                return uid
            }
        }
        if let builtInUID = try builtInOutputDeviceUID() {
            return builtInUID
        }

        let defaultUID = try defaultOutputDeviceUID()
        if !excluded.contains(defaultUID) {
            return defaultUID
        }
        throw CoreAudioError.noUsableTapClockDevice
    }

    private static func deviceID(forUID uid: String) throws -> AudioObjectID {
        let deviceIDs = try getPropertyDataArray(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyDevices
        )
        for deviceID in deviceIDs {
            let deviceUID = try readStringProperty(
                objectID: deviceID,
                selector: kAudioDevicePropertyDeviceUID
            )
            if deviceUID == uid {
                return deviceID
            }
        }
        throw CoreAudioError.operationFailed(operation: "resolve device UID", status: -1)
    }

    private static func isAggregateDevice(deviceID: AudioObjectID, uid: String, name: String? = nil) -> Bool {
        if uid.hasPrefix("io.github.brekkeliten.openaudiomatrix.") { return true }
        if uid.lowercased().contains("aggregate") { return true }
        if let name, name.lowercased().contains("aggregate") { return true }

        if let classID = try? readUInt32Property(
            objectID: deviceID,
            selector: kAudioObjectPropertyClass
        ), classID == kAudioAggregateDeviceClassID {
            return true
        }

        return false
    }

    /// Physical or virtual outputs users can route to — excludes tap aggregates and other internal devices.
    static func isRoutableOutputDevice(deviceID: AudioObjectID, uid: String, name: String) -> Bool {
        !isAggregateDevice(deviceID: deviceID, uid: uid, name: name)
    }

    static func isRoutableInputDevice(deviceID: AudioObjectID, uid: String, name: String) -> Bool {
        !isAggregateDevice(deviceID: deviceID, uid: uid, name: name)
    }

    private static func isUsableTapClockDevice(deviceID: AudioObjectID, uid: String) -> Bool {
        if isAggregateDevice(deviceID: deviceID, uid: uid) { return false }

        if let transport = try? readUInt32Property(
            objectID: deviceID,
            selector: kAudioDevicePropertyTransportType
        ), transport == kAudioDeviceTransportTypeVirtual {
            return false
        }

        return (try? outputChannelCount(deviceID: deviceID)) ?? 0 > 0
    }

    static func tapClockDeviceUID(avoiding excludedUID: String) throws -> String {
        try tapClockDeviceUID(avoiding: [excludedUID])
    }

    static func builtInSpeakerDeviceUID() throws -> String? {
        let deviceIDs = try getPropertyDataArray(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyDevices
        )
        for deviceID in deviceIDs {
            guard let transport = try? readUInt32Property(
                objectID: deviceID,
                selector: kAudioDevicePropertyTransportType
            ), transport == kAudioDeviceTransportTypeBuiltIn else {
                continue
            }
            guard let uid = try? readStringProperty(
                objectID: deviceID,
                selector: kAudioDevicePropertyDeviceUID
            ), !uid.isEmpty, uid.localizedCaseInsensitiveContains("speaker") else {
                continue
            }
            guard (try? outputChannelCount(deviceID: deviceID)) ?? 0 > 0 else {
                continue
            }
            return uid
        }
        return nil
    }

    static func builtInOutputDeviceUID() throws -> String? {
        let deviceIDs = try getPropertyDataArray(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyDevices
        )
        for deviceID in deviceIDs {
            guard let transport = try? readUInt32Property(
                objectID: deviceID,
                selector: kAudioDevicePropertyTransportType
            ), transport == kAudioDeviceTransportTypeBuiltIn else {
                continue
            }
            guard let uid = try? readStringProperty(
                objectID: deviceID,
                selector: kAudioDevicePropertyDeviceUID
            ), !uid.isEmpty else {
                continue
            }
            guard (try? outputChannelCount(deviceID: deviceID)) ?? 0 > 0 else {
                continue
            }
            return uid
        }
        return nil
    }

    private static func outputChannelCount(deviceID: AudioObjectID) throws -> Int {
        var address = propertyAddress(
            selector: kAudioDevicePropertyStreamConfiguration,
            scope: kAudioDevicePropertyScopeOutput
        )
        var size: UInt32 = 0
        try checkOSStatus(
            AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size),
            operation: "stream configuration size"
        )
        guard size > 0 else { return 0 }

        let bufferList = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(size))
        defer { bufferList.deallocate() }

        try checkOSStatus(
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, bufferList),
            operation: "stream configuration"
        )

        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func checkOSStatus(_ status: OSStatus, operation: String) throws {
        guard status == noErr else {
            throw CoreAudioError.operationFailed(operation: operation, status: status)
        }
    }
}

enum CoreAudioError: Error, CustomStringConvertible {
    case propertyReadFailed(selector: AudioObjectPropertySelector, status: OSStatus)
    case operationFailed(operation: String, status: OSStatus)
    case noDefaultOutputDevice
    case noDefaultInputDevice
    case noUsableTapClockDevice

    public var description: String {
        switch self {
        case .propertyReadFailed(let selector, let status):
            "Property read failed (selector: \(selector), status: \(status))"
        case .operationFailed(let operation, let status):
            "\(operation) failed (status: \(status))"
        case .noDefaultOutputDevice:
            "No default output device is configured"
        case .noDefaultInputDevice:
            "No default input device is configured"
        case .noUsableTapClockDevice:
            "No usable tap clock device is available"
        }
    }
}
