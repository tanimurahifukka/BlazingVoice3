import SwiftUI

@main
struct BlazingVoice3App: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        // CLI/self-test modes: bypass GUI
        if CLITest.shouldRun() {
            Task { @MainActor in
                await CLITest.run()
            }
        }
    }

    var body: some Scene {
        Settings {
            SettingsView()
                .environmentObject(appDelegate.settings)
                .environmentObject(appDelegate.modelManager)
                .environmentObject(appDelegate.dictionary)
                .environmentObject(appDelegate.evolutionLog)
                .environmentObject(appDelegate)
        }
        Window("セットアップ", id: "setup-wizard") {
            SetupWizardView()
                .environmentObject(appDelegate.settings)
                .environmentObject(appDelegate.modelManager)
                .frame(width: 560, height: 520)
        }
        .windowResizability(.contentSize)
    }
}
