#if os(macOS)
import AppKit
import SwiftUI

@main
@MainActor
struct SSBNKClientApp: App {
    @StateObject private var model: AppModel

    init() {
        let model = AppModel()
        _model = StateObject(wrappedValue: model)
        NSApplication.shared.setActivationPolicy(.accessory)
        model.start()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environmentObject(model)
        } label: {
            Label("SSBNK Client", systemImage: model.displayState.systemImageName)
                .accessibilityLabel("SSBNK Client, \(model.displayState.rawValue)")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(model)
        }
    }
}
#else
@main
enum SSBNKClientApp {
    static func main() {}
}
#endif
