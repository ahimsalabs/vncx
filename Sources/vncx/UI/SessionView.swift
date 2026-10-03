import VNCCore
import SwiftUI
import AppKit

struct RemoteViewRepresentable: NSViewRepresentable {
    let session: Session

    func makeNSView(context: Context) -> RemoteView {
        let view = RemoteView(session: session)
        session.view = view
        view.scaling = session.scaling
        view.viewOnly = session.viewOnly
        view.smoothScaling = Preferences.shared.smoothScaling
        view.fallbackCursor = session.localCursor
        view.framebuffer = session.framebuffer
        return view
    }

    func updateNSView(_ view: RemoteView, context: Context) {
        view.scaling = session.scaling
        view.fallbackCursor = session.localCursor
        view.viewOnly = session.viewOnly
        view.smoothScaling = Preferences.shared.smoothScaling
    }
}

struct SessionView: View {
    @Bindable var session: Session

    var body: some View {
        ZStack {
            RemoteViewRepresentable(session: session)
                .opacity(session.phase == .connected ? 1 : 0.35)
            overlay
        }
        .background(Color.black)
        .ignoresSafeArea(.container, edges: .bottom)
        .navigationTitle(session.title)
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
        ToolbarItem(placement: .primaryAction) {
            Picker("Scaling", selection: $session.scaling) {
                ForEach(ScalingMode.allCases) { mode in
                    Label(mode.label, systemImage: mode.symbol).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .help("Scale to fit the window, show actual pixels, or resize the remote desktop to match the window")
        }
        ToolbarItem(placement: .primaryAction) {
            Toggle(isOn: $session.viewOnly) {
                Label("View Only", systemImage: session.viewOnly ? "eye" : "computermouse")
            }
            .help(session.viewOnly ? "View only: input is not sent" : "Controlling: click to switch to view only")
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                SendKeysMenu(session: session)
            } label: {
                Label("Send Keys", systemImage: "keyboard")
            }
            .help("Send special keys and clipboard text")
            .disabled(session.phase != .connected)
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button("Save Screenshot to Desktop") { session.saveScreenshot() }
                Button("Copy Screenshot") { session.copyScreenshot() }
            } label: {
                Label("Screenshot", systemImage: "camera")
            }
            .disabled(session.phase != .connected)
        }
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
