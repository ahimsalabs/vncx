// Renders the vncx app icon into an .iconset directory: swift icon.swift <out.iconset>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px) / 1024
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: s, y: s)

    // Squircle-ish background
    let bg = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
    NSGradient(colors: [NSColor(calibratedRed: 0.20, green: 0.24, blue: 0.36, alpha: 1),
                        NSColor(calibratedRed: 0.08, green: 0.09, blue: 0.15, alpha: 1)])!.draw(in: bg, angle: -90)

    // Display
    let screen = NSRect(x: 220, y: 330, width: 584, height: 400)
    NSColor(calibratedWhite: 0.92, alpha: 1).setFill()
    NSBezierPath(roundedRect: screen.insetBy(dx: -18, dy: -18), xRadius: 40, yRadius: 40).fill()
    NSGradient(colors: [NSColor(calibratedRed: 0.25, green: 0.62, blue: 1.0, alpha: 1),
                        NSColor(calibratedRed: 0.42, green: 0.32, blue: 0.95, alpha: 1)])!
        .draw(in: NSBezierPath(roundedRect: screen, xRadius: 22, yRadius: 22), angle: -60)
    // Stand
    NSColor(calibratedWhite: 0.85, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 452, y: 236, width: 120, height: 90), xRadius: 10, yRadius: 10).fill()
    NSBezierPath(roundedRect: NSRect(x: 362, y: 210, width: 300, height: 38), xRadius: 19, yRadius: 19).fill()

    // Cursor arrow
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 560, y: 610))
    arrow.line(to: NSPoint(x: 560, y: 390))
    arrow.line(to: NSPoint(x: 612, y: 440))
    arrow.line(to: NSPoint(x: 650, y: 362))
    arrow.line(to: NSPoint(x: 684, y: 378))
    arrow.line(to: NSPoint(x: 646, y: 456))
    arrow.line(to: NSPoint(x: 716, y: 456))
    arrow.close()
    NSColor.white.setFill(); arrow.fill()
    NSColor(calibratedWhite: 0.1, alpha: 1).setStroke(); arrow.lineWidth = 14; arrow.lineJoinStyle = .round; arrow.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try! render(size).write(to: out.appendingPathComponent("icon_\(size)x\(size).png"))
    try! render(size * 2).write(to: out.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
