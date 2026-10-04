import AppKit
import AudioMatrixCore
import SwiftUI

@main
struct AudioMatrixApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppViewModel()
    @State private var showAbout = false

    var body: some Scene {
        WindowGroup {
            MatrixEditorView(model: model)
                .frame(minWidth: 960, minHeight: 640)
                .onAppear {
                    model.onAppear()
                    NSApp.activate(ignoringOtherApps: true)
                }
                .onDisappear { model.onDisappear() }
                .sheet(isPresented: $showAbout) {
                    AboutView()
                }
        }
        .defaultSize(width: 960, height: 640)
        .commands {
            CommandGroup(replacing: .newItem) {}

            CommandGroup(replacing: .appInfo) {
                Button("About Open AudioMatrix") {
                    showAbout = true
                }
            }
        }

        Settings {
            SettingsView(model: model)
        }
    }
}
