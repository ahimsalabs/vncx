// Copyright 2026 Ahimsa Labs
// SPDX-License-Identifier: Apache-2.0

import VNCCore
import SwiftUI
import AppKit

struct RemoteViewRepresentable: NSViewRepresentable {
    let session: Session
    var displayID: UInt32?

    /// The crop for this view: its own display for a per-display window, the selected display for the main one.
    private var crop: CGRect? { session.cropRect(for: displayID ?? session.selectedDisplay) }

    func makeNSView(context: Context) -> RemoteView {
        let view = RemoteView(session: session)
        view.crop = crop
        session.register(view, display: displayID)
        view.scaling = session.scaling
        view.viewOnly = session.viewOnly
        view.smoothScaling = Preferences.shared.smoothScaling
        view.fallbackCursor = session.localCursor
        if displayID == nil { view.onZoomChange = { [weak session] z in session?.zoom = z } }
        return view
    }

    func updateNSView(_ view: RemoteView, context: Context) {
        view.crop = crop
        view.scaling = session.scaling
        view.fallbackCursor = session.localCursor
        view.viewOnly = session.viewOnly
        view.smoothScaling = Preferences.shared.smoothScaling
    }
}

/// Per-window chrome state the window controller shares with its SwiftUI content.
@Observable
final class SessionChrome {
    /// Full screen with the toolbar replaced by the floating bar.
    var island = false
    @ObservationIgnored var exitFullScreen: () -> Void = {}
}

struct SessionView: View {
    @Bindable var session: Session
    var displayID: UInt32?
    var chrome: SessionChrome

    private var windowTitle: String {
        guard let d = session.display(displayID) else { return session.title }
        return "\(session.title) — Display \(d.number)"
    }

    var body: some View {
        ZStack {
            RemoteViewRepresentable(session: session, displayID: displayID)
                .opacity(session.phase == .connected ? 1 : 0.35)
            overlay
            if let banner = session.banner {
                HStack(spacing: 8) {
                    if banner.busy { ProgressView().controlSize(.small) }
                    else { Image(systemName: banner.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(banner.isError ? Color.orange : Color.green) }
                    Text(banner.text).lineLimit(3)
                }
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(.regularMaterial, in: Capsule())
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 18)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .allowsHitTesting(false)
            }
            if session.showStats && session.phase == .connected {
                StatsOverlay(stats: session.liveStats, size: session.framebufferSize, auto: session.config.quality == .auto)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(12)
                    .allowsHitTesting(false)
            }
            if let waiting = session.waiting {
                WaitingIndicator(waiting: waiting, host: session.config.title)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .padding(12)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
            if chrome.island {
                FloatingBar(session: session, displayID: displayID, chrome: chrome)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: session.waiting)
        .coordinateSpace(.named(FloatingBar.space))
        .background(Color.black)
        .ignoresSafeArea(.container, edges: .bottom)
        .navigationTitle(windowTitle)
        .navigationSubtitle(session.subtitle)
        .toolbar { toolbar }
        .sheet(item: $session.credentialPrompt) { prompt in
            CredentialsSheet(prompt: prompt) { session.submitCredentials($0) }
        }
    }

    @ViewBuilder private var overlay: some View {
        switch session.phase {
        case .connecting:
            if session.credentialPrompt == nil {
                VStack(spacing: 14) {
                    ProgressView().controlSize(.large)
                    Text("Connecting to \(session.config.title)…").font(.title3)
                    if let detail = session.statusDetail {
                        Text(detail).foregroundStyle(.secondary)
                    }
                    Button("Cancel") { session.window?.close() }
                        .keyboardShortcut(.cancelAction)
                }
                .padding(28)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        case .connected:
            EmptyView()
        case .reconnecting(let attempt, let reason):
            VStack(spacing: 12) {
                ProgressView().controlSize(.large)
                Text("Reconnecting to \(session.config.title)…").font(.title3)
                if let reason {
                    Text(reason).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
                }
                if attempt > 1 { Text("Attempt \(attempt)").font(.caption).foregroundStyle(.secondary) }
                HStack {
                    Button("Stop") { session.disconnect() }.keyboardShortcut(.cancelAction)
                    Button("Retry Now") { session.reconnect() }.keyboardShortcut(.defaultAction)
                }
                .controlSize(.large)
            }
            .padding(28)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        case .disconnected(let message):
            VStack(spacing: 12) {
                Image(systemName: message == nil ? "display" : "exclamationmark.triangle")
                    .font(.system(size: 40))
                    .foregroundStyle(message == nil ? Color.secondary : Color.orange)
                Text(message == nil ? "Disconnected" : "Couldn’t connect to \(session.config.title)")
                    .font(.title3.weight(.semibold))
                if let message {
                    Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
                }
                HStack {
                    Button("Close") { session.window?.close() }
                        .keyboardShortcut(.cancelAction)
                    Button("Reconnect") { session.reconnect() }
                        .keyboardShortcut(.defaultAction)
                }
                .controlSize(.large)
                .padding(.top, 4)
            }
            .padding(28)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        let controls = SessionControls(session: session, displayID: displayID)
        if controls.showsDisplays {
            ToolbarItem(placement: .primaryAction) { controls.displays }
        }
        ToolbarItem(placement: .primaryAction) { controls.scaling }
        ToolbarItem(placement: .primaryAction) { controls.viewOnly }
        ToolbarItem(placement: .primaryAction) { controls.sendKeys }
        ToolbarItem(placement: .primaryAction) { controls.stats }
        ToolbarItem(placement: .primaryAction) { controls.screenshot }
    }
}

/// The session's toolbar controls, shared by the window toolbar and the full screen floating bar.
struct SessionControls {
    @Bindable var session: Session
    var displayID: UInt32?

    var showsDisplays: Bool { displayID == nil && session.displays.count > 1 }

    var displays: some View {
        Menu {
            DisplayMenu(session: session)
        } label: {
            Label("Displays", systemImage: "rectangle.on.rectangle")
        }
        .help("Choose which remote display to show")
    }

    var scaling: some View {
        Picker("Scaling", selection: $session.scaling) {
            ForEach(ScalingMode.allCases) { mode in
                Label(mode.label, systemImage: mode.symbol).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .help("Scale to fit, fill the window's width or height, show actual pixels, or resize the remote desktop to match the window")
    }

    var viewOnly: some View {
        Toggle(isOn: $session.viewOnly) {
            Label("View Only", systemImage: session.viewOnly ? "eye" : "computermouse")
        }
        .help(session.viewOnly ? "View only: input is not sent" : "Controlling: click to switch to view only")
    }

    var sendKeys: some View {
        Menu {
            SendKeysMenu(session: session)
        } label: {
            Label("Send Keys", systemImage: "keyboard")
        }
        .help("Send special keys and clipboard text")
        .disabled(session.phase != .connected)
    }

    var stats: some View {
        Toggle(isOn: $session.showStats) {
            Label("Connection Stats", systemImage: "gauge.with.dots.needle.33percent")
        }
        .help("Show frame rate, bandwidth, latency and encoding (⌃⌘I)")
    }

    var screenshot: some View {
        Menu {
            Button("Save Screenshot to Desktop") { session.saveScreenshot() }
            Button("Copy Screenshot") { session.copyScreenshot() }
        } label: {
            Label("Screenshot", systemImage: "camera")
        }
        .disabled(session.phase != .connected)
    }
}

/// Stands in for the toolbar in full screen: a small tab at the top center that opens into the session controls
/// while the pointer is over it, so the remote desktop keeps the whole screen.
struct FloatingBar: View {
    static let space = "session"
    let session: Session
    var displayID: UInt32?
    let chrome: SessionChrome
    @State private var expanded = false
    @State private var collapse: DispatchWorkItem?

    var body: some View {
        let controls = SessionControls(session: session, displayID: displayID)
        VStack(spacing: 0) {
            if expanded {
                HStack(spacing: 10) {
                    if controls.showsDisplays { controls.displays }
                    controls.scaling.fixedSize()
                    controls.viewOnly
                    controls.sendKeys
                    controls.stats
                    controls.screenshot
                    Divider().frame(height: 18)
                    Button(action: chrome.exitFullScreen) {
                        Label("Exit Full Screen", systemImage: "arrow.down.right.and.arrow.up.left.rectangle")
                    }
                    .help("Exit full screen (⌃⌘F)")
                }
                .labelStyle(.iconOnly)
                .toggleStyle(.button)
                .menuIndicator(.hidden)
                .buttonStyle(.borderless)
                .controlSize(.large)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.35), radius: 10, y: 3)
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
            } else {
                // A wide, short hot zone around a small visible tab.
                Capsule()
                    .fill(.white.opacity(0.55))
                    .stroke(.black.opacity(0.35), lineWidth: 0.5)
                    .frame(width: 48, height: 5)
                    .padding(.top, 3)
                    .frame(width: 160, height: 10, alignment: .top)
                    .contentShape(Rectangle())
                    .onTapGesture { setExpanded(true) }
            }
        }
        .onHover { inside in
            collapse?.cancel()
            if inside { setExpanded(true) } else { scheduleCollapse() }
        }
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named(Self.space)) }) { rect in
            session.remoteView(for: displayID)?.overlayRect = rect
        }
        .onDisappear { session.remoteView(for: displayID)?.overlayRect = nil }
    }

    /// Collapses shortly after the pointer leaves, but not while one of the bar's menus is open or the pointer is
    /// back over the bar (hover events don't arrive while a menu tracks).
    private func scheduleCollapse() {
        let work = DispatchWorkItem {
            guard let view = session.remoteView(for: displayID), let window = view.window else { return setExpanded(false) }
            let p = view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
            if RunLoop.current.currentMode == .eventTracking || view.overlayRect?.contains(p) == true {
                scheduleCollapse()
            } else {
                setExpanded(false)
            }
        }
        collapse = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
    }

    private func setExpanded(_ value: Bool) {
        withAnimation(.snappy(duration: 0.2)) { expanded = value }
    }
}

struct SendKeysMenu: View {
    let session: Session
    var body: some View {
        Button("Control–Alt–Delete") { session.sendCtrlAltDel() }
        Button("Control–Alt–Backspace") { session.sendKeys([0xffe3, 0xffe9, 0xff08]) }
        Divider()
        Button("Command–Tab") { session.sendKeys([Preferences.shared.commandKey.left, 0xff09]) }
        Button("Command–Space") { session.sendKeys([Preferences.shared.commandKey.left, 0x20]) }
        Button("Command–Q") { session.sendKeys([Preferences.shared.commandKey.left, 0x71]) }
        Divider()
        Button("Escape") { session.sendKeys([0xff1b]) }
        Button("Print Screen") { session.sendKeys([0xff61]) }
        Divider()
        Button("Type Clipboard Text") { session.typeClipboard() }
        Button("Send Clipboard to Remote") { session.syncClipboardToRemote(force: true) }
    }
}

extension Session {
    var window: NSWindow? { windowController?.window }
}

struct CredentialsSheet: View {
    let prompt: Session.CredentialPrompt
    let onDone: (Credentials?) -> Void
    @State private var username: String
    @State private var password = ""
    @State private var remember = true
    @FocusState private var focus: Field?
    enum Field { case user, password }

    init(prompt: Session.CredentialPrompt, onDone: @escaping (Credentials?) -> Void) {
        self.prompt = prompt
        self.onDone = onDone
        _username = State(initialValue: prompt.username)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: prompt.request.needsUsername ? "person.badge.key" : "key")
                    .font(.system(size: 32)).foregroundStyle(.tint).frame(width: 40)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Log in to \(prompt.hostLabel)").font(.headline)
                    Text(prompt.request.needsUsername
                         ? "Enter the name and password of a user account on the remote Mac."
                         : "This server uses a VNC password.")
                        .font(.callout).foregroundStyle(.secondary)
                    if prompt.previousFailed {
                        Text("The previous attempt failed. Check the name and password.")
                            .font(.callout).foregroundStyle(.red)
                    }
                }
            }
            Form {
                if prompt.request.needsUsername {
                    TextField("Name", text: $username).focused($focus, equals: .user)
                        .textContentType(.username)
                }
                SecureField("Password", text: $password).focused($focus, equals: .password)
                    .textContentType(.password)
                Toggle("Remember this password in my keychain", isOn: $remember)
            }
            .formStyle(.columns)
            HStack {
                Spacer()
                Button("Cancel") { onDone(nil) }.keyboardShortcut(.cancelAction)
                Button("Connect") {
                    onDone(Credentials(username: username, password: password, remember: remember))
                }
                .keyboardShortcut(.defaultAction)
                .disabled(password.isEmpty || (prompt.request.needsUsername && username.isEmpty))
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear { focus = prompt.request.needsUsername && username.isEmpty ? .user : .password }
    }
}

/// A small "still working" pill for waits vncx knows about (see `Session.Waiting`).
struct WaitingIndicator: View {
    let waiting: Session.Waiting
    let host: String

    private var text: String {
        switch waiting {
        case .server: return "Waiting for \(host)…"
        case .receiving(let bytes):
            return "Receiving… " + ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .binary)
        case .limited(let bps): return String(format: "Bandwidth limit · %.0f Mbit/s", bps / 1e6)
        }
    }

    var body: some View {
        HStack(spacing: 7) {
            ProgressView().controlSize(.mini)
            Text(text).monospacedDigit()
        }
        .font(.caption)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .environment(\.colorScheme, .dark)
    }
}

struct StatsOverlay: View {
    let stats: Session.LiveStats
    let size: CGSize
    let auto: Bool

    private func rate(_ bps: Double) -> String {
        bps >= 1_000_000 ? String(format: "%.1f Mbit/s", bps / 1_000_000) : String(format: "%.0f kbit/s", bps / 1000)
    }

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
            row("Screen", "\(Int(size.width))×\(Int(size.height))")
            row("Frames", "\(stats.fps)/s" + (stats.continuous ? " · pushed" : stats.limit != nil ? " · paced" : " · polled"))
            row("Received", rate(stats.bitsPerSecond))
            row("Limit", stats.limit.map(rate) ?? "none")
            row("Link", stats.linkBitsPerSecond.map(rate) ?? "measuring…")
            row("Latency", stats.rttMs.map { String(format: "%.1f ms", $0) } ?? "n/a")
            row("Encoding", stats.encodings.isEmpty ? "–" : stats.encodings.map { "\($0.name) \(Int(($0.share * 100).rounded()))%" }.joined(separator: ", "))
            row("Quality", (auto ? "Auto · " : "") + stats.level.label + (stats.inMotion ? " · moving: JPEG 4" : ""))
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .environment(\.colorScheme, .dark)
    }

    private func row(_ k: String, _ v: String) -> some View {
        GridRow {
            Text(k).foregroundStyle(.secondary)
            Text(v)
        }
    }
}

struct DisplayMenu: View {
    let session: Session
    var body: some View {
        Picker("Show", selection: Binding(get: { session.selectedDisplay }, set: { session.selectedDisplay = $0 })) {
            Text("All Displays").tag(UInt32?.none)
            ForEach(session.displays) { d in Text(d.label).tag(Optional(d.id)) }
        }
        .pickerStyle(.inline)
        Divider()
        Button("Open Each Display in Its Own Window") { session.openAllDisplays(fullScreen: false) }
        Button("Full Screen on All My Displays") { session.openAllDisplays(fullScreen: true) }
            .disabled(NSScreen.screens.count < 2)
        Button("Show All Displays in One Window") { session.showAllDisplaysInOneWindow() }
    }
}
