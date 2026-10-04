import SwiftUI

struct PresetsView: View {
    @Bindable var model: AppViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var presetToDelete: String?
    @State private var showOverwriteConfirm = false
    @State private var pendingSaveName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Show Presets")
                .font(.title2.weight(.semibold))

            Text("Presets save routes, mute state, channel labels, and matrix layout.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                TextField("Preset name", text: $model.presetName)
                    .textFieldStyle(.roundedBorder)
                Button("Save") {
                    let trimmed = model.presetName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    if model.presets.contains(trimmed) {
                        pendingSaveName = trimmed
                        showOverwriteConfirm = true
                    } else {
                        model.savePreset(named: trimmed)
                    }
                }
                .disabled(model.presetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if model.presets.isEmpty {
                Text("No presets saved yet.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
            } else {
                List(model.presets, id: \.self) { name in
                    HStack {
                        Text(name)
                        Spacer()
                        Button("Load") {
                            model.loadPreset(name)
                        }
                        Button("Delete", role: .destructive) {
                            presetToDelete = name
                        }
                    }
                }
                .frame(minHeight: 180)
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
        .confirmationDialog(
            "Overwrite preset?",
            isPresented: $showOverwriteConfirm,
            titleVisibility: .visible
        ) {
            Button("Overwrite", role: .destructive) {
                model.savePreset(named: pendingSaveName)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("“\(pendingSaveName)” already exists.")
        }
        .confirmationDialog(
            "Delete preset?",
            isPresented: Binding(
                get: { presetToDelete != nil },
                set: { if !$0 { presetToDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let name = presetToDelete {
                    model.deletePreset(name)
                }
                presetToDelete = nil
            }
            Button("Cancel", role: .cancel) {
                presetToDelete = nil
            }
        } message: {
            if let name = presetToDelete {
                Text("Delete “\(name)”? This cannot be undone.")
            }
        }
    }
}
