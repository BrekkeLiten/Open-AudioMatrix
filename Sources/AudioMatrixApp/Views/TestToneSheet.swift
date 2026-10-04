import AudioMatrixCore
import SwiftUI

struct TestToneSheet: View {
    @Bindable var model: AppViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var selectedDeviceUID: String = ""
    @State private var selectedChannels: Set<Int> = [1]
    @State private var selectionAnchor: Int = 1
    @State private var channelText = "1"
    @State private var selectedSignal: TestSignalKind = .sine440
    @State private var modifierFlags: EventModifiers = []

    private let gridColumns = Array(repeating: GridItem(.fixed(44), spacing: 6), count: 8)

    private var devices: [OutputDeviceInfo] {
        model.devicesInMatrixOrder.isEmpty ? model.devices : model.devicesInMatrixOrder
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Test Signal")
                .font(.title3.weight(.semibold))

            Text("Play a test signal on one or more output channels. Shift-click a range, ⌘-click to toggle.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if devices.isEmpty {
                Text("No output devices available.")
                    .foregroundStyle(.secondary)
            } else {
                Picker("Signal", selection: $selectedSignal) {
                    ForEach(TestSignalKind.allCases) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .pickerStyle(.segmented)

                Picker("Device", selection: $selectedDeviceUID) {
                    ForEach(devices) { device in
                        Text(device.name).tag(device.uid)
                    }
                }

                HStack(spacing: 8) {
                    Text("Channels")
                        .foregroundStyle(.secondary)
                    TextField("1,2,3", text: $channelText)
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 120, maxWidth: 180)
                        .onSubmit(applyChannelText)
                    Text("of \(channelCount)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(selectionSummary)
                        .font(.system(.caption, design: .monospaced).weight(.semibold))
                        .multilineTextAlignment(.trailing)
                }

                ScrollView {
                    LazyVGrid(columns: gridColumns, spacing: 6) {
                        ForEach(channels, id: \.self) { channel in
                            channelButton(channel)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: min(channelGridHeight, 280))
            }

            HStack(alignment: .center, spacing: 12) {
                if model.testToneActive {
                    Label(playingStatusText, systemImage: "speaker.wave.2.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                if let error = model.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Button("Close") { dismiss() }
                if !devices.isEmpty {
                    Button(model.testToneActive ? "Stop" : "Start") {
                        if model.testToneActive {
                            model.stopTestTone()
                        } else {
                            applyChannelText()
                            startWithCurrentSelection()
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(sortedSelectedChannels.isEmpty)
                }
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear {
            restoreSelectionFromSession()
        }
        .onChange(of: selectedSignal) {
            guard model.testToneActive else { return }
            applyChannelText()
            startWithCurrentSelection()
        }
        .onChange(of: selectedDeviceUID) {
            clampSelectedChannels()
            syncChannelText()
        }
        .onModifierKeysChanged(initial: true) { _, new in
            modifierFlags = new
        }
    }

    private func channelButton(_ channel: Int) -> some View {
        let isSelected = selectedChannels.contains(channel)
        let label = channelButtonLabel(channel)
        return Button {
            handleChannelTap(channel)
        } label: {
            Text(label)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: 44, height: 28)
                .background {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isSelected ? MatrixTheme.connectedFill : MatrixTheme.disconnectedFill)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(
                            isSelected ? Color.white.opacity(0.2) : MatrixTheme.disconnectedBorder,
                            lineWidth: 0.5
                        )
                }
                .foregroundStyle(isSelected ? Color.white : Color.secondary)
        }
        .buttonStyle(.plain)
        .help(model.destinationChannelLabel(deviceUID: selectedDeviceUID, monoChannel: channel))
    }

    private func handleChannelTap(_ channel: Int) {
        let shift = modifierFlags.contains(.shift)
        let command = modifierFlags.contains(.command)

        if shift {
            let lo = min(selectionAnchor, channel)
            let hi = max(selectionAnchor, channel)
            if command {
                selectedChannels.formUnion(lo...hi)
            } else {
                selectedChannels = Set(lo...hi)
            }
        } else if command {
            if selectedChannels.contains(channel) {
                if selectedChannels.count > 1 {
                    selectedChannels.remove(channel)
                }
            } else {
                selectedChannels.insert(channel)
            }
            selectionAnchor = channel
        } else {
            selectedChannels = [channel]
            selectionAnchor = channel
        }

        syncChannelText()
        if model.testToneActive {
            startWithCurrentSelection()
        }
    }

    private func startWithCurrentSelection() {
        model.startTestTone(
            deviceUID: selectedDeviceUID,
            channels: sortedSelectedChannels,
            signalKind: selectedSignal
        )
    }

    private func restoreSelectionFromSession() {
        if selectedDeviceUID.isEmpty, let first = devices.first {
            selectedDeviceUID = first.uid
        }
        if model.testToneActive,
           let deviceUID = model.session?.testToneOutputDeviceUID,
           devices.contains(where: { $0.uid == deviceUID }) {
            selectedDeviceUID = deviceUID
        }
        if let channels = model.session?.testToneChannels, !channels.isEmpty {
            selectedChannels = Set(channels)
            selectionAnchor = channels.min() ?? 1
        }
        if let signal = model.session?.testToneSignalKind {
            selectedSignal = signal
        }
        clampSelectedChannels()
        syncChannelText()
    }

    private func channelButtonLabel(_ channel: Int) -> String {
        let full = model.destinationChannelLabel(deviceUID: selectedDeviceUID, monoChannel: channel)
        let numeric = String(format: "%02d", channel)
        if full == numeric { return numeric }
        if full.count <= 5 { return full }
        return String(full.prefix(4)) + "…"
    }

    private func applyChannelText() {
        let parsed = parseChannelText(channelText)
        guard !parsed.isEmpty else {
            syncChannelText()
            return
        }
        selectedChannels = Set(parsed.filter { $0 >= 1 && $0 <= channelCount })
        if selectedChannels.isEmpty {
            selectedChannels = [1]
        }
        selectionAnchor = sortedSelectedChannels.first ?? 1
        syncChannelText()
    }

    private func parseChannelText(_ text: String) -> [Int] {
        var values: [Int] = []
        for part in text.split(separator: ",") {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if trimmed.contains("-") {
                let bounds = trimmed.split(separator: "-", maxSplits: 1)
                    .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                guard bounds.count == 2 else { continue }
                values.append(contentsOf: min(bounds[0], bounds[1])...max(bounds[0], bounds[1]))
            } else if let value = Int(trimmed) {
                values.append(value)
            }
        }
        return values
    }

    private func syncChannelText() {
        channelText = sortedSelectedChannels.map(String.init).joined(separator: ",")
    }

    private func clampSelectedChannels() {
        selectedChannels = Set(selectedChannels.filter { $0 >= 1 && $0 <= channelCount })
        if selectedChannels.isEmpty {
            selectedChannels = [min(max(selectionAnchor, 1), channelCount)]
        }
        selectionAnchor = min(max(selectionAnchor, 1), channelCount)
    }

    private var sortedSelectedChannels: [Int] {
        selectedChannels.sorted()
    }

    private var playingStatusText: String {
        let signal = model.session?.testToneSignalKind ?? selectedSignal
        return "\(signal.displayName) is playing"
    }

    private var selectionSummary: String {
        let sorted = sortedSelectedChannels
        guard !sorted.isEmpty else { return "—" }
        if sorted.count == 1 {
            return String(format: "%02d", sorted[0])
        }
        return "\(sorted.count) selected"
    }

    private var selectedDevice: OutputDeviceInfo? {
        devices.first { $0.uid == selectedDeviceUID }
    }

    private var channelCount: Int {
        max(selectedDevice?.outputChannelCount ?? 2, 1)
    }

    private var channels: [Int] {
        Array(1...channelCount)
    }

    private var channelGridHeight: CGFloat {
        let rows = CGFloat((channelCount + gridColumns.count - 1) / gridColumns.count)
        return rows * 34 + 8
    }
}
