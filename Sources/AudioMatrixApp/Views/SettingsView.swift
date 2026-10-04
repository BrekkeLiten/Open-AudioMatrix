import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppViewModel

    var body: some View {
        Form {
            Toggle("Start routing when app opens", isOn: $model.autoStartRouting)
                .onChange(of: model.autoStartRouting) {
                    model.persistAppPreferences()
                }

            Toggle("Show VU meters", isOn: $model.showVUMeters)
                .onChange(of: model.showVUMeters) {
                    model.vuMetersPreferenceChanged()
                }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .padding()
    }
}
