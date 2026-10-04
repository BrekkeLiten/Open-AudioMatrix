import SwiftUI

struct ChannelLabelSheet: View {
    let deviceUID: String
    let monoChannel: Int
    let initialLabel: String
    let onSave: (String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var labelText: String

    init(
        deviceUID: String,
        monoChannel: Int,
        initialLabel: String,
        onSave: @escaping (String?) -> Void
    ) {
        self.deviceUID = deviceUID
        self.monoChannel = monoChannel
        self.initialLabel = initialLabel
        self.onSave = onSave
        _labelText = State(initialValue: initialLabel)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename Channel")
                .font(.title3.weight(.semibold))

            Text("Output channel \(String(format: "%02d", monoChannel))")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("Label", text: $labelText)
                .textFieldStyle(.roundedBorder)

            HStack {
                Button("Clear") {
                    onSave(nil)
                    dismiss()
                }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    let trimmed = labelText.trimmingCharacters(in: .whitespacesAndNewlines)
                    onSave(trimmed.isEmpty ? nil : trimmed)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 340)
    }
}
