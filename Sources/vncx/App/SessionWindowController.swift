import VNCCore
import AppKit
import Network
import SwiftUI

/// Owns a session's NSWindow. We manage these windows in AppKit (rather than a SwiftUI WindowGroup) because a VNC
/// viewer needs precise control over content size, aspect ratio, and full screen behavior.
final class SessionWindowController: NSWindowController, NSWindowDelegate {
    let session: Session
    /// nil for the session's main window; a remote screen id for a per-display window.
    let displayID: UInt32?
    var isAuxiliary: Bool { displayID != nil }
    private var remoteView: RemoteView? { session.remoteView(for: displayID) }

    init(session: Session, displayID: UInt32? = nil) {
        self.session = session
        self.displayID = displayID
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 600),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.tabbingMode = .automatic
        window.tabbingIdentifier = "vncx.session"
        window.titlebarSeparatorStyle = .automatic
        window.backgroundColor = .black
        window.minSize = NSSize(width: 320, height: 200)

        let host = NSHostingController(rootView: SessionView(session: session, displayID: displayID))
        host.sizingOptions = []
        host.sceneBridgingOptions = [.toolbars, .title]
        window.contentViewController = host
        window.setContentSize(NSSize(width: 960, height: 600))
        window.center()
        super.init(window: window)
        window.delegate = self
        if let displayID {
            session.auxControllers[displayID] = self
            window.tabbingMode = .disallowed
            DispatchQueue.main.async { [weak self] in self?.resizeToIdeal(); self?.applyScaling(resizeWindow: false) }
        } else {
            session.windowController = self
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private var isFullScreen: Bool { window?.styleMask.contains(.fullScreen) ?? false }

    /// Sizes the window to show the remote desktop at its ideal size the first time we connect.
    func connected(firstTime: Bool) {
        if firstTime { resizeToIdeal() }
        applyScaling(resizeWindow: false)
    }

    func remoteResized() {
        guard session.scaling != .remoteResize else { return }
        applyScaling(resizeWindow: session.scaling == .fit)
    }

    func applyScaling(resizeWindow: Bool) {
        guard let window, session.framebuffer != nil, let region = remoteView?.region.size, region.width > 0 else { return }
        switch session.scaling {
        case .fit:
            window.contentAspectRatio = region
            if resizeWindow && !isFullScreen { fitWindowToAspect() }
        case .fillWidth, .fillHeight, .actual, .remoteResize:
            window.contentResizeIncrements = NSSize(width: 1, height: 1) // clears the aspect ratio constraint
            if resizeWindow && !isFullScreen && session.scaling == .actual { resizeToIdeal() }
        }
    }

    private func resizeToIdeal() {
        guard let window, session.framebuffer != nil, let view = remoteView, !isFullScreen else { return }
        let size = view.idealContentSize(for: view.region.size, on: window.screen ?? NSScreen.main)
        setContentSize(size)
    }

    private func fitWindowToAspect() {
        guard let window, let region = remoteView?.region.size, region.height > 0 else { return }
        let current = window.contentRect(forFrameRect: window.frame).size
        let aspect = region.width / region.height
        var size = NSSize(width: current.width, height: (current.width / aspect).rounded())
        if let visible = (window.screen ?? NSScreen.main)?.visibleFrame, size.height > visible.height - 60 {
            size.height = visible.height - 60
            size.width = (size.height * aspect).rounded()
        }
        setContentSize(size)
    }

    private func setContentSize(_ size: NSSize) {
        guard let window else { return }
        let oldFrame = window.frame
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        // Keep the top-left corner fixed, then nudge back on screen.
        frame.origin = NSPoint(x: oldFrame.minX, y: oldFrame.maxY - frame.height)
        if let visible = (window.screen ?? NSScreen.main)?.visibleFrame {
            if frame.maxX > visible.maxX { frame.origin.x = max(visible.minX, visible.maxX - frame.width) }
            if frame.minY < visible.minY { frame.origin.y = visible.minY }
            if frame.maxY > visible.maxY { frame.origin.y = visible.maxY - frame.height }
        }
        window.setFrame(frame, display: true, animate: window.isVisible)
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        if let displayID {
            session.auxiliaryClosed(displayID)
            SessionManager.shared.closedAuxiliary(self)
            return
        }
        session.auxControllers.values.forEach { $0.close() }
        session.disconnect()
        SessionManager.shared.closed(self)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        SessionManager.shared.activeSession = session
        session.syncClipboardToRemote()
        KeyboardCapture.shared.update()
    }

    func windowDidResignKey(_ notification: Notification) {
        if SessionManager.shared.activeSession === session { SessionManager.shared.activeSession = nil }
        DispatchQueue.main.async { KeyboardCapture.shared.update() }
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        remoteView?.remoteResizeIfNeeded()
        KeyboardCapture.shared.update()
    }
    func windowDidExitFullScreen(_ notification: Notification) {
        KeyboardCapture.shared.update()
        applyScaling(resizeWindow: false)
        remoteView?.remoteResizeIfNeeded()
    }
}

/// Tracks open session windows and which one is active (for menu commands).
@Observable
final class SessionManager {
    static let shared = SessionManager()
    private var controllers: [UUID: SessionWindowController] = [:]
    var activeSession: Session?
    @ObservationIgnored private let pathMonitor = NWPathMonitor()
    @ObservationIgnored private var lastPath: (status: NWPath.Status, interfaces: [String])?

    init() {
        // After sleep or a network change, connections can be dead without the socket noticing.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.verifyAll(after: 1.5)
        }
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let snapshot = (path.status, path.availableInterfaces.map(\.name))
            DispatchQueue.main.async {
                guard let self else { return }
                defer { self.lastPath = snapshot }
                guard let last = self.lastPath, last.status != snapshot.0 || last.interfaces != snapshot.1,
                      snapshot.0 == .satisfied else { return }
                self.verifyAll(after: 1)
            }
        }
        pathMonitor.start(queue: .global(qos: .utility))
    }

    private func verifyAll(after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            for c in self.controllers.values { c.session.verifyConnection() }
        }
    }

    func open(_ config: SavedConnection) {
        // If this saved connection is already open, just bring it forward.
        if let existing = controllers.values.first(where: { $0.session.config.id == config.id }) {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let session = Session(config: config)
        let controller = SessionWindowController(session: session)
        controllers[session.id] = controller
        if Session.isEphemeral {
            // Development runs must never steal focus (keystrokes meant for another app would reach the remote).
            controller.window?.orderFrontRegardless()
        } else {
            controller.showWindow(nil)
            controller.window?.makeKeyAndOrderFront(nil)
            NSApp.activate()
        }
        session.connect()
    }

    func open(address: String) -> Bool {
        guard let addr = Address.parse(address) else { return false }
        let store = ConnectionStore.shared
        let config = store.match(host: addr.host, port: addr.port, username: addr.username, bonjourName: nil)
            ?? { var c = SavedConnection(); c.host = addr.host; c.port = addr.port; c.username = addr.username; return c }()
        open(config)
        return true
    }

    func open(bonjour name: String) {
        let config = ConnectionStore.shared.match(host: "", port: 5900, username: "", bonjourName: name)
            ?? { var c = SavedConnection(); c.name = name; c.bonjourName = name; return c }()
        open(config)
    }

    @ObservationIgnored private var auxiliary: [SessionWindowController] = []

    /// Opens a window showing one display of an existing session.
    func openAuxiliary(session: Session, display: UInt32) -> SessionWindowController {
        let c = SessionWindowController(session: session, displayID: display)
        auxiliary.append(c)
        if let main = session.windowController?.window, let w = c.window {
            w.setFrameTopLeftPoint(NSPoint(x: main.frame.maxX + 20, y: main.frame.maxY))
        }
        return c
    }

    func closedAuxiliary(_ controller: SessionWindowController) {
        auxiliary.removeAll { $0 === controller }
    }

    func closed(_ controller: SessionWindowController) {
        controllers[controller.session.id] = nil
        if activeSession === controller.session { activeSession = nil }
    }

    var hasSessions: Bool { !controllers.isEmpty }
    var anySession: Session? { controllers.values.first?.session }
    var openSessions: [Session] {
        controllers.values.map(\.session).sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    func focus(_ session: Session) {
        guard let w = session.windowController?.window else { return }
        w.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func disconnectAll() { controllers.values.forEach { $0.session.disconnect() } }
}
