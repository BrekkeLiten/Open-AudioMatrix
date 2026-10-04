import AudioMatrixCore
import SwiftUI

struct ToolbarView: View {
    @Bindable var model: AppViewModel
    @State private var showMatrixConfiguration = false
    @State private var showPresets = false
    @State private var showTestTone = false

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(model.running ? Color.green : Color.secondary)
                .frame(width: 10, height: 10)
            Text(model.statusMessage)
                .font(.headline)

            Spacer()

            Button {
                showMatrixConfiguration = true
            } label: {
                Label("Configure Matrix", systemImage: "slider.horizontal.3")
            }

            Button {
                showPresets = true
            } label: {
                Label("Presets", systemImage: "list.bullet.rectangle")
            }

            Button {
                showTestTone = true
            } label: {
                Label("Test Tone", systemImage: "speaker.wave.2")
            }

            Button(model.running ? "Stop" : "Start") {
                model.running ? model.stop() : model.start()
            }
            .keyboardShortcut(model.running ? .cancelAction : .defaultAction)

            if let error = model.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .sheet(isPresented: $showMatrixConfiguration) {
            MatrixConfigurationView(model: model)
        }
        .sheet(isPresented: $showPresets) {
            PresetsView(model: model)
        }
        .sheet(isPresented: $showTestTone) {
            TestToneSheet(model: model)
        }
    }
}
