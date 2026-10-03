import VNCCore
import AppKit

/// The menu bar item. Built with plain AppKit (NSStatusItem + NSMenu, rebuilt each time it opens) rather than
/// SwiftUI's MenuBarExtra: with the app active, MenuBarExtra and the main menu kept invalidating each other,
/// which spun the main thread at 100% and hung the app.
final class MenuBarController: NSObject, NSMenuDelegate {
    static let shared = MenuBarController()
    private var item: NSStatusItem?

    /// Shows or hides the item to match the preference.
    func update() {
        if Preferences.shared.showMenuBarItem {
            guard item == nil else { return }
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            let image = NSImage(systemSymbolName: AppIdentity.isDev ? "hammer" : "display", accessibilityDescription: AppIdentity.name)
            image?.isTemplate = true
            item.button?.image = image
            item.button?.toolTip = AppIdentity.name
            let menu = NSMenu()
            menu.delegate = self
            item.menu = menu
            self.item = item
        } else if let item {
            NSStatusBar.system.removeStatusItem(item)
            self.item = nil
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let manager = SessionManager.shared

        let open = manager.openSessions
        if !open.isEmpty {
            menu.addItem(.sectionHeader(title: "Open"))
            for s in open {
                let mi = action(s.title) { manager.focus(s) }
                mi.image = NSImage(systemSymbolName: s.phase == .connected ? "display" : "exclamationmark.triangle",
                                   accessibilityDescription: nil)
                menu.addItem(mi)
            }
        }

        let store = ConnectionStore.shared
        let recent = Array(store.sorted.prefix(10))
        if !recent.isEmpty {
            menu.addItem(.sectionHeader(title: "Computers"))
            for c in recent { menu.addItem(action(c.title) { manager.open(c) }) }
        }

        let saved = Set(store.connections.compactMap(\.bonjourName))
        let nearby = BonjourBrowser.shared.services.filter { !saved.contains($0.name) }
        if !nearby.isEmpty {
            menu.addItem(.sectionHeader(title: "Nearby"))
            for s in nearby { menu.addItem(action(s.name) { manager.open(bonjour: s.name) }) }
        }

        menu.addItem(.separator())
        menu.addItem(action("Connect to Address…") {
            AppState.shared.showLauncher()
            AppState.shared.focusAddressRequests += 1
        })
        menu.addItem(action("Show Computers") { AppState.shared.showLauncher() })
        menu.addItem(action("Settings…") {
            NSApp.activate()
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        })
        menu.addItem(.separator())
        let quit = action("Quit \(AppIdentity.name)") { NSApp.terminate(nil) }
        quit.keyEquivalent = "q"
        menu.addItem(quit)
    }

    private func action(_ title: String, _ handler: @escaping () -> Void) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: #selector(ClosureTarget.invoke), keyEquivalent: "")
        let target = ClosureTarget(handler)
        mi.target = target
        mi.representedObject = target // keeps the target alive as long as the item
        return mi
    }
}

private final class ClosureTarget: NSObject {
    let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    @objc func invoke() { handler() }
}
