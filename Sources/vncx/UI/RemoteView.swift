// Copyright 2026 Ahimsa Labs
// SPDX-License-Identifier: Apache-2.0

import VNCCore
import AppKit
import MetalKit
import Carbon.HIToolbox

enum ScalingMode: String, Codable, CaseIterable, Identifiable {
    case fit, fillWidth, fillHeight, actual, remoteResize
    var id: String { rawValue }
    var label: String {
        switch self {
        case .fit: return "Scale to Fit"
        case .fillWidth: return "Fill Width"
        case .fillHeight: return "Fill Height"
        case .actual: return "Actual Size"
        case .remoteResize: return "Resize Remote"
        }
    }
    var symbol: String {
        switch self {
        case .fit: return "arrow.down.right.and.arrow.up.left"
        case .fillWidth: return "arrow.left.and.right"
        case .fillHeight: return "arrow.up.and.down"
        case .actual: return "1.magnifyingglass"
        case .remoteResize: return "rectangle.expand.vertical"
        }
    }
}

struct ViewLayout {
    var dst: CGRect          // where the image is drawn, in view points (top-left origin)
    var scale: CGFloat       // view points per framebuffer pixel
    var srcOrigin: CGPoint   // framebuffer pixel at dst.origin
}

/// Hosts the Metal-rendered remote desktop and translates local input into RFB events.
final class RemoteView: MTKView {
    weak var session: Session?
    private var renderer: Renderer?

    var framebuffer: Framebuffer? { didSet { if framebuffer !== oldValue { layoutChanged() } } }
    var scaling: ScalingMode = .fit { didSet { if scaling != oldValue { layoutChanged(); remoteResizeIfNeeded() } } }
    var viewOnly = false {
        didSet {
            guard viewOnly != oldValue else { return }
            if viewOnly { releaseAll() }
            window?.invalidateCursorRects(for: self)
            applyCursorIfInside()
        }
    }
    var smoothScaling = true { didSet { needsDisplay = true } }
    var remoteCursor: RemoteCursor? { didSet { rebuildCursor() } }

    var backgroundRGBA = SIMD4<Float>(0, 0, 0, 1)
    private var panFraction = CGPoint(x: 0.5, y: 0.5)

    private func updatePan(_ p: CGPoint) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let fx = min(max(p.x / bounds.width, 0), 1), fy = min(max(p.y / bounds.height, 0), 1)
        guard abs(fx - panFraction.x) > 0.0001 || abs(fy - panFraction.y) > 0.0001 else { return }
        panFraction = CGPoint(x: fx, y: fy)
        if isPanning { needsDisplay = true }
    }
    private var buttons: UInt8 = 0
    private var pressedKeys: [UInt16: UInt32] = [:]
    private var pressedModifiers: [UInt16: UInt32] = [:]
    private var scrollAccum = CGSize.zero
    private var nsCursor: NSCursor = .arrow
    private var lastPointer: (Int, Int)?
    private var capsLockOn = false

    init(session: Session) {
        self.session = session
        let device = Framebuffer.device ?? MTLCreateSystemDefaultDevice()
        super.init(frame: .zero, device: device)
        colorPixelFormat = .bgra8Unorm
        framebufferOnly = true
        isPaused = true
        enableSetNeedsDisplay = true
        autoResizeDrawable = true
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        if let layer = layer as? CAMetalLayer {
            layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
            layer.isOpaque = true
        }
        if let device {
            renderer = Renderer(device: device, pixelFormat: colorPixelFormat)
            delegate = renderer
        }
        registerForDraggedTypes([.fileURL, .string])
    }

    // MARK: Drag and drop

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !viewOnly, session?.phase == .connected else { return [] }
        let pb = sender.draggingPasteboard
        if pb.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) { return .copy }
        if pb.canReadObject(forClasses: [NSString.self], options: nil) { return .copy }
        return []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let session else { return false }
        let pb = sender.draggingPasteboard
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            session.handleDroppedFiles(urls)
            return true
        }
        if let text = pb.string(forType: .string), !text.isEmpty {
            window?.makeFirstResponder(self)
            session.handleDroppedText(text, type: NSEvent.modifierFlags.contains(.option))
            return true
        }
        return false
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    var backingScale: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }

    // MARK: Layout

    /// Optional sub-rectangle of the framebuffer to show (one display of a multi-screen remote).
    var crop: CGRect? { didSet { if crop != oldValue { layoutChanged() } } }

    /// Pinch zoom on top of the scaling mode (1 = no zoom).
    private(set) var zoom: CGFloat = 1 { didSet { if zoom != oldValue { layoutChanged(); onZoomChange?(zoom) } } }
    var onZoomChange: ((CGFloat) -> Void)?
    static let maxZoom: CGFloat = 8

    /// The framebuffer region being shown.
    var region: CGRect {
        guard let fb = framebuffer else { return .zero }
        let full = CGRect(x: 0, y: 0, width: fb.width, height: fb.height)
        return crop?.intersection(full).nonEmpty ?? full
    }

    func currentLayout() -> ViewLayout {
        guard framebuffer != nil else { return ViewLayout(dst: bounds, scale: 1, srcOrigin: .zero) }
        let r = region
        let fw = r.width, fh = r.height
        let bw = max(bounds.width, 1), bh = max(bounds.height, 1)
        let bs = backingScale
        var s: CGFloat
        // If we're within a pixel or two of an exact 1:1 or 2:1 device-pixel mapping, snap to it so text stays
        // sharp (window sizes are whole points, so odd remote sizes otherwise land at 0.4995 and blur).
        func snapped(_ scale: CGFloat) -> CGFloat {
            let devicePixelsPerFBPixel = scale * bs
            let nearest = devicePixelsPerFBPixel.rounded()
            return nearest >= 1 && abs(devicePixelsPerFBPixel - nearest) * max(fw, fh) < 2 ? nearest / bs : scale
        }
        switch scaling {
        case .fit, .remoteResize:
            s = snapped(min(bw / fw, bh / fh))
        case .fillWidth:
            s = snapped(bw / fw)
        case .fillHeight:
            s = snapped(bh / fh)
        case .actual:
            s = 1 / bs
        }
        s *= zoom
        // Each axis either fits (centered) or overflows, in which case the view follows the pointer:
        // pointer at 30% across the view shows the region 30% across the framebuffer.
        let w = fw * s, h = fh * s
        var dst = CGRect.zero, src = r.origin
        if w <= bw + 0.5 {
            dst.origin.x = ((bw - w) / 2 * bs).rounded() / bs; dst.size.width = w
        } else {
            dst.size.width = bw; src.x += ((fw - bw / s) * panFraction.x).rounded()
        }
        if h <= bh + 0.5 {
            dst.origin.y = ((bh - h) / 2 * bs).rounded() / bs; dst.size.height = h
        } else {
            dst.size.height = bh; src.y += ((fh - bh / s) * panFraction.y).rounded()
        }
        return ViewLayout(dst: dst, scale: s, srcOrigin: src)
    }

    /// Whether the image currently overflows the view (so pointer movement pans).
    private var isPanning: Bool {
        let l = currentLayout(), r = region
        return r.width * l.scale > bounds.width + 0.5 || r.height * l.scale > bounds.height + 0.5
    }

    func setZoom(_ z: CGFloat) { zoom = min(max(z, 1), Self.maxZoom) }

    override func magnify(with event: NSEvent) {
        updatePan(convert(event.locationInWindow, from: nil))
        var z = zoom * (1 + event.magnification)
        if z < 1.03 { z = 1 } // settle exactly at 1 so the unzoomed view stays pixel-snapped
        setZoom(z)
    }

    /// Two-finger double tap: zoom to 1:1 device pixels (or 2x if already at least that), or back out.
    override func smartMagnify(with event: NSEvent) {
        updatePan(convert(event.locationInWindow, from: nil))
        if zoom > 1 { setZoom(1); return }
        let base = currentLayout().scale
        let pixelExact = (1 / backingScale) / base
        setZoom(pixelExact > 1.2 ? pixelExact : 2)
    }

    /// The window content size that shows the framebuffer pixel-for-pixel, capped to the screen.
    func idealContentSize(for pixels: CGSize, on screen: NSScreen?) -> CGSize {
        let bs = screen?.backingScaleFactor ?? backingScale
        var size = CGSize(width: pixels.width / bs, height: pixels.height / bs)
        // Low-resolution remotes look tiny at 1:1 on Retina; use 1 point per pixel for those.
        if let screen, size.width < screen.visibleFrame.width * 0.5 {
            size = pixels
        }
        if let visible = screen?.visibleFrame {
            let maxW = visible.width, maxH = visible.height - 60 // leave room for title bar / toolbar
            let s = min(1, maxW / size.width, maxH / size.height)
            size = CGSize(width: (size.width * s).rounded(.down), height: (size.height * s).rounded(.down))
        }
        return size
    }

    private func layoutChanged() {
        rebuildCursor()
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutChanged()
        if !inLiveResize { remoteResizeIfNeeded() }
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        remoteResizeIfNeeded()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        layoutChanged()
    }

    private var lastRequestedRemoteSize: CGSize?
    func remoteResizeIfNeeded() {
        // Resizing a multi-monitor remote would collapse its layout into one screen.
        guard scaling == .remoteResize, let session, session.displays.count <= 1, crop == nil,
              bounds.width > 50, bounds.height > 50 else { return }
        let scale: CGFloat = session.remoteResizeUsesRetina ? backingScale : 1
        let size = CGSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
        guard size != lastRequestedRemoteSize else { return }
        if let fb = framebuffer, CGFloat(fb.width) == size.width, CGFloat(fb.height) == size.height { return }
        lastRequestedRemoteSize = size
        session.requestRemoteSize(size)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self)
        }
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        if let window {
            NotificationCenter.default.addObserver(self, selector: #selector(windowResignedKey), name: NSWindow.didResignKeyNotification, object: window)
        }
    }

    @objc private func windowResignedKey(_ note: Notification) { releaseAll() }

    // MARK: Cursor

    /// Shown when the server reports an empty (0×0) cursor, so the pointer never disappears entirely.
    private static let dotCursor: NSCursor = {
        let size = NSSize(width: 7, height: 7)
        let img = NSImage(size: size, flipped: false) { r in
            NSColor.black.setFill(); NSBezierPath(ovalIn: r.insetBy(dx: 0.5, dy: 0.5)).fill()
            NSColor.white.setFill(); NSBezierPath(ovalIn: r.insetBy(dx: 2, dy: 2)).fill()
            return true
        }
        return NSCursor(image: img, hotSpot: NSPoint(x: 3.5, y: 3.5))
    }()

    private var hasRemoteCursorInfo = false

    /// Cursor to show when the server never sends shapes (it may be drawing the cursor into the picture).
    var fallbackCursor: LocalCursorMode = .arrow { didSet { if fallbackCursor != oldValue { rebuildCursor() } } }

    private static let hiddenCursor: NSCursor = {
        let img = NSImage(size: NSSize(width: 1, height: 1), flipped: false) { _ in true }
        return NSCursor(image: img, hotSpot: .zero)
    }()

    private func rebuildCursor() {
        if let c = remoteCursor {
            // Draw the cursor at the same scale as the desktop, within sane bounds.
            let s = min(max(currentLayout().scale, 0.5), 2)
            let size = NSSize(width: CGFloat(c.image.width) * s, height: CGFloat(c.image.height) * s)
            let img = NSImage(cgImage: c.image, size: size)
            nsCursor = NSCursor(image: img, hotSpot: NSPoint(x: c.hotspot.x * s, y: c.hotspot.y * s))
        } else {
            if hasRemoteCursorInfo {
                nsCursor = Self.dotCursor // the server explicitly hid its cursor
            } else {
                switch fallbackCursor {
                case .arrow: nsCursor = .arrow
                case .dot: nsCursor = Self.dotCursor
                case .hidden: nsCursor = Self.hiddenCursor
                }
            }
        }
        window?.invalidateCursorRects(for: self)
        applyCursorIfInside()
    }

    /// Called when the server sends a cursor shape (nil means the server hid the cursor).
    func setRemoteCursor(_ cursor: RemoteCursor?) {
        hasRemoteCursorInfo = true
        remoteCursor = cursor
    }

    private var activeCursor: NSCursor { viewOnly ? .arrow : nsCursor }

    /// Cursor rects alone aren't enough: SwiftUI's hosting view also manages the cursor, and a shape change while
    /// the mouse is still never triggers a cursor-rect update. So set it directly whenever the mouse is over us.
    private func applyCursorIfInside() {
        guard let window, window.isKeyWindow else { return }
        let p = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        if bounds.contains(p) { activeCursor.set() }
    }

    override func resetCursorRects() {
        addCursorRect(visibleRect, cursor: activeCursor)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect, .cursorUpdate],
                                       owner: self, userInfo: nil))
    }

    override func cursorUpdate(with event: NSEvent) { activeCursor.set() }

    // MARK: Mouse

    private func framebufferPoint(_ event: NSEvent) -> (Int, Int)? {
        guard let fb = framebuffer else { return nil }
        let p = convert(event.locationInWindow, from: nil)
        updatePan(p)
        let l = currentLayout(), r = region
        let x = Int(((p.x - l.dst.minX) / l.scale + l.srcOrigin.x).rounded(.down))
        let y = Int(((p.y - l.dst.minY) / l.scale + l.srcOrigin.y).rounded(.down))
        // Clamp to the visible region so a cropped display never sends the pointer onto another one.
        return (min(max(x, Int(r.minX)), min(Int(r.maxX), fb.width) - 1),
                min(max(y, Int(r.minY)), min(Int(r.maxY), fb.height) - 1))
    }

    private func sendPointer(_ event: NSEvent) {
        activeCursor.set()
        guard let pt = framebufferPoint(event) else { return }
        guard !viewOnly, let session else { return }
        lastPointer = pt
        session.client?.sendPointer(x: pt.0, y: pt.1, buttons: buttons)
    }

    private func setButton(_ bit: UInt8, down: Bool, _ event: NSEvent) {
        if down { buttons |= bit } else { buttons &= ~bit }
        sendPointer(event)
    }

    override func mouseMoved(with event: NSEvent) { sendPointer(event) }
    override func mouseDragged(with event: NSEvent) { sendPointer(event) }
    override func rightMouseDragged(with event: NSEvent) { sendPointer(event) }
    override func otherMouseDragged(with event: NSEvent) { sendPointer(event) }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        setButton(1, down: true, event)
    }
    override func mouseUp(with event: NSEvent) { setButton(1, down: false, event) }
    override func rightMouseDown(with event: NSEvent) { setButton(4, down: true, event) }
    override func rightMouseUp(with event: NSEvent) { setButton(4, down: false, event) }
    override func otherMouseDown(with event: NSEvent) { if event.buttonNumber == 2 { setButton(2, down: true, event) } }
    override func otherMouseUp(with event: NSEvent) { if event.buttonNumber == 2 { setButton(2, down: false, event) } }

    override func scrollWheel(with event: NSEvent) {
        guard !viewOnly, let session, let pt = framebufferPoint(event) else { return }
        var ticksY = 0, ticksX = 0
        if event.hasPreciseScrollingDeltas {
            // Trackpads report points; convert to wheel clicks with an accumulator so slow swipes still scroll.
            let step: CGFloat = 16
            scrollAccum.height += event.scrollingDeltaY
            scrollAccum.width += event.scrollingDeltaX
            ticksY = Int(scrollAccum.height / step); scrollAccum.height -= CGFloat(ticksY) * step
            ticksX = Int(scrollAccum.width / step); scrollAccum.width -= CGFloat(ticksX) * step
            if event.phase == .ended || event.momentumPhase == .ended { scrollAccum = .zero }
        } else {
            ticksY = event.scrollingDeltaY == 0 ? 0 : (event.scrollingDeltaY > 0 ? 1 : -1) * max(1, Int(abs(event.scrollingDeltaY).rounded()))
            ticksX = event.scrollingDeltaX == 0 ? 0 : (event.scrollingDeltaX > 0 ? 1 : -1) * max(1, Int(abs(event.scrollingDeltaX).rounded()))
        }
        func click(_ bit: UInt8, _ n: Int) {
            for _ in 0..<min(n, 20) {
                session.client?.sendPointer(x: pt.0, y: pt.1, buttons: buttons | bit)
                session.client?.sendPointer(x: pt.0, y: pt.1, buttons: buttons)
            }
        }
        if ticksY > 0 { click(8, ticksY) } else if ticksY < 0 { click(16, -ticksY) }
        if ticksX > 0 { click(32, ticksX) } else if ticksX < 0 { click(64, -ticksX) }
    }

    // MARK: Keyboard

    private var commandMapping: CommandKeyMapping { Preferences.shared.commandKey }

    override func keyDown(with event: NSEvent) {
        guard !viewOnly, let client = session?.client else { return }
        guard let sym = pressedKeys[event.keyCode] ?? KeyMapping.keysym(for: event) else { return }
        pressedKeys[event.keyCode] = sym
        client.sendKey(sym, down: true)
    }

    override func keyUp(with event: NSEvent) {
        guard let client = session?.client else { return }
        if let sym = pressedKeys.removeValue(forKey: event.keyCode) {
            client.sendKey(sym, down: false)
        }
        // Command+key on macOS never delivers keyUp for the letter; the release is synthesized in flagsChanged.
    }

    override func flagsChanged(with event: NSEvent) {
        guard !viewOnly, let client = session?.client else { return }
        if Int(event.keyCode) == kVK_CapsLock {
            let on = event.modifierFlags.contains(.capsLock)
            if on != capsLockOn {
                capsLockOn = on
                client.sendKey(KeyMapping.Modifier.capsLock, down: true)
                client.sendKey(KeyMapping.Modifier.capsLock, down: false)
            }
            return
        }
        guard let sym = KeyMapping.modifierKeysym(event.keyCode, commandMapping: commandMapping) else { return }
        if let held = pressedModifiers.removeValue(forKey: event.keyCode) {
            client.sendKey(held, down: false)
            if Int(event.keyCode) == kVK_Command || Int(event.keyCode) == kVK_RightCommand {
                // Keys pressed with Command don't get keyUp events from AppKit; release them now.
                for (code, s) in pressedKeys { client.sendKey(s, down: false); pressedKeys[code] = nil }
            }
        } else {
            pressedModifiers[event.keyCode] = sym
            client.sendKey(sym, down: true)
        }
    }

    /// Command shortcuts normally go to the menu bar. Send them to the remote unless they are reserved locally.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, !viewOnly, session?.client != nil,
              Preferences.shared.sendCommandShortcuts, event.type == .keyDown else {
            return super.performKeyEquivalent(with: event)
        }
        if isReservedShortcut(event) { return super.performKeyEquivalent(with: event) }
        keyDown(with: event)
        return true
    }

    private func isReservedShortcut(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Control-Command shortcuts belong to vncx (view modes, full screen, disconnect).
        if flags.contains(.command) && flags.contains(.control) { return true }
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if flags.contains(.command) && (key == "q" || key == "h") && !flags.contains(.option) { return true }
        return false
    }

    /// Releases all keys and buttons so nothing stays stuck on the remote side after losing focus.
    func releaseAll() {
        guard let client = session?.client else { pressedKeys.removeAll(); pressedModifiers.removeAll(); return }
        for (_, s) in pressedKeys { client.sendKey(s, down: false) }
        for (_, s) in pressedModifiers { client.sendKey(s, down: false) }
        pressedKeys.removeAll(); pressedModifiers.removeAll()
        if buttons != 0, let p = lastPointer {
            buttons = 0
            client.sendPointer(x: p.0, y: p.1, buttons: 0)
        }
    }

    /// Types a string on the remote machine by sending key presses for each character.
    func type(_ text: String) {
        guard !viewOnly, let client = session?.client else { return }
        for scalar in text.unicodeScalars {
            let sym = scalar == "\n" ? 0xff0d : KeyMapping.keysym(for: scalar)
            client.sendKey(sym, down: true)
            client.sendKey(sym, down: false)
        }
    }

    func sendKeyCombo(_ syms: [UInt32]) {
        guard !viewOnly, let client = session?.client else { return }
        syms.forEach { client.sendKey($0, down: true) }
        syms.reversed().forEach { client.sendKey($0, down: false) }
    }
}

extension CGRect {
    var nonEmpty: CGRect? { isEmpty || isNull ? nil : self }
}
