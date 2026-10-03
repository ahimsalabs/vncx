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
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme?.lowercased() == "vnc" {
            _ = SessionManager.shared.open(address: url.absoluteString)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Command-line convenience: `vncx host[:port]` connects immediately.
        let args = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
        for a in args { _ = SessionManager.shared.open(address: a) }
        NSWindow.allowsAutomaticWindowTabbing = true
        DebugDump.installIfRequested()
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
