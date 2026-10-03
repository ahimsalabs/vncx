import VNCCore
import SwiftUI
import AppKit

/// Cross-window UI requests (menu commands that target the launcher).
@Observable
final class AppState {
    static let shared = AppState()
    var newConnectionRequests = 0
    var focusAddressRequests = 0
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Development runs stay in the background so they never take keyboard focus from the user.
        if Session.isEphemeral { NSApp.setActivationPolicy(.accessory) }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme?.lowercased() == "vnc" {
            _ = SessionManager.shared.open(address: url.absoluteString)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Command-line convenience: `vncx host[:port]` connects immediately.
        let args = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
        for a in args { _ = SessionManager.shared.open(address: a) }
        // Development: VNCX_OPEN_JSON=/path/connection.json opens a fully specified connection (not saved).
        if let path = ProcessInfo.processInfo.environment["VNCX_OPEN_JSON"],
           let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let config = try? JSONDecoder().decode(SavedConnection.self, from: data) {
            SessionManager.shared.open(config)
        }
        NSWindow.allowsAutomaticWindowTabbing = true
        BonjourBrowser.shared.start()
        DebugDump.installIfRequested()
    }

    func applicationWillTerminate(_ notification: Notification) {
        SessionManager.shared.disconnectAll()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
struct VNCXApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("vncx", id: "launcher") {
            LauncherView()
        }
        .defaultSize(width: 760, height: 540)
        .commands { AppCommands() }

        Settings { SettingsView() }

        MenuBarExtra("vncx", systemImage: "display", isInserted: Binding(
            get: { Preferences.shared.showMenuBarItem },
            set: { Preferences.shared.showMenuBarItem = $0 })) {
            MenuBarContent()
        }
    }
}

struct AppCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @State private var manager = SessionManager.shared

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Connection…") {
                openWindow(id: "launcher")
                AppState.shared.newConnectionRequests += 1
            }
            .keyboardShortcut("n")
            Button("Connect to Address…") {
                openWindow(id: "launcher")
                AppState.shared.focusAddressRequests += 1
            }
            .keyboardShortcut("k")
            Button("Show Computers") { openWindow(id: "launcher") }
                .keyboardShortcut("0")
        }

        CommandMenu("Session") {
            let s = manager.activeSession
            let connected = s?.phase == .connected
            Picker("Scaling", selection: Binding(get: { s?.scaling ?? .fit }, set: { s?.scaling = $0 })) {
                Text(ScalingMode.fit.label).tag(ScalingMode.fit).keyboardShortcut("1", modifiers: [.control, .command])
                Text(ScalingMode.actual.label).tag(ScalingMode.actual).keyboardShortcut("2", modifiers: [.control, .command])
                Text(ScalingMode.remoteResize.label).tag(ScalingMode.remoteResize).keyboardShortcut("3", modifiers: [.control, .command])
            }
            .pickerStyle(.inline)
            .disabled(s == nil)
            Button("Zoom In") { s?.zoomIn() }
                .keyboardShortcut("=", modifiers: [.control, .command])
                .disabled(s == nil)
            Button("Zoom Out") { s?.zoomOut() }
                .keyboardShortcut("-", modifiers: [.control, .command])
                .disabled((s?.zoom ?? 1) <= 1)
            Button("Reset Zoom") { s?.resetZoom() }
                .keyboardShortcut("0", modifiers: [.control, .command])
                .disabled((s?.zoom ?? 1) <= 1)
            Divider()
            Picker("Local Cursor", selection: Binding(get: { s?.localCursor ?? .arrow }, set: { s?.localCursor = $0 })) {
                ForEach(LocalCursorMode.allCases) { Text($0.label).tag($0) }
            }
            .disabled(s == nil)
            Toggle("View Only", isOn: Binding(get: { s?.viewOnly ?? false }, set: { s?.viewOnly = $0 }))
                .keyboardShortcut("o", modifiers: [.control, .command])
                .disabled(s == nil)
            Divider()
            Button("Send Control–Alt–Delete") { s?.sendCtrlAltDel() }
                .keyboardShortcut(.delete, modifiers: [.control, .command])
                .disabled(!connected)
            Button("Type Clipboard Text") { s?.typeClipboard() }
                .keyboardShortcut("v", modifiers: [.control, .command])
                .disabled(!connected)
            Button("Send Clipboard to Remote") { s?.syncClipboardToRemote(force: true) }
                .disabled(!connected)
            Divider()
            if let s, s.displays.count > 1 {
                Menu("Displays") { DisplayMenu(session: s) }
            }
            Toggle("Show Connection Stats", isOn: Binding(get: { s?.showStats ?? false }, set: { s?.showStats = $0 }))
                .keyboardShortcut("i", modifiers: [.control, .command])
                .disabled(s == nil)
            Button("Save Screenshot to Desktop") { s?.saveScreenshot() }
                .keyboardShortcut("s", modifiers: [.control, .command])
                .disabled(!connected)
            Button("Refresh Screen") { s?.refresh() }
                .keyboardShortcut("r", modifiers: [.control, .command])
                .disabled(!connected)
            Divider()
            Button(connected ? "Disconnect" : "Reconnect") {
                guard let s else { return }
                if connected { s.disconnect() } else { s.reconnect() }
            }
            .keyboardShortcut("d", modifiers: [.control, .command])
            .disabled(s == nil)
        }
    }
}

struct MenuBarContent: View {
    @Environment(\.openWindow) private var openWindow
    @State private var manager = SessionManager.shared
    @State private var store = ConnectionStore.shared
    @State private var bonjour = BonjourBrowser.shared

    var body: some View {
        let open = manager.openSessions
        if !open.isEmpty {
            Section("Open") {
                ForEach(open) { s in
                    Button {
                        manager.focus(s)
                    } label: {
                        Label(s.title, systemImage: s.phase == .connected ? "display" : "exclamationmark.triangle")
                    }
                }
            }
        }
        let recent = Array(store.sorted.prefix(10))
        if !recent.isEmpty {
            Section("Computers") {
                ForEach(recent) { c in
                    Button(c.title) { SessionManager.shared.open(c) }
                }
            }
        }
        let saved = Set(store.connections.compactMap(\.bonjourName))
        let nearby = bonjour.services.filter { !saved.contains($0.name) }
        if !nearby.isEmpty {
            Section("Nearby") {
                ForEach(nearby) { s in
                    Button(s.name) { SessionManager.shared.open(bonjour: s.name) }
                }
            }
        }
        Divider()
        Button("Connect to Address…") {
            openWindow(id: "launcher")
            NSApp.activate()
            AppState.shared.focusAddressRequests += 1
        }
        Button("Show Computers") {
            openWindow(id: "launcher")
            NSApp.activate()
        }
        SettingsLink { Text("Settings…") }
        Divider()
        Button("Quit vncx") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
