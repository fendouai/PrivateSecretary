import SwiftUI
import AppKit

@main
struct PrivateSecretaryApplication {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel()
    private var statusItem: NSStatusItem?
    private var windowController: NSWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installStatusItem()
        let shouldOpen = ProcessInfo.processInfo.environment["PRIVATE_SECRETARY_SHOW_WINDOW"] == "1"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self else { return }
            if shouldOpen || self.statusItemIsOccluded() {
                // On notched Macs, macOS may place a new status item underneath
                // the notch. Keep the app reachable by showing a Dock icon and
                // opening the main window in that case.
                if self.statusItemIsOccluded() {
                    NSApp.setActivationPolicy(.regular)
                }
                self.openMainWindow()
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.length = 30
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "brain.head.profile", accessibilityDescription: "Private Secretary")
            button.image?.isTemplate = true
            button.imagePosition = .imageOnly
            button.toolTip = "Private Secretary"
            button.title = "PS"
            button.imagePosition = .imageLeading
        }
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Open Private Secretary", action: #selector(openMainWindowAction), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Open Dashboard", action: #selector(openDashboardAction), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Open Data Folder", action: #selector(openDataFolderAction), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Restart Capture Service", action: #selector(restartServiceAction), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Private Secretary", action: #selector(quitAction), keyEquivalent: "q"))
        for menuItem in menu.items where menuItem.action != nil {
            menuItem.target = self
        }
        item.menu = menu
        statusItem = item
    }

    private func statusItemIsOccluded() -> Bool {
        guard let screen = NSScreen.main,
              let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea,
              let frame = statusItem?.button?.window?.frame else { return false }
        let notch = NSRect(
            x: left.maxX,
            y: screen.frame.minY,
            width: max(0, right.minX - left.maxX),
            height: screen.frame.height
        )
        return notch.width > 0 && frame.intersects(notch)
    }

    @objc private func openMainWindowAction() {
        openMainWindow()
    }

    private func openMainWindow() {
        if windowController == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1_080, height: 720),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Private Secretary"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: RootView(model: model))
            window.center()
            window.setFrameAutosaveName("PrivateSecretaryMainWindow")
            windowController = NSWindowController(window: window)
        }
        windowController?.showWindow(nil)
        windowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openDashboardAction() {
        model.openDashboard()
    }

    @objc private func openDataFolderAction() {
        model.openDataFolder()
    }

    @objc private func restartServiceAction() {
        model.restartService()
    }

    @objc private func quitAction() {
        NSApp.terminate(nil)
    }
}
