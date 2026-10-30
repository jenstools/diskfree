// Renders the DiskFree app icon into Resources/AppIcon.icns.
//
//   swift Resources/make-icon.swift
//
// A disk-usage ring on a teal-to-green tile: the bright arc is the space DiskFree gets back.

import AppKit

func render(size: CGFloat) -> NSImage {
    NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
        let s = size / 1024
        let tile = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
        let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185 * s, yRadius: 185 * s)

        // Drop shadow under the tile, as on stock macOS icons.
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
        shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
        shadow.shadowBlurRadius = 24 * s
        shadow.set()
        NSColor.black.setFill()
        tilePath.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        tilePath.addClip()
        NSGradient(colors: [NSColor(red: 0.04, green: 0.30, blue: 0.36, alpha: 1),
                            NSColor(red: 0.07, green: 0.55, blue: 0.45, alpha: 1)])!
            .draw(in: tile, angle: 70)
        // Soft highlight on the top half.
        NSGradient(colors: [NSColor.white.withAlphaComponent(0.16), NSColor.white.withAlphaComponent(0)])!
            .draw(in: NSRect(x: tile.minX, y: tile.midY, width: tile.width, height: tile.height / 2), angle: -90)
        NSGraphicsContext.restoreGraphicsState()

        let center = NSPoint(x: 512 * s, y: 500 * s)
        let radius = 255 * s
        let width = 92 * s

        func arc(from start: CGFloat, to end: CGFloat, color: NSColor) {
            let path = NSBezierPath()
            path.appendArc(withCenter: center, radius: radius, startAngle: start, endAngle: end, clockwise: true)
            path.lineWidth = width
            path.lineCapStyle = .round
            color.setStroke()
            path.stroke()
        }
        // Track, used space, freed space.
        arc(from: 90, to: -270, color: NSColor.white.withAlphaComponent(0.18))
        arc(from: 90, to: -150, color: NSColor.white.withAlphaComponent(0.95))
        arc(from: -178, to: -262, color: NSColor(red: 0.55, green: 1.0, blue: 0.72, alpha: 1))

        // Four-point sparkle in the middle of the ring.
        func sparkle(at p: NSPoint, size r: CGFloat) {
            let path = NSBezierPath()
            let k = r * 0.22
            path.move(to: NSPoint(x: p.x, y: p.y + r))
            path.curve(to: NSPoint(x: p.x + r, y: p.y), controlPoint1: NSPoint(x: p.x + k, y: p.y + k), controlPoint2: NSPoint(x: p.x + k, y: p.y + k))
            path.curve(to: NSPoint(x: p.x, y: p.y - r), controlPoint1: NSPoint(x: p.x + k, y: p.y - k), controlPoint2: NSPoint(x: p.x + k, y: p.y - k))
            path.curve(to: NSPoint(x: p.x - r, y: p.y), controlPoint1: NSPoint(x: p.x - k, y: p.y - k), controlPoint2: NSPoint(x: p.x - k, y: p.y - k))
            path.curve(to: NSPoint(x: p.x, y: p.y + r), controlPoint1: NSPoint(x: p.x - k, y: p.y + k), controlPoint2: NSPoint(x: p.x - k, y: p.y + k))
            NSColor.white.setFill()
            path.fill()
        }
        sparkle(at: NSPoint(x: center.x - 18 * s, y: center.y - 10 * s), size: 120 * s)
        sparkle(at: NSPoint(x: center.x + 95 * s, y: center.y + 92 * s), size: 46 * s)
        return true
    }
}

func png(_ image: NSImage, pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let resources = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        try! png(render(size: CGFloat(pixels)), pixels: pixels).write(to: iconset.appendingPathComponent(name))
    }
}
try! png(render(size: 1024), pixels: 1024).write(to: resources.appendingPathComponent("AppIcon.png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", resources.appendingPathComponent("AppIcon.icns").path]
try! iconutil.run()
iconutil.waitUntilExit()
print(iconutil.terminationStatus == 0 ? "wrote Resources/AppIcon.icns" : "iconutil failed")
