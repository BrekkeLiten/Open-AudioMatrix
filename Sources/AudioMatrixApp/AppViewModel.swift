import AppKit
import AudioMatrixCore
import Foundation
import SwiftUI

@MainActor
@Observable
final class AppViewModel {
    var devices: [OutputDeviceInfo] = []
    var inputDevices: [InputDeviceInfo] = []
    var sourceCatalog = SourceCatalogSnapshot()
    var session: RoutingSession?
    var audioConnections: [RouteKey: Bool] = [:]
    var mutedConnections: Set<RouteKey> = []
    private(set) var activeRouteSourceGroups: Set<String> = []
    private(set) var activeRouteDestinationGroups: Set<String> = []
    var collapsedSourceGroups: Set<String> = []
    var collapsedDestinationGroups: Set<String> = []
    var matrixSourceOrder: [String] = []
    var matrixDestinationOrder: [String] = []
    private var hiddenMatrixSourceIDs: Set<String> = []
    private var hiddenMatrixDestinationUIDs: Set<String> = []
    var sourceChannelCounts: [String: Int] = [:]
    var presets: [String] = []
    var running = false
    var statusMessage = "Ready"
    var errorMessage: String?
    var presetName = ""
    var autoStartRouting = true
    var showVUMeters = true
    var showPermissionsGuide = false
    let meters = MatrixMeterState()
    let windowVisibility = WindowVisibilityMonitor()
    private(set) var matrixLayout = MatrixLayoutSnapshot.empty
    private(set) var meterActiveLevelKeys: Set<String> = []

    private var pollTask: Task<Void, Never>?
    private var meterPollTask: Task<Void, Never>?
    private var routePatchTask: Task<Void, Never>?
    private var isApplyingRoute = false
    private var sourceDisplayNames: [String: String] = [:]
    private var destinationDisplayNames: [String: String] = [:]
    private var destinationChannelCounts: [String: Int] = [:]
    private var hasSeededMatrixLayout = false
    private var hasRestoredPersistedRoutes = false
    private var lastLayoutFingerprint: Int?

    var vuMetersActive: Bool {
        showVUMeters && windowVisibility.isVisibleOnDisplay
    }

    func onAppear() {
        loadAppPreferences()
        loadMatrixPreferences()
        windowVisibility.start()
        pollTask?.cancel()
        pollTask = Task {
            await refresh(includeCatalog: true)
            await restorePersistedRoutesIfNeeded()
            await autoStartRoutingIfNeeded()
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                tick += 1
                await refresh(includeCatalog: tick.isMultiple(of: 6))
            }
        }
        meterPollTask?.cancel()
        meterPollTask = Task {
            while !Task.isCancelled {
                await refreshMeters()
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
    }

    func onDisappear() {
        pollTask?.cancel()
        pollTask = nil
        meterPollTask?.cancel()
        meterPollTask = nil
        windowVisibility.stop()
        saveAppPreferences()
        saveMatrixPreferences()
    }

    func refresh(includeCatalog: Bool = true) async {
        do {
            try EngineClient.ensureEngineRunning()
            let status = try EngineClient.send(.status)
            applySessionIfChanged(status.session)
            if running != status.running {
                running = status.running
            }
            if !running {
                meterActiveLevelKeys = []
                meters.applyIfChanged([:], activeKeys: [])
            }

            if includeCatalog {
                let deviceResponse = try EngineClient.send(.listOutputDevices)
                applyDevicesIfChanged(deviceResponse.outputDevices ?? [])

                let inputResponse = try EngineClient.send(.listInputDevices)
                applyInputDevicesIfChanged(inputResponse.inputDevices ?? [])

                let processResponse = try EngineClient.send(.listProcesses)
                let catalog = mergeInputDevices(into: resolvedCatalog(from: processResponse))
                applySourceCatalogIfChanged(catalog)
                updateSourceDisplayNames()

                let presetResponse = try EngineClient.send(.listPresets)
                let newPresets = presetResponse.presets ?? []
                if newPresets != presets {
                    presets = newPresets
                }

                syncMatrixLayoutWithCatalog()
            }

            applySourceChannelCountsIfChanged(status.sourceChannelCounts ?? [:])

            ensureMatrixIncludesRoutedItems()
            rebuildMatrixLayoutIfNeeded()

            if !isApplyingRoute, let session {
                reconcileConnections(from: session)
            }

            statusMessage = running ? "Routing active" : "Stopped"
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = "Engine unavailable"
        }
    }

    private func refreshMeters() async {
        guard running, vuMetersActive else {
            clearMetersIfNeeded()
            return
        }
        do {
            let response = try EngineClient.send(.levels)
            meters.applyIfChanged(response.levels ?? [:], activeKeys: meterActiveLevelKeys)
        } catch {
            // Keep last meter values; main refresh loop surfaces engine errors.
        }
    }

    func updateMeterVisibility(activeLevelKeys: Set<String>) {
        let keys = vuMetersActive ? activeLevelKeys : []
        guard meterActiveLevelKeys != keys else { return }
        meterActiveLevelKeys = keys
        if !vuMetersActive {
            clearMetersIfNeeded()
        }
    }

    func vuMetersPreferenceChanged() {
        persistAppPreferences()
        if !showVUMeters {
            meterActiveLevelKeys = []
            clearMetersIfNeeded()
        }
    }

    private func clearMetersIfNeeded() {
        guard !meters.levels.isEmpty else { return }
        meters.applyIfChanged([:], activeKeys: [])
    }

    private func applySessionIfChanged(_ newSession: RoutingSession?) {
        let newSignature = sessionRouteSignature(newSession)
        let currentSignature = sessionRouteSignature(session)
        guard newSignature != currentSignature else { return }
        session = newSession
    }

    private func sessionRouteSignature(_ session: RoutingSession?) -> Set<String> {
        var items = Set((session?.sources ?? []).filter(\.enabled).map { route in
            "\(MatrixRouteCodec.routeKey(for: route))|muted:\(route.muted)"
        })
        if let session {
            items.insert(
                "testTone:\(session.testToneEnabled)|\(session.testToneOutputDeviceUID ?? "")|\(session.testToneChannels.map(String.init).joined(separator: ","))|\(session.testToneSignalKind.rawValue)"
            )
        }
        return items
    }

    private func applyDevicesIfChanged(_ newDevices: [OutputDeviceInfo]) {
        guard newDevices != devices else { return }
        devices = newDevices
    }

    private func applyInputDevicesIfChanged(_ newDevices: [InputDeviceInfo]) {
        guard newDevices != inputDevices else { return }
        inputDevices = newDevices
    }

    private func applySourceCatalogIfChanged(_ catalog: SourceCatalogSnapshot) {
        guard catalog != sourceCatalog else { return }
        sourceCatalog = catalog
    }

    private func applySourceChannelCountsIfChanged(_ engineCounts: [String: Int]) {
        var merged = sourceChannelCounts
        for (bundleID, count) in engineCounts where count > 0 {
            merged[bundleID] = max(merged[bundleID] ?? 0, count)
        }
        applyStaticInputChannelCounts(to: &merged)
        guard merged != sourceChannelCounts else { return }
        sourceChannelCounts = merged
    }

    private func loadAppPreferences() {
        let prefs = AppPreferences.load()
        autoStartRouting = prefs.autoStartRouting
        showVUMeters = prefs.showVUMeters
        showPermissionsGuide = !prefs.hasDismissedPermissionsGuide
    }

    private func saveAppPreferences() {
        var prefs = AppPreferences.load()
        prefs.autoStartRouting = autoStartRouting
        prefs.showVUMeters = showVUMeters
        prefs.save()
    }

    func dismissPermissionsGuide(permanently: Bool) {
        showPermissionsGuide = false
        if permanently {
            var prefs = AppPreferences.load()
            prefs.hasDismissedPermissionsGuide = true
            prefs.save()
        }
    }

    func persistAppPreferences() {
        saveAppPreferences()
    }

    private func loadMatrixPreferences() {
        let prefs = MatrixPreferences.load()
        if !prefs.destinationOrder.isEmpty {
            matrixDestinationOrder = prefs.destinationOrder
            hasSeededMatrixLayout = true
        }
        if !prefs.sourceOrder.isEmpty {
            matrixSourceOrder = prefs.sourceOrder
            hasSeededMatrixLayout = true
        }

        if !prefs.collapsedDestinationGroups.isEmpty {
            collapsedDestinationGroups = Set(prefs.collapsedDestinationGroups)
        } else if let expandedDest = prefs.expandedDestinationGroups {
            collapsedDestinationGroups = Set(matrixDestinationOrder).subtracting(expandedDest)
        } else {
            collapsedDestinationGroups = []
        }

        if !prefs.collapsedSourceGroups.isEmpty {
            collapsedSourceGroups = Set(prefs.collapsedSourceGroups)
        } else if let expandedSrc = prefs.expandedSourceGroups {
            collapsedSourceGroups = Set(matrixSourceOrder).subtracting(expandedSrc)
        } else {
            collapsedSourceGroups = []
        }

        mutedConnections = Set(prefs.mutedRouteKeys)
        if !prefs.sourceDisplayNames.isEmpty {
            sourceDisplayNames = prefs.sourceDisplayNames
        }
        if !prefs.destinationDisplayNames.isEmpty {
            destinationDisplayNames = prefs.destinationDisplayNames
        }
        if !prefs.destinationChannelCounts.isEmpty {
            destinationChannelCounts = prefs.destinationChannelCounts
        }
        hiddenMatrixSourceIDs = Set(prefs.hiddenSourceIDs)
        hiddenMatrixDestinationUIDs = Set(prefs.hiddenDestinationUIDs)

        var seededFromRoutes = false
        for route in prefs.savedRoutes where route.enabled {
            seededFromRoutes = includeRoutedItem(route) || seededFromRoutes
        }
        if seededFromRoutes {
            saveMatrixPreferences()
        }

        if MatrixPreferences.hasPersistedPreferences {
            hasSeededMatrixLayout = true
        }

        rebuildMatrixLayout()
    }

    private func saveMatrixPreferences(session: RoutingSession? = nil) {
        let routes = session?.sources.filter(\.enabled) ?? self.session?.sources.filter(\.enabled) ?? []
        MatrixPreferences(
            destinationOrder: matrixDestinationOrder,
            sourceOrder: matrixSourceOrder,
            collapsedDestinationGroups: Array(collapsedDestinationGroups),
            collapsedSourceGroups: Array(collapsedSourceGroups),
            savedRoutes: routes,
            mutedRouteKeys: Array(mutedConnections),
            sourceDisplayNames: sourceDisplayNames,
            destinationDisplayNames: destinationDisplayNames,
            destinationChannelCounts: destinationChannelCounts,
            hiddenSourceIDs: Array(hiddenMatrixSourceIDs).sorted(),
            hiddenDestinationUIDs: Array(hiddenMatrixDestinationUIDs).sorted()
        ).save()
    }

    private func routeSignatures(_ routes: [SourceRoute]) -> Set<String> {
        Set(routes.filter(\.enabled).map(MatrixRouteCodec.routeKey(for:)))
    }

    private func restorePersistedRoutesIfNeeded() async {
        guard !hasRestoredPersistedRoutes else { return }
        hasRestoredPersistedRoutes = true

        let prefs = MatrixPreferences.load()
        guard !prefs.savedRoutes.isEmpty else { return }

        let current = session?.sources ?? []
        let savedSignatures = routeSignatures(prefs.savedRoutes)
        let currentSignatures = routeSignatures(current)
        guard savedSignatures != currentSignatures else { return }

        isApplyingRoute = true
        defer { isApplyingRoute = false }

        do {
            for route in current where route.enabled {
                let signature = MatrixRouteCodec.routeKey(for: route)
                if !savedSignatures.contains(signature) {
                    _ = try EngineClient.send(.removeSource(
                        bundleID: route.bundleID,
                        outputDeviceUID: route.outputDeviceUID,
                        sourceChannel: route.sourceChannel,
                        outputChannel: route.outputChannel
                    ))
                }
            }

            for route in prefs.savedRoutes where route.enabled {
                let signature = MatrixRouteCodec.routeKey(for: route)
                if !currentSignatures.contains(signature) {
                    _ = try EngineClient.send(.addSource(
                        bundleID: route.bundleID,
                        outputDeviceUID: route.outputDeviceUID,
                        sourceChannel: route.sourceChannel,
                        outputChannel: route.outputChannel
                    ))
                }
                if route.muted {
                    _ = try EngineClient.send(.setRouteMuted(
                        bundleID: route.bundleID,
                        outputDeviceUID: route.outputDeviceUID,
                        sourceChannel: route.sourceChannel,
                        outputChannel: route.outputChannel,
                        muted: true
                    ))
                }
            }

            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func isSourceGroupExpanded(_ groupID: String) -> Bool {
        !collapsedSourceGroups.contains(groupID)
    }

    func isDestinationGroupExpanded(_ groupID: String) -> Bool {
        !collapsedDestinationGroups.contains(groupID)
    }

    private func syncMatrixLayoutWithCatalog() {
        updateDestinationMetadataFromConnectedDevices()
        updateSourceDisplayNames()

        if !hasSeededMatrixLayout {
            hasSeededMatrixLayout = true
            saveMatrixPreferences()
            return
        }

        collapsedDestinationGroups = collapsedDestinationGroups.intersection(matrixDestinationOrder)
        collapsedSourceGroups = collapsedSourceGroups.intersection(matrixSourceOrder)
    }

    private func updateDestinationMetadataFromConnectedDevices() {
        for device in devices {
            destinationDisplayNames[device.uid] = device.name
            destinationChannelCounts[device.uid] = device.outputChannelCount
        }
    }

    private func ensureMatrixIncludesRoutedItems() {
        var changed = false
        let routes = session?.sources.filter(\.enabled) ?? []

        for route in routes {
            changed = includeRoutedItem(route) || changed
        }

        if changed {
            saveMatrixPreferences()
        }
    }

    private func includeRoutedItem(_ route: SourceRoute) -> Bool {
        var changed = false
        let parent = BundleIDMatcher.parentBundleID(of: route.bundleID)

        if !hiddenMatrixSourceIDs.contains(parent) {
            if sourceDisplayNames[parent] == nil {
                sourceDisplayNames[parent] = displayName(for: parent)
                changed = true
            }
            if !matrixSourceOrder.contains(parent) {
                matrixSourceOrder.append(parent)
                changed = true
            }

            let neededSourceChannels = max(sourceChannelCounts[parent] ?? 0, route.sourceChannel)
            if neededSourceChannels > (sourceChannelCounts[parent] ?? 0) {
                sourceChannelCounts[parent] = neededSourceChannels
                changed = true
            }
        }

        if !hiddenMatrixDestinationUIDs.contains(route.outputDeviceUID) {
            if !matrixDestinationOrder.contains(route.outputDeviceUID) {
                matrixDestinationOrder.append(route.outputDeviceUID)
                changed = true
            }
            if destinationDisplayNames[route.outputDeviceUID] == nil {
                destinationDisplayNames[route.outputDeviceUID] = route.outputDeviceUID
                changed = true
            }

            let neededOutputChannels = max(destinationChannelCounts[route.outputDeviceUID] ?? 0, route.outputChannel)
            if neededOutputChannels > (destinationChannelCounts[route.outputDeviceUID] ?? 0) {
                destinationChannelCounts[route.outputDeviceUID] = neededOutputChannels
                changed = true
            }
        }

        return changed
    }

    func isSourceAvailable(_ bundleID: String) -> Bool {
        availableSourceIDs().contains(BundleIDMatcher.parentBundleID(of: bundleID))
    }

    func isDestinationAvailable(_ deviceUID: String) -> Bool {
        devices.contains { $0.uid == deviceUID }
    }

    private func availableSourceIDs() -> Set<String> {
        var ids = Set<String>()
        for entry in sourceCatalog.playing + sourceCatalog.available {
            ids.insert(BundleIDMatcher.parentBundleID(of: entry.bundleID))
        }
        return ids
    }

    private func orderedCatalogParentIDs() -> [String] {
        var seen = Set<String>()
        var parents: [String] = []
        for entry in sourceCatalog.playing + sourceCatalog.available {
            let parent = BundleIDMatcher.parentBundleID(of: entry.bundleID)
            guard seen.insert(parent).inserted else { continue }
            parents.append(parent)
        }
        return parents
    }

    private func updateSourceDisplayNames() {
        for entry in sourceCatalog.playing + sourceCatalog.available {
            let parent = BundleIDMatcher.parentBundleID(of: entry.bundleID)
            sourceDisplayNames[parent] = entry.name
        }
    }

    func displayName(for bundleID: String) -> String {
        let parent = BundleIDMatcher.parentBundleID(of: bundleID)
        return sourceDisplayNames[parent] ?? parent
    }

    private func reconcileConnections(from session: RoutingSession) {
        var connections: [RouteKey: Bool] = [:]
        var muted: Set<RouteKey> = []

        for source in session.sources where source.enabled {
            let keys = MatrixRouteCodec.diagonalRouteKeys(
                bundleID: source.bundleID,
                deviceUID: source.outputDeviceUID,
                sourceChannel: source.sourceChannel,
                outputChannel: source.outputChannel
            )
            for key in keys {
                connections[key] = true
                if source.muted {
                    muted.insert(key)
                }
            }
        }

        let connectionsChanged = connections != audioConnections
        let mutedChanged = muted != mutedConnections
        guard connectionsChanged || mutedChanged else { return }

        audioConnections = connections
        mutedConnections = muted
        updateActiveRouteGroups(from: connections)
        saveMatrixPreferences(session: session)
    }

    private func updateActiveRouteGroups(from connections: [RouteKey: Bool]) {
        var sources = Set<String>()
        var destinations = Set<String>()
        for (key, isOn) in connections where isOn {
            if let source = MatrixRouteCodec.parseSource(key.sourceId) {
                sources.insert(BundleIDMatcher.parentBundleID(of: source.bundleID))
            }
            if let destination = MatrixRouteCodec.parseDestination(key.destinationId) {
                destinations.insert(destination.deviceUID)
            }
        }
        activeRouteSourceGroups = sources
        activeRouteDestinationGroups = destinations
    }

    private func mergeInputDevices(into catalog: SourceCatalogSnapshot) -> SourceCatalogSnapshot {
        let playing = catalog.playing
        var available = catalog.available
        var existing = Set((playing + available).map(\.bundleID))

        for device in inputDevices {
            let bundleID = SourceCatalog.inputDeviceBundleID(uid: device.uid)
            guard existing.insert(bundleID).inserted else { continue }
            available.append(SourceCatalogEntry(
                bundleID: bundleID,
                name: device.name,
                isPlayingAudio: false,
                category: .inputDevice
            ))
        }

        available.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return SourceCatalogSnapshot(playing: playing, available: available)
    }

    private func applyStaticInputChannelCounts(to counts: inout [String: Int]) {
        for device in inputDevices {
            let bundleID = SourceCatalog.inputDeviceBundleID(uid: device.uid)
            counts[bundleID] = max(counts[bundleID] ?? 0, device.inputChannelCount)
        }
    }

    private func resolvedCatalog(from response: EngineResponse) -> SourceCatalogSnapshot {
        if let catalog = response.sourceCatalog,
           !catalog.playing.isEmpty || !catalog.available.isEmpty {
            return catalog
        }
        guard let processes = response.processes, !processes.isEmpty else {
            return SourceCatalogSnapshot()
        }
        let runningApps = NSWorkspace.shared.runningApplications.compactMap { app -> SourceCatalogBuilder.RunningApp? in
            guard let bundleID = app.bundleIdentifier, !bundleID.isEmpty else { return nil }
            return SourceCatalogBuilder.RunningApp(
                bundleID: bundleID,
                name: app.localizedName ?? bundleID
            )
        }
        return SourceCatalogBuilder.build(from: processes, additionalRunningApps: runningApps)
    }

    // MARK: - Matrix layout configuration

    var devicesInMatrixOrder: [OutputDeviceInfo] {
        let deviceByUID = Dictionary(uniqueKeysWithValues: devices.map { ($0.uid, $0) })
        return matrixDestinationOrder.compactMap { deviceByUID[$0] }
    }

    var devicesNotInMatrix: [OutputDeviceInfo] {
        devices.filter { !matrixDestinationOrder.contains($0.uid) }
    }

    var sourcesInMatrixOrder: [MatrixConfigSourceItem] {
        matrixSourceOrder.map { parent in
            MatrixConfigSourceItem(id: parent, name: displayName(for: parent))
        }
    }

    var sourcesNotInMatrix: [MatrixConfigSourceItem] {
        var seen = Set(matrixSourceOrder)
        var items: [MatrixConfigSourceItem] = []
        for entry in sourceCatalog.playing + sourceCatalog.available {
            let parent = BundleIDMatcher.parentBundleID(of: entry.bundleID)
            guard !seen.contains(parent) else { continue }
            seen.insert(parent)
            items.append(MatrixConfigSourceItem(id: parent, name: entry.name))
        }
        return items.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func moveDestinationInMatrix(from source: IndexSet, to destination: Int) {
        matrixDestinationOrder.move(fromOffsets: source, toOffset: destination)
        rebuildMatrixLayout()
        saveMatrixPreferences()
    }

    func moveSourceInMatrix(from source: IndexSet, to destination: Int) {
        matrixSourceOrder.move(fromOffsets: source, toOffset: destination)
        rebuildMatrixLayout()
        saveMatrixPreferences()
    }

    func resetMatrixLayout() {
        let patches = routePatches(
            for: audioConnections.compactMap { key, isOn in isOn ? key : nil }
        )

        matrixDestinationOrder = []
        matrixSourceOrder = []
        collapsedDestinationGroups = []
        collapsedSourceGroups = []
        hiddenMatrixSourceIDs = []
        hiddenMatrixDestinationUIDs = []

        if patches.isEmpty {
            audioConnections = [:]
            mutedConnections = []
            updateActiveRouteGroups(from: audioConnections)
        } else {
            applyLocalRouteRemoval(patches)
            enqueueRoutePatch {
                await self.applyRoutes(patches: patches, add: false)
            }
        }

        rebuildMatrixLayout()
        saveMatrixPreferences()
    }

    func showSourceInMatrix(bundleID: String, displayName: String) {
        let parent = BundleIDMatcher.parentBundleID(of: bundleID)
        hiddenMatrixSourceIDs.remove(parent)
        sourceDisplayNames[parent] = displayName
        if !matrixSourceOrder.contains(parent) {
            matrixSourceOrder.append(parent)
        }
        collapsedSourceGroups.remove(parent)
        rebuildMatrixLayout()
        saveMatrixPreferences()
    }

    func hideSourceFromMatrix(bundleID: String, disconnectRoutes: Bool = false) {
        let parent = BundleIDMatcher.parentBundleID(of: bundleID)
        if disconnectRoutes {
            disconnectAllRoutes(forSource: parent)
        }
        hiddenMatrixSourceIDs.insert(parent)
        matrixSourceOrder.removeAll { $0 == parent }
        collapsedSourceGroups.remove(parent)
        rebuildMatrixLayout()
        saveMatrixPreferences()
    }

    func showDeviceInMatrix(_ device: OutputDeviceInfo) {
        showDeviceInMatrix(uid: device.uid)
    }

    func showDeviceInMatrix(uid: String) {
        hiddenMatrixDestinationUIDs.remove(uid)
        if let device = devices.first(where: { $0.uid == uid }) {
            destinationDisplayNames[uid] = device.name
            destinationChannelCounts[uid] = device.outputChannelCount
        }
        if !matrixDestinationOrder.contains(uid) {
            matrixDestinationOrder.append(uid)
        }
        collapsedDestinationGroups.remove(uid)
        rebuildMatrixLayout()
        saveMatrixPreferences()
    }

    func hideDeviceFromMatrix(uid: String, disconnectRoutes: Bool = false) {
        if disconnectRoutes {
            disconnectAllRoutes(forDestination: uid)
        }
        hiddenMatrixDestinationUIDs.insert(uid)
        matrixDestinationOrder.removeAll { $0 == uid }
        collapsedDestinationGroups.remove(uid)
        rebuildMatrixLayout()
        saveMatrixPreferences()
    }

    func toggleSourceGroupExpanded(_ groupID: String) {
        if collapsedSourceGroups.contains(groupID) {
            collapsedSourceGroups.remove(groupID)
        } else {
            collapsedSourceGroups.insert(groupID)
        }
        rebuildMatrixLayout()
        saveMatrixPreferences()
    }

    func toggleDestinationGroupExpanded(_ groupID: String) {
        if collapsedDestinationGroups.contains(groupID) {
            collapsedDestinationGroups.remove(groupID)
        } else {
            collapsedDestinationGroups.insert(groupID)
        }
        rebuildMatrixLayout()
        saveMatrixPreferences()
    }

    // MARK: - Routing

    private func autoStartRoutingIfNeeded() async {
        guard autoStartRouting, !running else { return }
        do {
            let response = try EngineClient.send(.start)
            if !response.ok { errorMessage = response.message }
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func start() {
        Task {
            do {
                let response = try EngineClient.send(.start)
                if !response.ok { errorMessage = response.message }
                await refresh()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func stop() {
        Task {
            do {
                let response = try EngineClient.send(.stop)
                if !response.ok { errorMessage = response.message }
                await refresh()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func isConnected(_ key: RouteKey) -> Bool {
        audioConnections[key] == true
    }

    func isMuted(_ key: RouteKey) -> Bool {
        mutedConnections.contains(key)
    }

    func hasActiveRoutes(forDestination deviceUID: String) -> Bool {
        audioConnections.contains { key, isOn in
            guard isOn else { return false }
            guard let destination = MatrixRouteCodec.parseDestination(key.destinationId) else { return false }
            return destination.deviceUID == deviceUID
        }
    }

    func hasActiveRoutes(forSource bundleID: String) -> Bool {
        let parent = BundleIDMatcher.parentBundleID(of: bundleID)
        return audioConnections.contains { key, isOn in
            guard isOn else { return false }
            guard let source = MatrixRouteCodec.parseSource(key.sourceId) else { return false }
            return BundleIDMatcher.parentBundleID(of: source.bundleID) == parent
        }
    }

    func activeRouteCount(forDestination deviceUID: String) -> Int {
        activeRouteKeys(forDestination: deviceUID).count
    }

    func activeRouteCount(forSource bundleID: String) -> Int {
        activeRouteKeys(forSource: bundleID).count
    }

    private func activeRouteKeys(forDestination deviceUID: String) -> [RouteKey] {
        audioConnections.compactMap { key, isOn in
            guard isOn,
                  let destination = MatrixRouteCodec.parseDestination(key.destinationId),
                  destination.deviceUID == deviceUID else {
                return nil
            }
            return key
        }
    }

    private func activeRouteKeys(forSource bundleID: String) -> [RouteKey] {
        let parent = BundleIDMatcher.parentBundleID(of: bundleID)
        return audioConnections.compactMap { key, isOn in
            guard isOn,
                  let source = MatrixRouteCodec.parseSource(key.sourceId),
                  BundleIDMatcher.parentBundleID(of: source.bundleID) == parent else {
                return nil
            }
            return key
        }
    }

    private func disconnectAllRoutes(forDestination deviceUID: String) {
        let patches = routePatches(for: activeRouteKeys(forDestination: deviceUID))
        applyLocalRouteRemoval(patches)
        enqueueRoutePatch {
            await self.applyRoutes(patches: patches, add: false)
        }
    }

    private func disconnectAllRoutes(forSource bundleID: String) {
        let patches = routePatches(for: activeRouteKeys(forSource: bundleID))
        applyLocalRouteRemoval(patches)
        enqueueRoutePatch {
            await self.applyRoutes(patches: patches, add: false)
        }
    }

    private func routePatches(for keys: [RouteKey]) -> [RoutePatch] {
        keys.compactMap { key in
            guard let route = MatrixRouteCodec.engineRoute(
                sourceId: key.sourceId,
                destinationId: key.destinationId
            ) else {
                return nil
            }
            return (
                key: key,
                bundleID: route.bundleID,
                deviceUID: route.deviceUID,
                sourceChannel: route.sourceChannel,
                outputChannel: route.outputChannel
            )
        }
    }

    private func applyLocalRouteRemoval(_ patches: [RoutePatch]) {
        for patch in patches {
            setCrosspointDisconnected(patch.key)
            mutedConnections.remove(patch.key)
        }
        saveMatrixPreferences()
    }

    func toggleCrosspoint(_ key: RouteKey, modifiers: EventModifiers = []) {
        guard let route = MatrixRouteCodec.engineRoute(
            sourceId: key.sourceId,
            destinationId: key.destinationId
        ) else {
            return
        }
        guard isSourceAvailable(route.bundleID), isDestinationAvailable(route.deviceUID) else {
            return
        }

        if modifiers.contains(.shift),
           let source = MatrixRouteCodec.parseSource(key.sourceId),
           let destination = MatrixRouteCodec.parseDestination(key.destinationId) {
            executeDiagonalPatch(
                sourceGroupID: BundleIDMatcher.parentBundleID(of: source.bundleID),
                destinationGroupID: destination.deviceUID,
                anchorSourceChannel: source.monoChannel,
                anchorDestinationChannel: destination.monoChannel
            )
            return
        }

        if modifiers.contains(.option) {
            executeMutePatch(key)
            return
        }

        guard let route = MatrixRouteCodec.engineRoute(
            sourceId: key.sourceId,
            destinationId: key.destinationId
        ) else {
            return
        }

        let currentlyConnected = isConnected(key)
        let targetConnected = !currentlyConnected

        if targetConnected {
            setCrosspointConnected(key, connected: true)
        } else {
            setCrosspointDisconnected(key)
            mutedConnections.remove(key)
        }

        enqueueRoutePatch {
            await self.applyRoutes(
                patches: [
                    (
                        key: key,
                        bundleID: route.bundleID,
                        deviceUID: route.deviceUID,
                        sourceChannel: route.sourceChannel,
                        outputChannel: route.outputChannel
                    )
                ],
                add: targetConnected
            )
        }
    }

    func commitDiagonalDragPatch(keys: [RouteKey], targetConnected: Bool) {
        var patches: [RoutePatch] = []

        for key in keys {
            guard let route = MatrixRouteCodec.engineRoute(
                sourceId: key.sourceId,
                destinationId: key.destinationId
            ) else {
                continue
            }
            guard isSourceAvailable(route.bundleID), isDestinationAvailable(route.deviceUID) else {
                continue
            }

            let currentlyConnected = isConnected(key)
            guard currentlyConnected != targetConnected else { continue }

            if targetConnected {
                setCrosspointConnected(key, connected: true)
            } else {
                setCrosspointDisconnected(key)
                mutedConnections.remove(key)
            }

            patches.append(
                (
                    key: key,
                    bundleID: route.bundleID,
                    deviceUID: route.deviceUID,
                    sourceChannel: route.sourceChannel,
                    outputChannel: route.outputChannel
                )
            )
        }

        guard !patches.isEmpty else { return }

        enqueueRoutePatch {
            await self.applyRoutes(patches: patches, add: targetConnected)
        }
    }

    func executeDiagonalPatch(
        sourceGroupID: String,
        destinationGroupID: String,
        anchorSourceChannel: Int? = nil,
        anchorDestinationChannel: Int? = nil
    ) {
        guard isSourceAvailable(sourceGroupID), isDestinationAvailable(destinationGroupID) else {
            return
        }

        let allSourceChannels = sourceMonoChannels(for: sourceGroupID)
        let allDestinationChannels = destinationMonoChannels(for: destinationGroupID)

        let (sourceChannels, destinationChannels): ([Int], [Int])
        if let anchorSourceChannel, let anchorDestinationChannel {
            (sourceChannels, destinationChannels) = MatrixRouteCodec.diagonalPatchChannels(
                sourceMonoChannels: allSourceChannels,
                destinationMonoChannels: allDestinationChannels,
                anchorSourceChannel: anchorSourceChannel,
                anchorDestinationChannel: anchorDestinationChannel,
                maxPairs: 2
            )
        } else {
            sourceChannels = allSourceChannels
            destinationChannels = allDestinationChannels
        }

        guard !sourceChannels.isEmpty, !destinationChannels.isEmpty else { return }

        let routes = MatrixRouteCodec.diagonalPatchEngineRoutes(
            sourceBundleID: sourceGroupID,
            destinationDeviceUID: destinationGroupID,
            sourceMonoChannels: sourceChannels,
            destinationMonoChannels: destinationChannels
        )

        let keys = routes.map { route in
            RouteKey(
                sourceId: MatrixRouteCodec.sourceId(
                    bundleID: sourceGroupID,
                    monoChannel: route.sourceChannel
                ),
                destinationId: MatrixRouteCodec.destinationId(
                    deviceUID: destinationGroupID,
                    monoChannel: route.outputChannel
                )
            )
        }

        let isStereoToggle = anchorSourceChannel != nil && anchorDestinationChannel != nil
        let targetConnected = isStereoToggle
            ? !keys.allSatisfy(isRouteActiveInSession)
            : true

        if targetConnected {
            for key in keys {
                setCrosspointConnected(key, connected: true)
            }
        } else {
            for key in keys {
                setCrosspointDisconnected(key)
                mutedConnections.remove(key)
            }
        }

        enqueueRoutePatch {
            await self.applyRoutes(
                patches: zip(routes, keys).map { route, key in
                    (
                        key: key,
                        bundleID: route.bundleID,
                        deviceUID: route.deviceUID,
                        sourceChannel: route.sourceChannel,
                        outputChannel: route.outputChannel
                    )
                },
                add: targetConnected
            )
        }
    }

    func executeMutePatch(_ key: RouteKey) {
        guard let route = MatrixRouteCodec.engineRoute(
            sourceId: key.sourceId,
            destinationId: key.destinationId
        ) else {
            return
        }
        guard isSourceAvailable(route.bundleID), isDestinationAvailable(route.deviceUID) else {
            return
        }

        if isConnected(key), mutedConnections.contains(key) {
            mutedConnections.remove(key)
            saveMatrixPreferences()
            enqueueRoutePatch {
                await self.setRouteMuted(
                    bundleID: route.bundleID,
                    deviceUID: route.deviceUID,
                    sourceChannel: route.sourceChannel,
                    outputChannel: route.outputChannel,
                    muted: false
                )
            }
            return
        }

        if !isConnected(key) {
            setCrosspointConnected(key, connected: true)
        }
        mutedConnections.insert(key)
        saveMatrixPreferences()

        enqueueRoutePatch {
            if !self.isRouteActiveInSession(key) {
                await self.applyRoutes(
                    patches: [
                        (
                            key: key,
                            bundleID: route.bundleID,
                            deviceUID: route.deviceUID,
                            sourceChannel: route.sourceChannel,
                            outputChannel: route.outputChannel
                        )
                    ],
                    add: true
                )
            }
            await self.setRouteMuted(
                bundleID: route.bundleID,
                deviceUID: route.deviceUID,
                sourceChannel: route.sourceChannel,
                outputChannel: route.outputChannel,
                muted: true
            )
        }
    }

    private func setRouteMuted(
        bundleID: String,
        deviceUID: String,
        sourceChannel: Int,
        outputChannel: Int,
        muted: Bool
    ) async {
        do {
            let response = try EngineClient.send(.setRouteMuted(
                bundleID: bundleID,
                outputDeviceUID: deviceUID,
                sourceChannel: sourceChannel,
                outputChannel: outputChannel,
                muted: muted
            ))
            if !response.ok { errorMessage = response.message }
            await refresh(includeCatalog: false)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func destinationMonoChannels(for deviceUID: String) -> [Int] {
        if let group = matrixLayout.destinationGroups.first(where: { $0.deviceUID == deviceUID }) {
            return group.monoChannels
        }
        if let device = devices.first(where: { $0.uid == deviceUID }) {
            return Array(1...max(1, device.outputChannelCount))
        }
        return [1, 2]
    }

    private func sourceMonoChannels(for bundleID: String) -> [Int] {
        let parent = BundleIDMatcher.parentBundleID(of: bundleID)
        if let group = matrixLayout.sourceGroups.first(where: { $0.id == parent }) {
            return group.monoChannels
        }
        let count = sourceChannelCounts[parent] ?? MatrixLayoutBuilder.defaultSourceMonoChannels.count
        return Array(1...max(1, count))
    }

    private func isRouteActiveInSession(_ key: RouteKey) -> Bool {
        guard let route = MatrixRouteCodec.engineRoute(
            sourceId: key.sourceId,
            destinationId: key.destinationId
        ) else {
            return false
        }
        let parent = BundleIDMatcher.parentBundleID(of: route.bundleID)
        return session?.sources.contains { source in
            source.enabled
                && BundleIDMatcher.parentBundleID(of: source.bundleID) == parent
                && source.outputDeviceUID == route.deviceUID
                && source.sourceChannel == route.sourceChannel
                && source.outputChannel == route.outputChannel
        } ?? false
    }

    private func setCrosspointConnected(_ key: RouteKey, connected: Bool) {
        guard let route = MatrixRouteCodec.engineRoute(
            sourceId: key.sourceId,
            destinationId: key.destinationId
        ) else {
            audioConnections[key] = connected
            updateActiveRouteGroups(from: audioConnections)
            return
        }

        let keys = MatrixRouteCodec.diagonalRouteKeys(
            bundleID: route.bundleID,
            deviceUID: route.deviceUID,
            sourceChannel: route.sourceChannel,
            outputChannel: route.outputChannel
        )
        for diagonalKey in keys {
            audioConnections[diagonalKey] = connected
        }
        updateActiveRouteGroups(from: audioConnections)
    }

    private func setCrosspointDisconnected(_ key: RouteKey) {
        guard let route = MatrixRouteCodec.engineRoute(
            sourceId: key.sourceId,
            destinationId: key.destinationId
        ) else {
            audioConnections[key] = false
            updateActiveRouteGroups(from: audioConnections)
            return
        }

        let keys = MatrixRouteCodec.diagonalRouteKeys(
            bundleID: route.bundleID,
            deviceUID: route.deviceUID,
            sourceChannel: route.sourceChannel,
            outputChannel: route.outputChannel
        )
        for diagonalKey in keys {
            audioConnections[diagonalKey] = false
            mutedConnections.remove(diagonalKey)
        }
        updateActiveRouteGroups(from: audioConnections)
    }

    private func enqueueRoutePatch(_ operation: @escaping @MainActor () async -> Void) {
        let previous = routePatchTask
        routePatchTask = Task { @MainActor in
            await previous?.value
            await operation()
        }
    }

    private typealias RoutePatch = (
        key: RouteKey,
        bundleID: String,
        deviceUID: String,
        sourceChannel: Int,
        outputChannel: Int
    )

    private func applyRoutes(patches: [RoutePatch], add: Bool) async {
        guard !patches.isEmpty else { return }
        isApplyingRoute = true
        defer { isApplyingRoute = false }

        let requests = patches.map {
            RoutePatchRequest(
                bundleID: $0.bundleID,
                outputDeviceUID: $0.deviceUID,
                sourceChannel: $0.sourceChannel,
                outputChannel: $0.outputChannel
            )
        }

        do {
            let response = try EngineClient.send(
                add
                    ? .applyRouteChanges(add: requests, remove: [])
                    : .applyRouteChanges(add: [], remove: requests)
            )

            if !response.ok {
                errorMessage = response.message
                for patch in patches {
                    if add {
                        setCrosspointDisconnected(patch.key)
                    } else {
                        setCrosspointConnected(patch.key, connected: true)
                    }
                }
            } else if let responseSession = response.session {
                session = responseSession
            }

            await refresh(includeCatalog: false)
        } catch {
            errorMessage = error.localizedDescription
            for patch in patches {
                if add {
                    setCrosspointDisconnected(patch.key)
                } else {
                    setCrosspointConnected(patch.key, connected: true)
                }
            }
            await refresh(includeCatalog: false)
        }
    }

    func savePreset() {
        guard !presetName.isEmpty else { return }
        let name = presetName
        Task {
            do {
                let status = try EngineClient.send(.status)
                guard let session = status.session else { return }
                let preset = ShowPreset(
                    session: session,
                    matrix: currentMatrixSnapshot()
                )
                try PresetManager.save(showPreset: preset, name: name)
                presetName = ""
                await refresh()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func savePreset(named name: String) {
        presetName = name
        savePreset()
    }

    func loadPreset(_ name: String) {
        Task {
            do {
                let preset = try PresetManager.loadShowPreset(name: name)
                let response = try EngineClient.send(.applySession(preset.session))
                if !response.ok {
                    errorMessage = response.message
                    return
                }
                applyMatrixSnapshot(preset.matrix)
                rebuildMatrixLayout()
                saveMatrixPreferences(session: preset.session)
                await refresh()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func deletePreset(_ name: String) {
        Task {
            do {
                try PresetManager.delete(name: name)
                await refresh()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func currentMatrixSnapshot() -> MatrixPresetSnapshot {
        MatrixPresetSnapshot(
            destinationOrder: matrixDestinationOrder,
            sourceOrder: matrixSourceOrder,
            collapsedDestinationGroups: Array(collapsedDestinationGroups),
            collapsedSourceGroups: Array(collapsedSourceGroups),
            sourceDisplayNames: sourceDisplayNames,
            destinationDisplayNames: destinationDisplayNames,
            destinationChannelCounts: destinationChannelCounts
        )
    }

    private func applyMatrixSnapshot(_ snapshot: MatrixPresetSnapshot) {
        if !snapshot.destinationOrder.isEmpty {
            matrixDestinationOrder = snapshot.destinationOrder
            hasSeededMatrixLayout = true
        }
        if !snapshot.sourceOrder.isEmpty {
            matrixSourceOrder = snapshot.sourceOrder
            hasSeededMatrixLayout = true
        }
        collapsedDestinationGroups = Set(snapshot.collapsedDestinationGroups)
        collapsedSourceGroups = Set(snapshot.collapsedSourceGroups)
        if !snapshot.sourceDisplayNames.isEmpty {
            sourceDisplayNames = snapshot.sourceDisplayNames
        }
        if !snapshot.destinationDisplayNames.isEmpty {
            destinationDisplayNames = snapshot.destinationDisplayNames
        }
        if !snapshot.destinationChannelCounts.isEmpty {
            destinationChannelCounts = snapshot.destinationChannelCounts
        }
    }

    func destinationChannelLabel(deviceUID: String, monoChannel: Int) -> String {
        session?.channelLabel(deviceUID: deviceUID, channelStart: monoChannel)
            ?? String(format: "%02d", monoChannel)
    }

    func setChannelLabel(deviceUID: String, monoChannel: Int, label: String?) {
        Task {
            do {
                let response = try EngineClient.send(.setChannelLabel(
                    deviceUID: deviceUID,
                    channelStart: monoChannel,
                    label: label?.isEmpty == true ? nil : label
                ))
                if !response.ok { errorMessage = response.message }
                await refresh(includeCatalog: false)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    var testToneActive: Bool {
        session?.testToneEnabled == true
    }

    func startTestTone(deviceUID: String, channels: [Int], signalKind: TestSignalKind) {
        let sortedChannels = channels.filter { $0 >= 1 }.sorted()
        guard !sortedChannels.isEmpty else { return }
        Task {
            do {
                try EngineClient.ensureEngineRunning()
                let toneResponse = try EngineClient.send(.setTestTone(
                    outputDeviceUID: deviceUID,
                    channels: sortedChannels,
                    signalKind: signalKind,
                    enabled: true
                ))
                if !toneResponse.ok {
                    errorMessage = toneResponse.message
                    return
                }
                await refresh(includeCatalog: false)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func stopTestTone() {
        Task {
            do {
                let deviceUID = session?.testToneOutputDeviceUID ?? "default"
                let channels = session?.testToneChannels ?? [1]
                let signalKind = session?.testToneSignalKind ?? .sine440
                let response = try EngineClient.send(.setTestTone(
                    outputDeviceUID: deviceUID,
                    channels: channels,
                    signalKind: signalKind,
                    enabled: false
                ))
                if !response.ok { errorMessage = response.message }
                await refresh(includeCatalog: false)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    var matrixSourceGroups: [MatrixSourceGroup] { matrixLayout.sourceGroups }
    var matrixDestinationGroups: [MatrixDestinationGroup] { matrixLayout.destinationGroups }
    var matrixSourceColumns: [MatrixSourceColumn] { matrixLayout.sourceColumns }
    var matrixDestinationRows: [MatrixDestinationRow] { matrixLayout.destinationRows }

    private func matrixLayoutInputs() -> MatrixLayoutCache.Inputs {
        MatrixLayoutCache.Inputs(
            devices: devices,
            sourceCatalog: sourceCatalog,
            matrixSourceOrder: matrixSourceOrder,
            matrixDestinationOrder: matrixDestinationOrder,
            collapsedSourceGroups: collapsedSourceGroups,
            collapsedDestinationGroups: collapsedDestinationGroups,
            sourceDisplayNames: sourceDisplayNames,
            destinationDisplayNames: destinationDisplayNames,
            destinationChannelCounts: destinationChannelCounts,
            sourceChannelCounts: sourceChannelCounts,
            availableSourceIDs: availableSourceIDs(),
            availableDestinationUIDs: Set(devices.map(\.uid))
        )
    }

    private func rebuildMatrixLayoutIfNeeded() {
        let fingerprint = MatrixLayoutCache.fingerprint(from: matrixLayoutInputs())
        guard fingerprint != lastLayoutFingerprint else { return }
        lastLayoutFingerprint = fingerprint
        matrixLayout = MatrixLayoutCache.build(from: matrixLayoutInputs())
    }

    func rebuildMatrixLayout() {
        lastLayoutFingerprint = MatrixLayoutCache.fingerprint(from: matrixLayoutInputs())
        matrixLayout = MatrixLayoutCache.build(from: matrixLayoutInputs())
    }
}
