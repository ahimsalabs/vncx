// Copyright 2026 Ahimsa Labs
// SPDX-License-Identifier: Apache-2.0

import VNCCore
import AppKit
import Network
import Observation
import UniformTypeIdentifiers
import ImageIO

/// One remote desktop connection and its UI state. Lives on the main thread; the RFB client posts events here.
@Observable
final class Session: Identifiable {
    enum Phase: Equatable {
        case connecting
        case connected
        /// Lost an established connection; retrying automatically. Associated value is the attempt number.
        case reconnecting(Int, String?)
        case disconnected(String?)
    }

    struct CredentialPrompt: Identifiable {
        let id = UUID()
        let request: CredentialRequest
        let hostLabel: String
        let username: String
        let previousFailed: Bool
    }

    let id = UUID()
    var config: SavedConnection
    private(set) var phase: Phase = .connecting
    private(set) var desktopName = ""
    private(set) var framebufferSize: CGSize = .zero
    private(set) var throughput = ""
    private(set) var securityType: SecurityType?
    /// Extra detail for the connecting overlay ("Opening SSH tunnel…").
    private(set) var statusDetail: String?
    var credentialPrompt: CredentialPrompt?
    /// A transient message shown at the bottom of the window (uploads, drop hints).
    struct Banner: Equatable {
        var text: String
        var busy = false
        var isError = false
    }
    var banner: Banner?
    @ObservationIgnored private var bannerWork: DispatchWorkItem?

    /// Something vncx knows it's waiting on, shown as a small indicator after a short delay.
    enum Waiting: Equatable {
        case server
        case receiving(bytes: UInt64)
        case limited(Double)
    }
    private(set) var waiting: Waiting?
    @ObservationIgnored private var waitTimer: Timer?
    @ObservationIgnored private var waitingShownAt: Date?

    private func updateWaiting() {
        var w: Waiting?
        if phase == .connected, let a = client?.activity() {
            if let t = a.fenceUnansweredFor, t > 1 { w = .server }
            else if let t = a.receivingFor, t > 0.4 { w = .receiving(bytes: a.receivedBytes) }
            else if let t = a.pacedFor, t > 0.4, let limit = a.limit { w = .limited(limit) }
        }
        // Once shown, stay up for at least half a second so it doesn't flicker.
        if w == nil, let shown = waitingShownAt, Date().timeIntervalSince(shown) < 0.5 { return }
        if w != nil && waiting == nil { waitingShownAt = Date() }
        if w != waiting { waiting = w }
    }

    private func stopWaitingIndicator() {
        waitTimer?.invalidate()
        waitTimer = nil
        waiting = nil
    }

    func showBanner(_ b: Banner?, for seconds: TimeInterval? = nil) {
        bannerWork?.cancel()
        banner = b
        guard let seconds else { return }
        let work = DispatchWorkItem { [weak self] in self?.banner = nil }
        bannerWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// Files dropped on the remote view: upload over SSH when configured.
    func handleDroppedFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        guard config.ssh.enabled else {
            showBanner(Banner(text: "VNC can’t transfer files. Set up SSH for this computer (Edit…) to drop files onto it.", isError: true), for: 6)
            return
        }
        let dest = config.sshDestination, dir = config.ssh.uploadDirectory
        let what = urls.count == 1 ? "“\(urls[0].lastPathComponent)”" : "\(urls.count) items"
        showBanner(Banner(text: "Uploading \(what) to \(dest):\(dir)…", busy: true))
        SSH.upload(urls, to: dest, directory: dir) { [weak self] result in
            switch result {
            case .success: self?.showBanner(Banner(text: "Uploaded \(what) to ~/\(dir) on \(dest)."), for: 4)
            case .failure(let e): self?.showBanner(Banner(text: "Upload failed: \(e.localizedDescription)", isError: true), for: 8)
            }
        }
    }

    /// Text dropped on the remote view is pasted there: it goes onto the remote clipboard, then the paste shortcut
    /// is sent. With `type` (Option held while dropping) it is typed key by key instead.
    func handleDroppedText(_ text: String, type: Bool = false) {
        guard !viewOnly, phase == .connected, let client else { return }
        let limited = String(text.prefix(1_000_000))
        // The classic clipboard is Latin-1 only; without the Unicode extension, other text can only be typed.
        let latin1 = limited.unicodeScalars.allSatisfy { $0.value < 0x100 }
        if type || (!client.supportsUnicodeClipboard && !latin1) {
            let typed = String(limited.prefix(20_000))
            view?.type(typed)
            showBanner(Banner(text: "Typed \(typed.count) characters."), for: 2)
            return
        }
        client.sendClipboard(limited)
        // Give the server a moment to take clipboard ownership before the application asks for it.
        let keys = pasteKeys
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.view?.sendKeyCombo(keys) }
        showBanner(Banner(text: "Pasted \(limited.count) characters. Hold ⌥ while dropping to type instead."), for: 3)
    }

    private var pasteKeys: [UInt32] {
        let m = KeyMapping.Modifier.self
        switch config.pasteShortcut {
        case .automatic: return client?.isAppleServer == true ? [Preferences.shared.commandKey.left, 0x76] : [m.controlL, 0x76]
        case .controlV: return [m.controlL, 0x76]
        case .commandV: return [Preferences.shared.commandKey.left, 0x76]
        case .controlShiftV: return [m.controlL, m.shiftL, 0x56]
        case .shiftInsert: return [m.shiftL, 0xff63]
        }
    }

    /// Current pinch zoom of the main view (1 = none), mirrored from the view for the UI.
    var zoom: CGFloat = 1

    var scaling: ScalingMode {
        didSet {
            allViews.forEach { $0.scaling = scaling }
            config.scaling = scaling
            persistConfig()
            windowController?.applyScaling(resizeWindow: true)
        }
    }
    var viewOnly: Bool {
        didSet { allViews.forEach { $0.viewOnly = viewOnly }; config.viewOnly = viewOnly; persistConfig() }
    }
    /// Local cursor used when the server doesn't send cursor shapes.
    var localCursor: LocalCursorMode {
        didSet { allViews.forEach { $0.fallbackCursor = localCursor }; config.localCursor = localCursor; persistConfig() }
    }
    var remoteResizeUsesRetina: Bool { config.remoteResizeRetina }

    @ObservationIgnored private(set) var client: RFBClient?
    @ObservationIgnored private(set) var framebuffer: Framebuffer?
    @ObservationIgnored private var cursor: RemoteCursor?
    @ObservationIgnored private var hasCursorInfo = false
    /// The main window's view.
    @ObservationIgnored weak var view: RemoteView?
    /// Views in per-display windows, keyed by remote screen id.
    @ObservationIgnored private var auxViews: [UInt32: WeakRemoteView] = [:]
    @ObservationIgnored var auxControllers: [UInt32: SessionWindowController] = [:]

    var allViews: [RemoteView] { ([view] + auxViews.values.map(\.view)).compactMap { $0 } }

    func register(_ v: RemoteView, display: UInt32?) {
        if let display { auxViews[display] = WeakRemoteView(view: v) } else { view = v }
        v.framebuffer = framebuffer
        if hasCursorInfo { v.setRemoteCursor(cursor) }
    }

    func remoteView(for display: UInt32?) -> RemoteView? { display.flatMap { auxViews[$0]?.view } ?? (display == nil ? view : nil) }

    // MARK: Displays

    /// Remote monitors, ordered left to right (then top to bottom), numbered from 1.
    private(set) var displays: [RemoteDisplay] = []
    /// Which display the main window shows; nil shows the whole desktop.
    var selectedDisplay: UInt32? {
        didSet {
            guard selectedDisplay != oldValue else { return }
            view?.crop = cropRect(for: selectedDisplay)
            if let d = displays.first(where: { $0.id == selectedDisplay }) { config.preferredDisplay = d.key } else { config.preferredDisplay = nil }
            persistConfig()
            windowController?.applyScaling(resizeWindow: true)
        }
    }

    func cropRect(for display: UInt32?) -> CGRect? {
        guard let display, displays.count > 1 else { return nil }
        return displays.first { $0.id == display }?.rect
    }

    func display(_ id: UInt32?) -> RemoteDisplay? { displays.first { $0.id == id } }

    private func updateDisplays(_ layouts: [ScreenLayout]) {
        let sorted = layouts.sorted { ($0.x, $0.y) < ($1.x, $1.y) }
        let list = sorted.enumerated().map { i, l in
            RemoteDisplay(id: l.id, number: i + 1, rect: CGRect(x: Int(l.x), y: Int(l.y), width: Int(l.w), height: Int(l.h)))
        }
        guard list != displays else { return }
        displays = list
        if list.count <= 1 {
            if selectedDisplay != nil { selectedDisplay = nil }
            auxControllers.values.forEach { $0.close() }
        } else if let current = selectedDisplay, list.contains(where: { $0.id == current }) {
            view?.crop = cropRect(for: current) // geometry may have changed
        } else if let pref = config.preferredDisplay {
            // Restore the remembered display: same number and size, else same size, else same number.
            let parts = pref.split(separator: ":")
            let number = Int(parts.first ?? "") ?? 0, size = parts.count > 1 ? String(parts[1]) : ""
            let match = list.first { $0.number == number && $0.sizeText == size } ?? list.first { $0.sizeText == size }
                ?? list.first { $0.number == number }
            selectedDisplay = match?.id
        }
        for (id, c) in auxControllers where !list.contains(where: { $0.id == id }) { c.close() }
        for v in auxViews { v.value.view?.crop = cropRect(for: v.key) }
    }

    /// Opens every display other than the main window's in its own window. With `fullScreen`, each window
    /// is moved to a different Mac display (left to right) and made full screen.
    func openAllDisplays(fullScreen: Bool) {
        guard displays.count > 1 else { return }
        if selectedDisplay == nil { selectedDisplay = displays[0].id }
        var windows: [NSWindow] = [windowController?.window].compactMap { $0 }
        for d in displays where d.id != selectedDisplay {
            let c = auxControllers[d.id] ?? SessionManager.shared.openAuxiliary(session: self, display: d.id)
            if Self.isEphemeral { c.window?.orderFrontRegardless() } else { c.showWindow(nil) }
            if let w = c.window { windows.append(w) }
        }
        guard fullScreen else { return }
        let screens = NSScreen.screens.sorted { $0.frame.minX < $1.frame.minX }
        for (i, w) in windows.enumerated() {
            let screen = screens[i % screens.count]
            if !w.styleMask.contains(.fullScreen) {
                let f = screen.visibleFrame
                w.setFrame(NSRect(x: f.minX + 40, y: f.minY + 40, width: min(w.frame.width, f.width - 80),
                                  height: min(w.frame.height, f.height - 80)), display: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3 * Double(i)) { w.toggleFullScreen(nil) }
            }
        }
    }

    func showAllDisplaysInOneWindow() {
        auxControllers.values.forEach { $0.close() }
        selectedDisplay = nil
    }

    func auxiliaryClosed(_ display: UInt32) {
        auxViews[display] = nil
        auxControllers[display] = nil
    }
    @ObservationIgnored weak var windowController: SessionWindowController?
    @ObservationIgnored private var credentialReply: ((Credentials?) -> Void)?
    @ObservationIgnored private var lastAuthFailed = false
    @ObservationIgnored private let redrawGate = RedrawGate()
    @ObservationIgnored private var statsTimer: Timer?
    @ObservationIgnored private var lastBytes: UInt64 = 0
    @ObservationIgnored private var lastPasteboardChange = NSPasteboard.general.changeCount
    @ObservationIgnored private var hasConnectedOnce = false
    @ObservationIgnored private var generation = 0
    /// Credentials from the last successful login, reused for automatic reconnects (memory only).
    @ObservationIgnored private var sessionCredentials: Credentials?
    @ObservationIgnored private var reconnectWork: DispatchWorkItem?
    @ObservationIgnored private var reconnectAttempt = 0
    @ObservationIgnored private var watchdog: DispatchWorkItem?
    @ObservationIgnored private var tunnel: SSHTunnel?
    @ObservationIgnored private var triedStartCommand = false
    @ObservationIgnored private var wakeDeadline: Date?
    private static let retryDelays: [TimeInterval] = [1, 2, 3, 5, 8, 13, 20, 30]
    private static let maxReconnectAttempts = 30

    init(config: SavedConnection) {
        self.config = config
        self.scaling = config.scaling
        self.viewOnly = config.viewOnly
        self.localCursor = config.localCursor
    }

    var title: String {
        if !desktopName.isEmpty, phase == .connected { return desktopName }
        return config.title
    }

    var subtitle: String {
        var parts: [String] = []
        if framebufferSize != .zero { parts.append("\(Int(framebufferSize.width))×\(Int(framebufferSize.height))") }
        if phase == .connected, !throughput.isEmpty { parts.append(throughput) }
        if zoom > 1.001 { parts.append("\(Int((zoom * 100).rounded()))%") }
        if viewOnly { parts.append("View Only") }
        return parts.joined(separator: " · ")
    }

    private var hostLabel: String { config.bonjourName ?? Address(host: config.host, port: config.port).display }

    // MARK: Lifecycle

    func connect() {
        reconnectWork?.cancel()
        watchdog?.cancel()
        client?.stop()
        generation += 1
        let gen = generation
        if case .reconnecting = phase {} else { phase = .connecting }
        credentialPrompt = nil
        statusDetail = nil

        if config.ssh.enabled && config.ssh.tunnel && !(tunnel?.isRunning ?? false) {
            if config.bonjourName != nil && config.ssh.destination.isEmpty {
                phase = .disconnected("Set an SSH destination to tunnel a Bonjour computer.")
                return
            }
            tunnel?.close()
            tunnel = nil
            statusDetail = "Opening SSH tunnel to \(config.sshDestination)…"
            SSHTunnel.open(destination: config.sshDestination, remoteHost: config.ssh.tunnelHost, remotePort: config.port) { [weak self] result in
                guard let self, self.generation == gen else { if case .success(let t) = result { t.close() }; return }
                switch result {
                case .success(let t):
                    self.tunnel = t
                    self.startClient(generation: gen)
                case .failure(let error):
                    self.statusDetail = nil
                    if self.isReconnecting { self.scheduleReconnect(reason: error.localizedDescription) }
                    else { self.phase = .disconnected(error.localizedDescription) }
                }
            }
            return
        }
        startClient(generation: gen)
    }

    private func startClient(generation gen: Int) {
        statusDetail = nil

        let endpoint: NWEndpoint
        if let tunnel, config.ssh.enabled && config.ssh.tunnel {
            endpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(integerLiteral: tunnel.localPort))
        } else if let name = config.bonjourName {
            endpoint = BonjourBrowser.shared.endpoint(named: name)
        } else {
            endpoint = .hostPort(host: NWEndpoint.Host(config.host), port: NWEndpoint.Port(integerLiteral: UInt16(clamping: config.port)))
        }
        let snapshot = config
        let skipKeychain = lastAuthFailed
        let remembered = lastAuthFailed ? nil : sessionCredentials
        let options = RFBOptions(endpoint: endpoint, username: config.username, password: nil, quality: config.quality)

        let client = RFBClient(options: options, credentialProvider: { [weak self] request in
            if let remembered, !(request.needsUsername && remembered.username.isEmpty) { return remembered }
            return self?.provideCredentials(request, config: snapshot, skipKeychain: skipKeychain, generation: gen)
        }, onEvent: { [weak self] event in
            guard let self else { return }
            switch event {
            case .updated, .progress:
                // Coalesce redraws: at most one pending main-queue hop at a time.
                if self.redrawGate.arm() {
                    DispatchQueue.main.async {
                        self.redrawGate.disarm()
                        for v in self.allViews { v.needsDisplay = true }
                    }
                }
            default:
                DispatchQueue.main.async { if self.generation == gen { self.handle(event) } }
            }
        })
        self.client = client
        client.setBandwidthLimit(config.bandwidth.bitsPerSecond)
        client.setMotionLevel(config.quality == .auto ? Self.lowestAutomatic : nil)
        client.start()
    }

    func disconnect() {
        generation += 1
        reconnectWork?.cancel()
        watchdog?.cancel()
        reconnectAttempt = 0
        credentialReply?(nil)
        credentialReply = nil
        credentialPrompt = nil
        client?.stop()
        client = nil
        tunnel?.close()
        tunnel = nil
        statusDetail = nil
        saveThumbnail()
        statsTimer?.invalidate()
        stopWaitingIndicator()
        if phase != .disconnected(nil) { phase = .disconnected(nil) }
    }

    /// Schedules the next automatic reconnect attempt, or gives up after too many.
    private func scheduleReconnect(reason: String?) {
        reconnectAttempt += 1
        guard reconnectAttempt <= Self.maxReconnectAttempts else {
            reconnectAttempt = 0
            phase = .disconnected(reason ?? "The connection was lost.")
            return
        }
        phase = .reconnecting(reconnectAttempt, reason)
        let delay = Self.retryDelays[min(reconnectAttempt - 1, Self.retryDelays.count - 1)]
        let work = DispatchWorkItem { [weak self] in self?.connect() }
        reconnectWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// After sleep or a network change the TCP connection may be silently dead. Ask for a full frame (which the
    /// server must answer) and reconnect if nothing arrives in time.
    func verifyConnection(timeout: TimeInterval = 4) {
        guard phase == .connected, let client else { return }
        let before = client.bytesReceived
        client.requestUpdate(incremental: false)
        watchdog?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.phase == .connected, let c = self.client, c === client else { return }
            if c.bytesReceived == before {
                self.generation += 1 // ignore the dead client's own disconnect event
                c.stop()
                self.client = nil
                self.reconnectAttempt = 0
                self.scheduleReconnect(reason: "The connection stopped responding.")
            }
        }
        watchdog = work
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: work)
    }

    /// Called on the RFB thread. Uses the Keychain when possible, otherwise asks the user and blocks for the reply.
    private func provideCredentials(_ request: CredentialRequest, config: SavedConnection, skipKeychain: Bool, generation: Int) -> Credentials? {
        let account = Keychain.account(host: config.bonjourName ?? config.host, port: config.port,
                                       username: request.needsUsername ? config.username : "")
        if !skipKeychain, !(request.needsUsername && config.username.isEmpty), let pw = Keychain.password(for: account) {
            return Credentials(username: config.username, password: pw, remember: false)
        }
        let sem = DispatchSemaphore(value: 0)
        var result: Credentials?
        DispatchQueue.main.async {
            guard self.generation == generation else { sem.signal(); return }
            self.credentialReply = { c in result = c; sem.signal() }
            self.credentialPrompt = CredentialPrompt(request: request, hostLabel: self.hostLabel,
                                                     username: config.username.isEmpty ? NSUserName() : config.username,
                                                     previousFailed: skipKeychain)
        }
        sem.wait()
        return result
    }

    func submitCredentials(_ c: Credentials?) {
        credentialPrompt = nil
        let reply = credentialReply
        credentialReply = nil
        reply?(c)
        if c == nil { disconnect() }
    }

    private func handle(_ event: RFBEvent) {
        switch event {
        case .connected(let name, let fb, let sec):
            phase = .connected
            statusDetail = nil
            wakeDeadline = nil
            reconnectAttempt = 0
            triedStartCommand = false
            if let used = client?.usedCredentials { sessionCredentials = used }
            desktopName = name
            securityType = sec
            lastAuthFailed = false
            setFramebuffer(fb)
            rememberSuccessfulConnection()
            windowController?.connected(firstTime: !hasConnectedOnce)
            hasConnectedOnce = true
            view?.remoteResizeIfNeeded()
            startStats()
            syncClipboardToRemote(force: true)
        case .resized(let fb):
            setFramebuffer(fb)
            windowController?.remoteResized()
        case .updated, .progress:
            allViews.forEach { $0.needsDisplay = true }
        case .cursor(let c):
            cursor = c
            hasCursorInfo = true
            allViews.forEach { $0.setRemoteCursor(c) }
        case .screens(let layouts):
            updateDisplays(layouts)
        case .bell:
            NSSound.beep()
        case .clipboard(let text):
            guard Preferences.shared.syncClipboard, !text.isEmpty else { return }
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(text, forType: .string)
            lastPasteboardChange = pb.changeCount
        case .nameChanged(let name):
            desktopName = name
        case .disconnected(let error):
            statsTimer?.invalidate()
        stopWaitingIndicator()
            watchdog?.cancel()
            let wasConnected = phase == .connected
            if wasConnected { saveThumbnail() }
            client = nil
            credentialPrompt = nil
            let message = error?.localizedDescription ?? (hasConnectedOnce ? "The connection was closed." : nil)
            // Nobody listening (or the tunnel's far end refused): try starting the server over SSH once.
            let unreachable: Bool = {
                switch error as? RFBError { case .refused?, .closed?: return true; default: return false }
            }()
            if !wasConnected, unreachable, config.ssh.enabled, !config.ssh.startCommand.isEmpty, !triedStartCommand {
                runStartCommand()
                return
            }
            let preConnectFailure: Bool = {
                switch error as? RFBError { case .authFailed?, .cancelled?, .protocol?, .auth?: return false; default: return true }
            }()
            if !wasConnected, preConnectFailure, config.wake.isConfigured {
                // The computer may be asleep: wake it once, then keep retrying until the deadline.
                if wakeDeadline == nil {
                    wakeDeadline = Date().addingTimeInterval(120)
                    sendWake()
                }
                if let deadline = wakeDeadline, Date() < deadline {
                    statusDetail = "Waking \(config.title)…"
                    if case .reconnecting = phase {} else { phase = .connecting }
                    let gen = generation
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                        guard let self, self.generation == gen else { return }
                        self.connect()
                    }
                    return
                }
                wakeDeadline = nil
            }
            if case .authFailed = error as? RFBError {
                lastAuthFailed = true
                sessionCredentials = nil
                reconnectAttempt = 0
                phase = .disconnected(message)
            } else if case .cancelled = error as? RFBError {
                phase = .disconnected(nil)
            } else if wasConnected || isReconnecting {
                // Lost a working connection (or still trying to get it back): keep retrying.
                scheduleReconnect(reason: message)
            } else {
                phase = .disconnected(message)
            }
        }
    }

    private func setFramebuffer(_ fb: Framebuffer) {
        framebuffer = fb
        framebufferSize = CGSize(width: fb.width, height: fb.height)
        for v in allViews { v.framebuffer = fb; v.needsDisplay = true }
    }

    /// Records the connection in history and saves credentials the user asked us to remember.
    private func rememberSuccessfulConnection() {
        let store = ConnectionStore.shared
        if let used = client?.usedCredentials {
            if !used.username.isEmpty { config.username = used.username }
            if used.remember {
                let account = Keychain.account(host: config.bonjourName ?? config.host, port: config.port,
                                               username: securityType == .appleRemoteDesktop ? used.username : "")
                Keychain.setPassword(used.password, for: account, label: "vncx: \(config.title)")
            }
        }
        if !Self.isEphemeral, store.connection(config.id) == nil,
           let existing = store.match(host: config.host, port: config.port, username: config.username, bonjourName: config.bonjourName) {
            var merged = existing
            merged.username = config.username.isEmpty ? existing.username : config.username
            config = merged
        }
        config.lastConnected = Date()
        config.lastResolution = "\(Int(framebufferSize.width))×\(Int(framebufferSize.height))"
        persistConfig(force: true)
    }

    /// Development runs (VNCX_DEBUG_DIR / VNCX_OPEN_JSON) never touch the user's saved connections.
    static let isEphemeral = ProcessInfo.processInfo.environment["VNCX_DEBUG_DIR"] != nil
        || ProcessInfo.processInfo.environment["VNCX_OPEN_JSON"] != nil

    private func persistConfig(force: Bool = false) {
        guard !Self.isEphemeral else { return }
        let store = ConnectionStore.shared
        if force || store.connection(config.id) != nil { store.upsert(config) }
    }

    /// Sends a Wake-on-LAN packet locally, and through the relay host when one is configured.
    func sendWake(completion: ((String?) -> Void)? = nil) {
        guard let mac = WakeOnLAN.parseMAC(config.wake.mac) else { completion?("Invalid MAC address."); return }
        WakeOnLAN.sendLocal(mac: mac, broadcast: config.wake.broadcast)
        let relay = config.wake.relay.trimmingCharacters(in: .whitespaces)
        guard !relay.isEmpty else { completion?(nil); return }
        WakeOnLAN.sendViaRelay(relay, mac: mac) { result in
            if case .failure(let e) = result { completion?("Relay \(relay): \(e.localizedDescription)") } else { completion?(nil) }
        }
    }

    private func runStartCommand() {
        triedStartCommand = true
        let gen = generation
        let destination = config.sshDestination
        let command = config.ssh.startCommand.replacingOccurrences(of: "{port}", with: String(config.port))
        statusDetail = "Starting the VNC server on \(destination)…"
        if case .reconnecting = phase {} else { phase = .connecting }
        SSH.run(destination, command: command) { [weak self] result in
            guard let self, self.generation == gen else { return }
            switch result {
            case .success:
                self.statusDetail = "Waiting for the VNC server…"
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    guard let self, self.generation == gen else { return }
                    self.connect()
                }
            case .failure(let error):
                self.statusDetail = nil
                self.phase = .disconnected("Couldn’t start the VNC server over SSH: \(error.localizedDescription)")
            }
        }
    }

    func reconnect() {
        triedStartCommand = false
        wakeDeadline = nil
        reconnectAttempt = 0
        connect()
    }

    var isReconnecting: Bool { if case .reconnecting = phase { return true } else { return false } }

    // MARK: Remote control helpers

    func requestRemoteSize(_ size: CGSize) {
        client?.requestDesktopSize(width: Int(size.width), height: Int(size.height))
    }

    func sendCtrlAltDel() {
        view?.sendKeyCombo([KeyMapping.Modifier.controlL, KeyMapping.Modifier.altL, 0xffff])
    }

    func sendKeys(_ syms: [UInt32]) { view?.sendKeyCombo(syms) }

    func typeClipboard() {
        if let s = NSPasteboard.general.string(forType: .string) { view?.type(s) }
    }

    /// Pushes the local clipboard to the server if it changed since we last looked.
    func syncClipboardToRemote(force: Bool = false) {
        guard Preferences.shared.syncClipboard, let client, phase == .connected, !viewOnly else { return }
        let pb = NSPasteboard.general
        guard force || pb.changeCount != lastPasteboardChange else { return }
        lastPasteboardChange = pb.changeCount
        if let s = pb.string(forType: .string), !s.isEmpty { client.sendClipboard(s) }
    }

    func zoomIn() { view.map { $0.setZoom($0.zoom * 1.25) } }
    func zoomOut() { view.map { $0.setZoom($0.zoom / 1.25 < 1.03 ? 1 : $0.zoom / 1.25) } }
    func resetZoom() { view?.setZoom(1) }

    func refresh() { client?.requestUpdate(incremental: false) }

    /// What the stats overlay shows, refreshed once a second.
    struct LiveStats: Equatable {
        var fps = 0
        var bitsPerSecond: Double = 0
        var linkBitsPerSecond: Double?
        var rttMs: Double?
        var encodings: [(name: String, share: Double)] = []
        var level: Quality = .lossless
        var continuous = false
        var limit: Double?
        var inMotion = false
        static func == (a: LiveStats, b: LiveStats) -> Bool {
            a.fps == b.fps && a.bitsPerSecond == b.bitsPerSecond && a.linkBitsPerSecond == b.linkBitsPerSecond
                && a.rttMs == b.rttMs && a.level == b.level && a.continuous == b.continuous && a.limit == b.limit && a.inMotion == b.inMotion
                && a.encodings.map(\.name) == b.encodings.map(\.name) && a.encodings.map(\.share) == b.encodings.map(\.share)
        }
    }

    private(set) var liveStats = LiveStats()
    var showStats = false
    @ObservationIgnored private var lastSnapshot: RFBStats?
    @ObservationIgnored private var statsTick = 0
    @ObservationIgnored private var pendingLevel: (level: Quality, count: Int)?

    private func startStats() {
        statsTimer?.invalidate()
        stopWaitingIndicator()
        lastSnapshot = nil
        statsTick = 0
        pendingLevel = nil
        bytesPerPixelCorrection = 1
        statsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.statsTimerFired()
        }
        waitTimer?.invalidate()
        waitTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            self?.updateWaiting()
        }
    }

    private func statsTimerFired() {
        guard let client else { return }
        statsTick += 1
        if statsTick % 2 == 1 { client.measureLatency() }
        let now = client.statsSnapshot()
        defer { lastSnapshot = now }
        guard let prev = lastSnapshot else { return }

        var live = LiveStats()
        live.fps = now.updates - prev.updates
        live.bitsPerSecond = Double(now.bytes &- prev.bytes) * 8
        live.linkBitsPerSecond = now.linkRate.map { $0 * 8 }
        live.rttMs = now.rtt.map { $0 * 1000 }
        live.level = now.level
        live.continuous = now.continuousUpdates
        live.limit = now.limit
        live.inMotion = now.inMotion
        let deltas = now.rectBytes.map { (Encoding.name($0.key), Double($0.value &- (prev.rectBytes[$0.key] ?? 0))) }
            .filter { $0.1 > 0 && !$0.0.hasPrefix("-") }
        let total = deltas.reduce(0) { $0 + $1.1 }
        if total > 0 {
            live.encodings = deltas.sorted { $0.1 > $1.1 }.prefix(3).map { ($0.0, $0.1 / total) }
        } else {
            live.encodings = liveStats.encodings // keep showing the last mix while idle
        }
        if live != liveStats { liveStats = live }
        let act = client.activity()
        func ms(_ t: Double?) -> Int { t.map { Int($0 * 1000) } ?? -1 }
        flowLog.info("""
            fps=\(live.fps) kbit=\(Int(live.bitsPerSecond / 1000)) limit=\(Int((now.limit ?? 0) / 1000)) \
            cu=\(now.continuousUpdates) level=\(now.level.rawValue, privacy: .public) rtt=\(ms(now.rtt)) \
            req=\(ms(act.requestOutstandingFor)) paced=\(ms(act.pacedFor)) recv=\(ms(act.receivingFor)) \
            fence=\(ms(act.fenceUnansweredFor)) waiting=\(String(describing: self.waiting), privacy: .public)
            """)

        let text: String
        switch live.bitsPerSecond {
        case ..<1: text = ""
        case ..<1_000_000: text = String(format: "%.0f kbit/s", live.bitsPerSecond / 1000)
        default: text = String(format: "%.1f Mbit/s", live.bitsPerSecond / 1_000_000)
        }
        if text != throughput { throughput = text }

        if config.quality == .auto { adjustQuality(now, previous: prev) }
    }

    /// Automatic goes no lower: below JPEG 4 a full repaint on WayVNC shrinks only another 14% (3.7 → 3.2 MB on a 5K
    /// desktop) while text gets visibly blocky. JPEG 0 to 3 stay available as manual choices.
    private static let lowestAutomatic = Quality.jpeg(4)

    /// Bytes per pixel of a full repaint at each level, measured on a 4915×3648 WayVNC desktop. WayVNC sends every
    /// 64×64 tile as its own JPEG, so headers flatten the low end; JPEG 9 costs more than lossless there.
    private static let typicalBytesPerPixel: [Quality: Double] = [
        .lossless: 0.40, .jpeg(9): 0.50, .jpeg(8): 0.26, .jpeg(7): 0.24, .jpeg(6): 0.22, .jpeg(5): 0.215,
        .jpeg(4): 0.21, .jpeg(3): 0.20, .jpeg(2): 0.196, .jpeg(1): 0.19, .jpeg(0): 0.18]
    /// Observed bytes per pixel ÷ the typical figure at the current level, so the table fits this server and
    /// desktop (TigerVNC sends far fewer JPEG headers; a desktop of text compresses better than a video).
    @ObservationIgnored private var bytesPerPixelCorrection = 1.0

    /// The best level worth sending for how the remote is shown: when several remote pixels land on one screen
    /// pixel, JPEG artifacts shrink below what you can see.
    private var levelCapForDisplay: Quality {
        guard let v = view else { return .lossless }
        let devicePixelsPerRemotePixel = v.currentLayout().scale * v.backingScale
        switch devicePixelsPerRemotePixel {
        case 0.9...: return .lossless
        case 0.6..<0.9: return .jpeg(8)
        case 0.4..<0.6: return .jpeg(6)
        default: return .jpeg(4)
        }
    }

    /// Automatic quality: the best level, up to the display cap, at which a full-screen repaint (a tab switch, a new
    /// window) would arrive within half a second, from the remote's size, bytes per pixel at each level and the
    /// measured delivery rate. Raw link speed alone picks lossless for a 5K desktop on a fast link, where a tab
    /// switch then costs 8 to 12 MB and seconds. Downgrades after 3 s of evidence, upgrades after 6 s.
    private func adjustQuality(_ st: RFBStats, previous prev: RFBStats) {
        // Learn from about a megapixel or more of updates at one level.
        let pixels = st.pixels &- prev.pixels
        if pixels > 1_000_000, st.level == prev.level, !st.inMotion, !prev.inMotion, let typical = Self.typicalBytesPerPixel[st.level] {
            let bytes = st.rectBytes.filter { $0.key >= 0 }.reduce(0.0) { $0 + Double($1.value &- (prev.rectBytes[$1.key] ?? 0)) }
            let observed = min(max(bytes / Double(pixels) / typical, 0.25), 4)
            bytesPerPixelCorrection = bytesPerPixelCorrection * 0.7 + observed * 0.3
        }
        guard let rate = st.linkRate.map({ $0 * 8 }), rate > 0 else { return } // bits/s; unknown until a big update
        let screen = Double(framebufferSize.width * framebufferSize.height)
        let rtt = st.rtt ?? 0
        func repaintSeconds(_ q: Quality) -> Double {
            screen * (Self.typicalBytesPerPixel[q] ?? 0.4) * bytesPerPixelCorrection * 8 / rate + rtt
        }
        let cap = levelCapForDisplay
        let target = Quality.levels.first {
            $0.rank <= cap.rank && $0.rank > Self.lowestAutomatic.rank && repaintSeconds($0) <= 0.5
        } ?? Self.lowestAutomatic
        guard target != st.level else { pendingLevel = nil; return }
        let count = (pendingLevel?.level == target ? pendingLevel!.count : 0) + 1
        pendingLevel = (target, count)
        if count >= (target.rank > st.level.rank ? 6 : 3) {
            client?.setQualityLevel(target)
            pendingLevel = nil
        }
    }

    // MARK: Images

    func snapshot(maxWidth: Int? = nil) -> CGImage? {
        guard let fb = framebuffer,
              let provider = CGDataProvider(dataInfo: nil, data: fb.pixels, size: fb.bytesPerRow * fb.height, releaseData: { _, _, _ in }),
              let full = CGImage(width: fb.width, height: fb.height, bitsPerComponent: 8, bitsPerPixel: 32,
                                 bytesPerRow: fb.bytesPerRow, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                 bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue),
                                 provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        let scale = maxWidth.map { min(1, CGFloat($0) / CGFloat(fb.width)) } ?? 1
        let w = Int(CGFloat(fb.width) * scale), h = Int(CGFloat(fb.height) * scale)
        // Always copy, so the image doesn't alias framebuffer memory that keeps changing.
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(full, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    private func saveThumbnail() {
        guard !Self.isEphemeral, hasConnectedOnce, ConnectionStore.shared.connection(config.id) != nil,
              let image = snapshot(maxWidth: 640) else { return }
        let url = ConnectionStore.shared.thumbnailURL(config.id)
        if write(image, to: url) { ConnectionStore.shared.thumbnailGeneration += 1 }
    }

    @discardableResult
    func write(_ image: CGImage, to url: URL) -> Bool {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest)
    }

    func saveScreenshot() {
        guard let image = snapshot() else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let name = "\(config.title) \(formatter.string(from: Date())).png".replacingOccurrences(of: "/", with: "-")
        let dir = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        let url = dir.appendingPathComponent(name)
        if write(image, to: url) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    func copyScreenshot() {
        guard let image = snapshot() else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([NSImage(cgImage: image, size: .zero)])
    }
}

/// A tiny lock-protected flag used to coalesce redraw requests from the network thread.
final class RedrawGate: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = false
    func arm() -> Bool { lock.withLock { if pending { return false }; pending = true; return true } }
    func disarm() { lock.withLock { pending = false } }
}
