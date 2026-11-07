import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

struct MenuBarLabel: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Image(systemName: "brain.head.profile")
            .task {
                if ProcessInfo.processInfo.environment["PRIVATE_SECRETARY_SHOW_WINDOW"] == "1" {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
            .accessibilityLabel("Private Secretary")
    }
}

@main
struct PrivateSecretaryApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            MenuBarLabel()
        }

        Window("Private Secretary", id: "main") {
            RootView(model: model)
        }
        .defaultSize(width: 1_080, height: 720)
        .windowResizability(.contentMinSize)
    }
}
