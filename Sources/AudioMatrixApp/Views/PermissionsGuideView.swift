import SwiftUI

struct PermissionsGuideView: View {
    @Bindable var model: AppViewModel
    @Environment(\.openURL) private var openURL
    @State private var dontShowAgain = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Audio Permissions Required", systemImage: "mic.fill")
                .font(.title3.weight(.semibold))

            Text("Open AudioMatrix needs permission to capture app audio and route it to your outputs.")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                Text("1. Open System Settings → Privacy & Security")
                Text("2. Enable System Audio Recording for Open AudioMatrix")
                Text("3. If you route from microphones or interfaces, also enable Microphone")
            }
            .font(.callout)

            Button("Open System Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_SystemAudioRecording") {
                    openURL(url)
                }
            }

            Toggle("Don't show this again", isOn: $dontShowAgain)

            HStack {
                Spacer()
                Button("Continue") {
                    model.dismissPermissionsGuide(permanently: dontShowAgain)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 440)
    }
}
