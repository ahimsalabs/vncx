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
    /// Current pinch zoom of the main view (1 = none), mirrored from the view for the UI.
    var zoom: CGFloat = 1

    var scaling: ScalingMode {
        didSet {
            view?.scaling = scaling
            config.scaling = scaling
            persistConfig()
            windowController?.applyScaling(resizeWindow: true)
        }
    }
    var viewOnly: Bool {
        didSet { view?.viewOnly = viewOnly; config.viewOnly = viewOnly; persistConfig() }
    }
    /// Local cursor used when the server doesn't send cursor shapes.
    var localCursor: LocalCursorMode {
        didSet { view?.fallbackCursor = localCursor; config.localCursor = localCursor; persistConfig() }
    }
    var remoteResizeUsesRetina: Bool { config.remoteResizeRetina }

    @ObservationIgnored private(set) var client: RFBClient?
    @ObservationIgnored private(set) var framebuffer: Framebuffer?
    @ObservationIgnored private var cursor: RemoteCursor?
    @ObservationIgnored weak var view: RemoteView?
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
            if case .updated = event {
                // Coalesce redraws: at most one pending main-queue hop at a time.
                if self.redrawGate.arm() {
                    DispatchQueue.main.async {
                        self.redrawGate.disarm()
                        self.view?.needsDisplay = true
                    }
                }
                return
            }
            DispatchQueue.main.async { if self.generation == gen { self.handle(event) } }
        })
        self.client = client
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
        case .updated:
            view?.needsDisplay = true
        case .cursor(let c):
            cursor = c
            view?.setRemoteCursor(c)
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
        view?.framebuffer = fb
        view?.needsDisplay = true
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
        if store.connection(config.id) == nil,
           let existing = store.match(host: config.host, port: config.port, username: config.username, bonjourName: config.bonjourName) {
            var merged = existing
            merged.username = config.username.isEmpty ? existing.username : config.username
            config = merged
        }
        config.lastConnected = Date()
        config.lastResolution = "\(Int(framebufferSize.width))×\(Int(framebufferSize.height))"
        persistConfig(force: true)
    }

    private func persistConfig(force: Bool = false) {
        let store = ConnectionStore.shared
        if force || store.connection(config.id) != nil { store.upsert(config) }
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

    private func startStats() {
        statsTimer?.invalidate()
        lastBytes = client?.bytesReceived ?? 0
        statsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, let client = self.client else { return }
            let now = client.bytesReceived
            let bits = Double(now &- self.lastBytes) * 8
            self.lastBytes = now
            let text: String
            switch bits {
            case ..<1: text = ""
            case ..<1_000_000: text = String(format: "%.0f kbit/s", bits / 1000)
            default: text = String(format: "%.1f Mbit/s", bits / 1_000_000)
            }
            if text != self.throughput { self.throughput = text }
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
        guard hasConnectedOnce, ConnectionStore.shared.connection(config.id) != nil,
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
