import Foundation

public enum SourceCatalogBuilder {
    public struct RunningApp: Sendable, Hashable {
        public var bundleID: String
        public var name: String

        public init(bundleID: String, name: String) {
            self.bundleID = bundleID
            self.name = name
        }
    }

    public static func build(
        from processes: [AudioProcessInfo],
        additionalRunningApps: [RunningApp] = []
    ) -> SourceCatalogSnapshot {
        var userApps: [String: AudioProcessInfo] = [:]
        var systemPlaying = false

        for process in processes {
            let parent = BundleIDMatcher.parentBundleID(of: process.bundleID)
            if isUserFacingApplication(bundleID: parent, displayName: process.name) {
                if var existing = userApps[parent] {
                    existing.isRunningOutput = existing.isRunningOutput || process.isRunningOutput
                    existing.isRunningInput = existing.isRunningInput || process.isRunningInput
                    if process.isRunningOutput || process.isRunningInput {
                        existing.pid = process.pid
                    }
                    userApps[parent] = existing
                } else {
                    userApps[parent] = AudioProcessInfo(
                        bundleID: parent,
                        pid: process.pid,
                        name: friendlyName(bundleID: parent, fallback: process.name),
                        isRunningOutput: process.isRunningOutput,
                        isRunningInput: process.isRunningInput
                    )
                }
            } else if parent.hasPrefix("com.apple.") || process.bundleID.hasPrefix("com.apple.") {
                systemPlaying = systemPlaying || process.isRunningOutput
            }
        }

        var playing: [SourceCatalogEntry] = []
        var available: [SourceCatalogEntry] = []

        let systemEntry = SourceCatalogEntry(
            bundleID: SourceCatalog.systemSoundsBundleID,
            name: "System Sounds",
            isPlayingAudio: systemPlaying,
            category: .systemSounds
        )
        if systemPlaying {
            playing.append(systemEntry)
        } else {
            available.append(systemEntry)
        }

        for app in userApps.values.sorted(by: { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) {
            let entry = SourceCatalogEntry(
                bundleID: app.bundleID,
                name: app.name,
                isPlayingAudio: app.isRunningOutput,
                category: .userApplication
            )
            if app.isRunningOutput {
                playing.append(entry)
            } else {
                available.append(entry)
            }
        }

        for app in additionalRunningApps {
            guard !app.bundleID.isEmpty,
                  !SourceCatalog.isSystemSoundsBundleID(app.bundleID),
                  isUserFacingApplication(bundleID: app.bundleID, displayName: app.name),
                  userApps[app.bundleID] == nil else {
                continue
            }
            available.append(SourceCatalogEntry(
                bundleID: app.bundleID,
                name: app.name,
                isPlayingAudio: false,
                category: .userApplication
            ))
        }

        available.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return SourceCatalogSnapshot(playing: playing, available: available)
    }

    public static func isUserFacingApplication(bundleID: String, displayName: String) -> Bool {
        if SourceCatalog.isSystemSoundsBundleID(bundleID) { return false }
        if !bundleID.hasPrefix("com.apple.") { return true }
        return displayName != bundleID && !displayName.hasPrefix("com.")
    }

    private static func friendlyName(bundleID: String, fallback: String) -> String {
        if fallback != bundleID, !fallback.hasPrefix("com.") {
            return fallback
        }
        return bundleID
    }
}
