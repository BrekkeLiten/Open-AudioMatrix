import AppKit
import AudioMatrixCore
import CoreAudio
import Foundation

public enum ProcessEnumerator {
    public static func listAudioProcesses() throws -> [AudioProcessInfo] {
        let processObjects = try CoreAudioHelpers.getPropertyDataArray(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyProcessObjectList
        )

        var byParentBundle: [String: AudioProcessInfo] = [:]

        for processObject in processObjects {
            guard let bundleID = try? CoreAudioHelpers.readStringProperty(
                objectID: processObject,
                selector: kAudioProcessPropertyBundleID
            ), !bundleID.isEmpty else {
                continue
            }

            let pid = (try? CoreAudioHelpers.readPID(objectID: processObject)) ?? -1
            let isRunningOutput = ((try? CoreAudioHelpers.readUInt32Property(
                objectID: processObject,
                selector: kAudioProcessPropertyIsRunningOutput
            )) ?? 0) != 0
            let isRunningInput = ((try? CoreAudioHelpers.readUInt32Property(
                objectID: processObject,
                selector: kAudioProcessPropertyIsRunningInput
            )) ?? 0) != 0

            let parentBundle = BundleIDMatcher.parentBundleID(of: bundleID)
            let name = localizedName(forBundleID: parentBundle) ?? parentBundle

            if var existing = byParentBundle[parentBundle] {
                existing.isRunningOutput = existing.isRunningOutput || isRunningOutput
                existing.isRunningInput = existing.isRunningInput || isRunningInput
                if isRunningOutput || isRunningInput {
                    existing.pid = pid
                }
                byParentBundle[parentBundle] = existing
            } else {
                byParentBundle[parentBundle] = AudioProcessInfo(
                    bundleID: parentBundle,
                    pid: pid,
                    name: name,
                    isRunningOutput: isRunningOutput,
                    isRunningInput: isRunningInput
                )
            }
        }

        return byParentBundle.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public static func processObjectIDs(matchingBundleID bundleID: String) throws -> [AudioObjectID] {
        if SourceCatalog.isSystemSoundsBundleID(bundleID) {
            return try systemSoundsProcessObjectIDs()
        }

        let processObjects = try CoreAudioHelpers.getPropertyDataArray(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyProcessObjectList
        )

        return processObjects.filter { processObject in
            guard let candidate = try? CoreAudioHelpers.readStringProperty(
                objectID: processObject,
                selector: kAudioProcessPropertyBundleID
            ) else {
                return false
            }
            return BundleIDMatcher.matches(requestedBundleID: bundleID, candidateBundleID: candidate)
        }
    }

    private static func systemSoundsProcessObjectIDs() throws -> [AudioObjectID] {
        let processObjects = try CoreAudioHelpers.getPropertyDataArray(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyProcessObjectList
        )

        return processObjects.filter { processObject in
            guard let candidate = try? CoreAudioHelpers.readStringProperty(
                objectID: processObject,
                selector: kAudioProcessPropertyBundleID
            ) else {
                return false
            }
            let parent = BundleIDMatcher.parentBundleID(of: candidate)
            let name = localizedName(forBundleID: parent) ?? parent
            return parent.hasPrefix("com.apple.")
                && !SourceCatalogBuilder.isUserFacingApplication(bundleID: parent, displayName: name)
        }
    }

    public static func userFacingProcessObjectIDs() throws -> [AudioObjectID] {
        let processObjects = try CoreAudioHelpers.getPropertyDataArray(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyProcessObjectList
        )

        return processObjects.filter { processObject in
            guard let candidate = try? CoreAudioHelpers.readStringProperty(
                objectID: processObject,
                selector: kAudioProcessPropertyBundleID
            ) else {
                return false
            }
            let parent = BundleIDMatcher.parentBundleID(of: candidate)
            let name = localizedName(forBundleID: parent) ?? parent
            return SourceCatalogBuilder.isUserFacingApplication(bundleID: parent, displayName: name)
        }
    }

    private static func localizedName(forBundleID bundleID: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }
        return FileManager.default.displayName(atPath: url.path)
    }
}
