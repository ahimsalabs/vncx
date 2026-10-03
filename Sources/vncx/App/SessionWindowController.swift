import VNCCore
import AppKit
import SwiftUI

/// Owns a session's NSWindow. We manage these windows in AppKit (rather than a SwiftUI WindowGroup) because a VNC
/// viewer needs precise control over content size, aspect ratio, and full screen behavior.
final class SessionWindowController: NSWindowController, NSWindowDelegate {
    let session: Session

    init(session: Session) {
        self.session = session
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

        let host = NSHostingController(rootView: SessionView(session: session))
        host.sizingOptions = []
        host.sceneBridgingOptions = [.toolbars, .title]
        window.contentViewController = host
        window.setContentSize(NSSize(width: 960, height: 600))
        window.center()
        super.init(window: window)
        window.delegate = self
        session.windowController = self
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
        guard let window, let fb = session.framebuffer else { return }
        switch session.scaling {
        case .fit:
            window.contentAspectRatio = NSSize(width: fb.width, height: fb.height)
            if resizeWindow && !isFullScreen { fitWindowToAspect() }
        case .actual, .remoteResize:
            window.contentResizeIncrements = NSSize(width: 1, height: 1) // clears the aspect ratio constraint
            if resizeWindow && !isFullScreen && session.scaling == .actual { resizeToIdeal() }
        }
    }

    private func resizeToIdeal() {
        guard let window, let fb = session.framebuffer, let view = session.view, !isFullScreen else { return }
        let size = view.idealContentSize(for: fb, on: window.screen ?? NSScreen.main)
        setContentSize(size)
    }

    private func fitWindowToAspect() {
        guard let window, let fb = session.framebuffer else { return }
        let current = window.contentRect(forFrameRect: window.frame).size
        let aspect = CGFloat(fb.width) / CGFloat(fb.height)
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
        session.disconnect()
        SessionManager.shared.closed(self)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        SessionManager.shared.activeSession = session
        session.syncClipboardToRemote()
    }

    func windowDidResignKey(_ notification: Notification) {
        if SessionManager.shared.activeSession === session { SessionManager.shared.activeSession = nil }
    }

    func windowDidEnterFullScreen(_ notification: Notification) { session.view?.remoteResizeIfNeeded() }
    func windowDidExitFullScreen(_ notification: Notification) {
        applyScaling(resizeWindow: false)
        session.view?.remoteResizeIfNeeded()
    }
}

/// Tracks open session windows and which one is active (for menu commands).
@Observable
final class SessionManager {
    static let shared = SessionManager()
    private var controllers: [UUID: SessionWindowController] = [:]
    var activeSession: Session?

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
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
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

    func closed(_ controller: SessionWindowController) {
        controllers[controller.session.id] = nil
        if activeSession === controller.session { activeSession = nil }
    }

    var hasSessions: Bool { !controllers.isEmpty }
}
