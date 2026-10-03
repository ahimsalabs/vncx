// Copyright 2026 Ahimsa Labs
// SPDX-License-Identifier: Apache-2.0

// Renders the vncx app icon into an .iconset directory: swift icon.swift <out.iconset> [release|dev]
// The dev variant has an orange background and a DEV badge so it's easy to tell apart in the Dock and Finder.
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
let isDev = CommandLine.arguments.count > 2 && CommandLine.arguments[2] == "dev"
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
    let bgColors = isDev
        ? [NSColor(calibratedRed: 0.98, green: 0.58, blue: 0.16, alpha: 1), NSColor(calibratedRed: 0.80, green: 0.30, blue: 0.05, alpha: 1)]
        : [NSColor(calibratedRed: 0.20, green: 0.24, blue: 0.36, alpha: 1), NSColor(calibratedRed: 0.08, green: 0.09, blue: 0.15, alpha: 1)]
    NSGradient(colors: bgColors)!.draw(in: bg, angle: -90)

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

    if isDev {
        // "DEV" pill across the bottom of the squircle.
        let pill = NSRect(x: 292, y: 118, width: 440, height: 150)
        NSColor(calibratedWhite: 0.08, alpha: 0.92).setFill()
        NSBezierPath(roundedRect: pill, xRadius: 75, yRadius: 75).fill()
        let text = NSAttributedString(string: "DEV", attributes: [
            .font: NSFont.systemFont(ofSize: 112, weight: .heavy),
            .foregroundColor: NSColor(calibratedRed: 1.0, green: 0.72, blue: 0.30, alpha: 1),
            .kern: 8,
        ])
        let size = text.size()
        text.draw(at: NSPoint(x: pill.midX - size.width / 2 + 4, y: pill.midY - size.height / 2 + 4))
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try! render(size).write(to: out.appendingPathComponent("icon_\(size)x\(size).png"))
    try! render(size * 2).write(to: out.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
