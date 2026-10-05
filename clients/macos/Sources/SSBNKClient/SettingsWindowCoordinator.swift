#if os(macOS)
import AppKit
import SwiftUI

@MainActor
final class SettingsWindowCoordinator {
    private var controller: NSWindowController?
    func show(model: AppModel) {
        if let controller { controller.showWindow(nil); NSApp.activate(ignoringOtherApps: true); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 540), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "SSBNK Client — Options"
        window.contentView = NSHostingView(rootView: SettingsView().environmentObject(model))
        window.center()
        controller = NSWindowController(window: window)
        controller?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
#endif
