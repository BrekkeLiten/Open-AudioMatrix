import CoreAudio
import Foundation
import os

/// Listens for CoreAudio device hotplug and default-output changes.
public final class DeviceChangeListener: @unchecked Sendable {
    private let logger = Logger(subsystem: "io.github.brekkeliten.openaudiomatrix", category: "DeviceChange")
    private let queue = DispatchQueue(label: "io.github.brekkeliten.openaudiomatrix.device-change")
    private var deviceListListener: AudioObjectPropertyListenerBlock?
    private var defaultOutputListener: AudioObjectPropertyListenerBlock?
    private var isListening = false

    public var onChange: (() -> Void)?

    public init() {}

    public func start() {
        queue.sync {
            guard !isListening else { return }
            let systemObject = AudioObjectID(kAudioObjectSystemObject)

            var deviceAddress = CoreAudioHelpers.propertyAddress(selector: kAudioHardwarePropertyDevices)
            let deviceBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.notifyChange()
            }
            do {
                try CoreAudioHelpers.checkOSStatus(
                    AudioObjectAddPropertyListenerBlock(
                        systemObject, &deviceAddress, queue, deviceBlock
                    ),
                    operation: "kAudioHardwarePropertyDevices listener"
                )
                deviceListListener = deviceBlock
            } catch {
                logger.error("Device list listener failed: \(error.localizedDescription, privacy: .public)")
            }

            var defaultAddress = CoreAudioHelpers.propertyAddress(
                selector: kAudioHardwarePropertyDefaultOutputDevice
            )
            let defaultBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.notifyChange()
            }
            do {
                try CoreAudioHelpers.checkOSStatus(
                    AudioObjectAddPropertyListenerBlock(
                        systemObject, &defaultAddress, queue, defaultBlock
                    ),
                    operation: "kAudioHardwarePropertyDefaultOutputDevice listener"
                )
                defaultOutputListener = defaultBlock
            } catch {
                logger.error("Default output listener failed: \(error.localizedDescription, privacy: .public)")
            }

            isListening = true
        }
    }

    public func stop() {
        queue.sync {
            guard isListening else { return }
            let systemObject = AudioObjectID(kAudioObjectSystemObject)

            if let deviceListListener {
                var deviceAddress = CoreAudioHelpers.propertyAddress(selector: kAudioHardwarePropertyDevices)
                AudioObjectRemovePropertyListenerBlock(systemObject, &deviceAddress, queue, deviceListListener)
            }
            if let defaultOutputListener {
                var defaultAddress = CoreAudioHelpers.propertyAddress(
                    selector: kAudioHardwarePropertyDefaultOutputDevice
                )
                AudioObjectRemovePropertyListenerBlock(systemObject, &defaultAddress, queue, defaultOutputListener)
            }

            deviceListListener = nil
            defaultOutputListener = nil
            isListening = false
        }
    }

    private func notifyChange() {
        onChange?()
    }
}
