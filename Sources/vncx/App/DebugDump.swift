import VNCCore
import AppKit
import Metal
import UniformTypeIdentifiers
import ImageIO
import SwiftUI

/// Development aid: when VNCX_DEBUG_DIR is set, `kill -USR1 <pid>` writes the app's window/session state, a
/// snapshot of each window's chrome, and an offscreen render of each remote view into that directory.
enum DebugDump {
    private static var source: DispatchSourceSignal?

    static func installIfRequested() {
        guard let dir = ProcessInfo.processInfo.environment["VNCX_DEBUG_DIR"] else { return }
        signal(SIGUSR1, SIG_IGN)
        let s = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        s.setEventHandler { MainActor.assumeIsolated { dump(to: URL(fileURLWithPath: dir)) } }
        s.resume()
        source = s
    }

    @MainActor static func dump(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var report = ""
        for (i, window) in NSApp.windows.enumerated() where window.isVisible {
            report += "window \(i): \"\(window.title)\" subtitle=\"\(window.subtitle)\" frame=\(window.frame) content=\(window.contentLayoutRect.size) key=\(window.isKeyWindow) aspect=\(window.contentAspectRatio) fullscreen=\(window.styleMask.contains(.fullScreen))\n"
            report += "  firstResponder=\(String(describing: window.firstResponder.map { type(of: $0) }))\n"
            if let frameView = window.contentView?.superview {
                if let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) {
                    frameView.cacheDisplay(in: frameView.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("window-\(i).png"))
                }
            }
            if let remote = findRemoteView(in: window.contentView) {
                let l = remote.currentLayout()
                report += "  remote: fb=\(remote.framebuffer.map { "\($0.width)x\($0.height)" } ?? "nil") bounds=\(remote.bounds.size) drawable=\(remote.drawableSize) scaling=\(remote.scaling) layout.dst=\(l.dst) scale=\(l.scale) src=\(l.srcOrigin)\n"
                if let s = remote.session {
                    report += "  session: phase=\(s.phase) title=\"\(s.title)\" subtitle=\"\(s.subtitle)\" prompt=\(s.credentialPrompt != nil)\n"
                }
                if let img = remote.renderOffscreen() { write(img, dir.appendingPathComponent("render-\(i).png")) }
                // Also exercise the zoom path: 2x with the pointer at the view's center.
                let z = remote.zoom
                remote.setZoom(2)
                let lz = remote.currentLayout()
                report += "  zoom2: dst=\(lz.dst) scale=\(lz.scale) src=\(lz.srcOrigin)\n"
                if let img = remote.renderOffscreen() { write(img, dir.appendingPathComponent("render-\(i)-zoom2.png")) }
                remote.setZoom(z)
            }
        }
        // SwiftUI content isn't captured by cacheDisplay, so render the launcher cards directly.
        let store = ConnectionStore.shared
        let cards = HStack(alignment: .top, spacing: 18) {
            ForEach(store.sorted) { c in ConnectionCard(connection: c, thumbnail: store.thumbnail(c.id)).frame(width: 240) }
        }.padding(20).background(Color.white)
        let renderer = ImageRenderer(content: cards)
        renderer.scale = 2
        if let img = renderer.cgImage { write(img, dir.appendingPathComponent("cards.png")) }
        try? report.write(to: dir.appendingPathComponent("state.txt"), atomically: true, encoding: .utf8)
    }

    private static func findRemoteView(in view: NSView?) -> RemoteView? {
        guard let view else { return nil }
        if let r = view as? RemoteView { return r }
        for sub in view.subviews { if let r = findRemoteView(in: sub) { return r } }
        return nil
    }

    private static func write(_ image: CGImage, _ url: URL) {
        guard let d = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(d, image, nil)
        CGImageDestinationFinalize(d)
    }
}

extension RemoteView {
    /// Renders the current frame into an offscreen texture of drawable size (same shader path as on screen).
    func renderOffscreen() -> CGImage? {
        guard let device, let renderer = delegate as? Renderer else { return nil }
        let w = Int(drawableSize.width), h = Int(drawableSize.height)
        guard w > 0, h > 0 else { return nil }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .shared
        guard let target = device.makeTexture(descriptor: desc) else { return nil }
        renderer.render(view: self, into: target)
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        target.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue)
        return ctx?.makeImage()
    }
}
