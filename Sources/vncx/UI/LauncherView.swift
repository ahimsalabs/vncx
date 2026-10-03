import VNCCore
import SwiftUI

struct LauncherView: View {
    @State private var store = ConnectionStore.shared
    @State private var bonjour = BonjourBrowser.shared
    @State private var app = AppState.shared
    @State private var address = ""
    @State private var search = ""
    @State private var addressError = false
    @State private var editing: SavedConnection?
    @State private var pendingDelete: SavedConnection?
    @FocusState private var addressFocused: Bool

    private let columns = [GridItem(.adaptive(minimum: 220, maximum: 320), spacing: 18)]

    private var filtered: [SavedConnection] {
        let all = store.sorted
        guard !search.isEmpty else { return all }
        return all.filter { $0.title.localizedCaseInsensitiveContains(search) || $0.subtitle.localizedCaseInsensitiveContains(search) }
    }

    private var nearby: [BonjourBrowser.Service] {
        let saved = Set(store.connections.compactMap(\.bonjourName))
        return bonjour.services.filter { !saved.contains($0.name) && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                connectBar
                if !filtered.isEmpty {
                    section("Recent") {
                        ForEach(filtered) { c in
                            ConnectionCard(connection: c, thumbnail: store.thumbnail(c.id))
                                .onTapGesture(count: 2) { SessionManager.shared.open(c) }
                                .contextMenu {
                                    Button("Connect") { SessionManager.shared.open(c) }
                                    Button("Edit…") { editing = c }
                                    Button("Duplicate") {
                                        var copy = c; copy.id = UUID(); copy.name = c.title + " copy"; copy.lastConnected = nil
                                        store.upsert(copy)
                                    }
                                    Divider()
                                    Button("Delete", role: .destructive) { pendingDelete = c }
                                }
                        }
                    }
                }
                if !nearby.isEmpty {
                    section("Nearby") {
                        ForEach(nearby) { s in
                            NearbyCard(name: s.name)
                                .onTapGesture(count: 2) { SessionManager.shared.open(bonjour: s.name) }
                                .contextMenu { Button("Connect") { SessionManager.shared.open(bonjour: s.name) } }
                        }
                    }
                }
                if filtered.isEmpty && nearby.isEmpty {
                    ContentUnavailableView {
                        Label(search.isEmpty ? "No Computers Yet" : "No Matches", systemImage: "display.2")
                    } description: {
                        Text(search.isEmpty ? "Type a host name or IP address above to connect. Computers you connect to appear here." : "")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
                }
            }
            .padding(24)
        }
        .frame(minWidth: 560, minHeight: 420)
        .navigationTitle("vncx")
        .searchable(text: $search, placement: .toolbar, prompt: "Search")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { editing = SavedConnection() } label: { Label("New Connection", systemImage: "plus") }
                    .help("Add a computer")
            }
        }
        .sheet(item: $editing) { c in
            ConnectionEditor(connection: c) { saved in
                if let saved { store.upsert(saved) }
                editing = nil
            }
        }
        .confirmationDialog("Delete \(pendingDelete?.title ?? "")?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
            Button("Delete", role: .destructive) {
                if let c = pendingDelete {
                    Keychain.deletePassword(for: c.keychainAccount)
                    store.delete(c)
                }
                pendingDelete = nil
            }
        } message: {
            Text("The saved password will also be removed from your keychain.")
        }
        .onAppear {
            bonjour.start()
            addressFocused = true
        }
        .onChange(of: app.newConnectionRequests) { editing = SavedConnection() }
        .onChange(of: app.focusAddressRequests) { addressFocused = true }
    }

    private var connectBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "network").foregroundStyle(.secondary)
            TextField("Host name, IP address, or vnc:// URL", text: $address)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($addressFocused)
                .onSubmit(connect)
                .onChange(of: address) { addressError = false }
            Button("Connect", action: connect)
                .buttonStyle(.borderedProminent)
                .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(addressError ? Color.red : .clear))
    }

    private func connect() {
        if SessionManager.shared.open(address: address) { address = "" } else { addressError = true }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline).foregroundStyle(.secondary)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 18, content: content)
        }
    }
}

struct ConnectionCard: View {
    let connection: SavedConnection
    let thumbnail: NSImage?
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // The 16:10 frame comes from a plain shape so the thumbnail's own aspect ratio can never resize the card.
            Rectangle().fill(.black).aspectRatio(16 / 10, contentMode: .fit).overlay {
            ZStack {
                if let thumbnail {
                    // Whole remote screen, fitted; a blurred copy fills the spare space instead of hard bars.
                    Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fill)
                        .blur(radius: 18).opacity(0.55)
                    Image(nsImage: thumbnail).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                } else {
                    LinearGradient(colors: [.accentColor.opacity(0.55), .accentColor.opacity(0.2)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: connection.bonjourName != nil ? "desktopcomputer" : "display")
                        .font(.system(size: 40, weight: .light)).foregroundStyle(.white.opacity(0.9))
                }
                if hovering {
                    Color.black.opacity(0.25)
                    Button { SessionManager.shared.open(connection) } label: {
                        Image(systemName: "play.fill").font(.title2).padding(14)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .background(.ultraThinMaterial, in: Circle())
                    .help("Connect")
                }
            }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
            .shadow(color: .black.opacity(hovering ? 0.25 : 0.1), radius: hovering ? 8 : 3, y: 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(connection.title).font(.body.weight(.medium)).lineLimit(1)
                HStack(spacing: 4) {
                    Text(connection.subtitle).lineLimit(1)
                    if let last = connection.lastConnected {
                        Text("·")
                        Text(last, format: .relative(presentation: .named))
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
    }
}

struct NearbyCard: View {
    let name: String
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "desktopcomputer").font(.title2).foregroundStyle(.tint).frame(width: 36)
            VStack(alignment: .leading) {
                Text(name).font(.body.weight(.medium)).lineLimit(1)
                Text("Screen Sharing · Bonjour").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Connect") { SessionManager.shared.open(bonjour: name) }.controlSize(.small)
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct ConnectionEditor: View {
    @State var connection: SavedConnection
    let onDone: (SavedConnection?) -> Void
    @State private var address = ""
    @State private var password = ""
    @State private var hadPassword = false

    init(connection: SavedConnection, onDone: @escaping (SavedConnection?) -> Void) {
        _connection = State(initialValue: connection)
        self.onDone = onDone
        let addr = connection.host.isEmpty ? "" : Address(host: connection.host, port: connection.port).display
        _address = State(initialValue: connection.bonjourName ?? addr)
    }

    private var parsed: Address? { connection.bonjourName != nil ? Address(host: "", port: 5900) : Address.parse(address) }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $connection.name, prompt: Text(parsed?.display ?? "Optional"))
                    TextField("Address", text: $address, prompt: Text("host, host:port, or vnc://host"))
                        .disabled(connection.bonjourName != nil)
                    TextField("User name", text: $connection.username, prompt: Text("For macOS Screen Sharing"))
                    SecureField("Password", text: $password, prompt: Text(hadPassword ? "Saved in keychain" : "Ask when connecting"))
                }
                Section("Display") {
                    Picker("Scaling", selection: $connection.scaling) {
                        ForEach(ScalingMode.allCases) { Text($0.label).tag($0) }
                    }
                    Toggle("Use Retina resolution when resizing remote", isOn: $connection.remoteResizeRetina)
                        .disabled(connection.scaling != .remoteResize)
                    Picker("Picture quality", selection: $connection.quality) {
                        ForEach(Quality.allCases) { Text($0.label).tag($0) }
                    }
                    Toggle("View only", isOn: $connection.viewOnly)
                    Picker("Local cursor", selection: $connection.localCursor) {
                        ForEach(LocalCursorMode.allCases) { Text($0.label).tag($0) }
                    }
                    .help("Used when the server doesn’t send cursor shapes. Choose Hidden or Dot if the server draws its cursor into the picture.")
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { onDone(nil) }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }.keyboardShortcut(.defaultAction).disabled(parsed == nil)
            }
            .padding()
        }
        .frame(width: 460)
        .onAppear { hadPassword = Keychain.password(for: connection.keychainAccount) != nil }
    }

    private func save() {
        guard let a = parsed else { return }
        let oldAccount = connection.keychainAccount
        if connection.bonjourName == nil {
            connection.host = a.host
            connection.port = a.port
            if !a.username.isEmpty { connection.username = a.username }
        }
        let newAccount = connection.keychainAccount
        if !password.isEmpty {
            Keychain.setPassword(password, for: newAccount, label: "vncx: \(connection.title)")
        } else if oldAccount != newAccount, let old = Keychain.password(for: oldAccount) {
            Keychain.setPassword(old, for: newAccount, label: "vncx: \(connection.title)")
        }
        onDone(connection)
    }
}

struct SettingsView: View {
    @State private var prefs = Preferences.shared

    var body: some View {
        TabView {
            Form {
                Picker("Command key sends", selection: $prefs.commandKey) {
                    ForEach(CommandKeyMapping.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Send ⌘ shortcuts to the remote computer", isOn: $prefs.sendCommandShortcuts)
                Text("⌘Q, ⌘H and all ⌃⌘ shortcuts stay with vncx.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Capture system shortcuts", selection: $prefs.keyboardCapture) {
                    ForEach(KeyboardCapturePolicy.allCases) { Text($0.label).tag($0) }
                }
                Text("Sends ⌘Tab, ⌘Space, Mission Control and other system shortcuts to the remote computer. Requires Accessibility permission (System Settings › Privacy & Security › Accessibility).")
                    .font(.caption).foregroundStyle(.secondary)
                if prefs.keyboardCapture != .never && !KeyboardCapture.shared.isTrusted {
                    Button("Open Accessibility Settings…") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                    }
                }
                Toggle("Share clipboard with the remote computer", isOn: $prefs.syncClipboard)
            }
            .formStyle(.grouped)
            .tabItem { Label("Keyboard", systemImage: "keyboard") }

            Form {
                Toggle("Smooth scaling", isOn: $prefs.smoothScaling)
                Text("Filters the image when it is scaled. Integer zoom levels always stay pixel-sharp.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Default scaling", selection: $prefs.defaultScaling) {
                    ForEach(ScalingMode.allCases) { Text($0.label).tag($0) }
                }
                Picker("Default picture quality", selection: $prefs.defaultQuality) {
                    ForEach(Quality.allCases) { Text($0.label).tag($0) }
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Display", systemImage: "display") }
        }
        .frame(width: 520, height: 400)
    }
}
