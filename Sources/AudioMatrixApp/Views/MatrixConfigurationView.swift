import AudioMatrixCore
import SwiftUI

private enum MatrixRemovalRequest: Identifiable {
    case destination(uid: String, name: String, routeCount: Int)
    case source(id: String, name: String, routeCount: Int)

    var id: String {
        switch self {
        case .destination(let uid, _, _):
            "destination-\(uid)"
        case .source(let id, _, _):
            "source-\(id)"
        }
    }
}

struct MatrixConfigurationView: View {
    @Bindable var model: AppViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var removalRequest: MatrixRemovalRequest?
    @State private var showResetConfirm = false

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()

            HStack(spacing: 0) {
                outputDevicesPanel
                Divider()
                sourcesPanel
            }

            Divider()
            footerBar
        }
        .frame(minWidth: 700, minHeight: 460)
        .confirmationDialog(
            removalDialogTitle,
            isPresented: Binding(
                get: { removalRequest != nil },
                set: { if !$0 { removalRequest = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove and Disconnect", role: .destructive) {
                confirmRemoval()
            }
            Button("Cancel", role: .cancel) {
                removalRequest = nil
            }
        } message: {
            Text(removalDialogMessage)
        }
        .confirmationDialog(
            "Reset matrix?",
            isPresented: $showResetConfirm,
            titleVisibility: .visible
        ) {
            Button("Reset Everything", role: .destructive) {
                model.resetMatrixLayout()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes all sources and outputs from the matrix and disconnects every active route.")
        }
    }

    private var removalDialogTitle: String {
        switch removalRequest {
        case .destination:
            "Remove output device?"
        case .source:
            "Remove source?"
        case .none:
            ""
        }
    }

    private var removalDialogMessage: String {
        switch removalRequest {
        case .destination(_, let name, let routeCount):
            "\(name) has \(routeCount) active \(routeCount == 1 ? "route" : "routes"). Removing it will disconnect those routes and hide it from the matrix."
        case .source(_, let name, let routeCount):
            "\(name) has \(routeCount) active \(routeCount == 1 ? "route" : "routes"). Removing it will disconnect those routes and hide it from the matrix."
        case .none:
            ""
        }
    }

    private func confirmRemoval() {
        switch removalRequest {
        case .destination(let uid, _, _):
            model.hideDeviceFromMatrix(uid: uid, disconnectRoutes: true)
        case .source(let id, _, _):
            model.hideSourceFromMatrix(bundleID: id, disconnectRoutes: true)
        case .none:
            break
        }
        removalRequest = nil
    }

    private func requestRemoveDestination(_ device: MatrixDestinationGroup) {
        let routeCount = model.activeRouteCount(forDestination: device.deviceUID)
        if routeCount > 0 {
            removalRequest = .destination(
                uid: device.deviceUID,
                name: device.displayName,
                routeCount: routeCount
            )
        } else {
            model.hideDeviceFromMatrix(uid: device.deviceUID)
        }
    }

    private func requestRemoveSource(_ item: MatrixSourceGroup) {
        let routeCount = model.activeRouteCount(forSource: item.id)
        if routeCount > 0 {
            removalRequest = .source(
                id: item.id,
                name: item.displayName,
                routeCount: routeCount
            )
        } else {
            model.hideSourceFromMatrix(bundleID: item.id)
        }
    }

    private var headerBar: some View {
        HStack {
            Text("Configure Matrix")
                .font(.title2.bold())
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding()
    }

    private var footerBar: some View {
        HStack {
            Text("Drag rows to reorder. Reset clears the entire matrix.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Reset Layout") { showResetConfirm = true }
        }
        .padding()
    }

    private var outputDevicesPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            panelTitle("Outputs", icon: "hifispeaker.fill", subtitle: "Drag to set column order ← →")

            List {
                ForEach(model.matrixDestinationGroups) { device in
                    HStack(spacing: 10) {
                        Image(systemName: "line.3.horizontal")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .frame(width: 16)

                        Text(device.displayName)
                            .foregroundStyle(device.isAvailable ? .primary : .tertiary)

                        if !device.isAvailable {
                            Text("Offline")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }

                        Spacer()

                        Text("\(device.monoChannels.count) ch")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Button {
                            requestRemoveDestination(device)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .opacity(device.isAvailable ? 1 : MatrixTheme.unavailableOpacity)
                }
                .onMove { source, destination in
                    model.moveDestinationInMatrix(from: source, to: destination)
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))

            addOutputMenu
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sourcesPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            panelTitle("Sources", icon: "square.grid.3x1.fill.below.line.grid.1x2", subtitle: "Drag to set row order ↑ ↓")

            List {
                ForEach(model.matrixSourceGroups) { item in
                    HStack(spacing: 10) {
                        Image(systemName: "line.3.horizontal")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .frame(width: 16)

                        Text(item.displayName)
                            .foregroundStyle(item.isAvailable ? .primary : .tertiary)

                        if !item.isAvailable {
                            Text("Offline")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }

                        Spacer()

                        Button {
                            requestRemoveSource(item)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .opacity(item.isAvailable ? 1 : MatrixTheme.unavailableOpacity)
                }
                .onMove { source, destination in
                    model.moveSourceInMatrix(from: source, to: destination)
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))

            addSourceMenu
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func panelTitle(_ title: String, icon: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(title, systemImage: icon)
                .font(.headline)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        .padding(.top, 12)
    }

    private var addOutputMenu: some View {
        Menu {
            ForEach(model.devicesNotInMatrix) { device in
                Button(device.name) {
                    model.showDeviceInMatrix(device)
                }
            }
        } label: {
            Label("Add Output Device…", systemImage: "plus.circle")
        }
        .disabled(model.devicesNotInMatrix.isEmpty)
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    private var addSourceMenu: some View {
        Menu {
            ForEach(model.sourcesNotInMatrix) { item in
                Button(item.name) {
                    model.showSourceInMatrix(bundleID: item.id, displayName: item.name)
                }
            }
        } label: {
            Label("Add Source…", systemImage: "plus.circle")
        }
        .disabled(model.sourcesNotInMatrix.isEmpty)
        .padding(.horizontal)
        .padding(.bottom, 8)
    }
}

struct MatrixConfigSourceItem: Identifiable, Hashable {
    let id: String
    let name: String
}
