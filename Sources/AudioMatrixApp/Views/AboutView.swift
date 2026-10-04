import SwiftUI

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    private var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "Open AudioMatrix"
    }

    private var versionString: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(short) (\(build))"
    }

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 52, weight: .medium))
                .foregroundStyle(Color(red: 0, green: 0.78, blue: 0.38))
                .symbolRenderingMode(.hierarchical)

            VStack(spacing: 6) {
                Text(appName)
                    .font(.title2.weight(.semibold))
                Text("Version \(versionString)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Text("Route application and input audio to any channel on your audio outputs.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)

            Text("© Open AudioMatrix contributors")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Button("OK") { dismiss() }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
        }
        .padding(32)
        .frame(width: 380)
    }
}
