// Draws the app icon and writes Resources/AppIcon.icns.
// Run from the project root: swift scripts/make_icon.swift
import AppKit

let canvas: CGFloat = 1024

func render(size: CGFloat) -> Data {
    let scale = size / canvas
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: scale, y: scale)
    drawIcon(in: ctx)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

func drawIcon(in ctx: CGContext) {
    // macOS icon grid: an 824 pt rounded square centered on the 1024 canvas.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0x000000, 0.35))
    ctx.addPath(shape)
    ctx.setFillColor(color(0x3A2E8C))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let background = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
        colors: [color(0xFF9F43), color(0xEE5A6F), color(0x6C3FD1)] as CFArray,
        locations: [0, 0.5, 1]
    )!
    ctx.drawLinearGradient(background, start: CGPoint(x: 150, y: 924), end: CGPoint(x: 874, y: 100), options: [])
    ctx.restoreGState()

    // Live Photo mark: center dot, solid ring, and a ring of small dots.
    let center = CGPoint(x: 512, y: 500)
    let white = color(0xFFFFFF)
    ctx.setFillColor(white)
    ctx.setStrokeColor(white)

    ctx.fillEllipse(in: CGRect(x: center.x - 92, y: center.y - 92, width: 184, height: 184))

    ctx.setLineWidth(36)
    ctx.strokeEllipse(in: CGRect(x: center.x - 180, y: center.y - 180, width: 360, height: 360))

    let dotCount = 36
    let dotRing: CGFloat = 268
    for i in 0..<dotCount {
        let angle = CGFloat(i) / CGFloat(dotCount) * 2 * .pi
        let p = CGPoint(x: center.x + cos(angle) * dotRing, y: center.y + sin(angle) * dotRing)
        // Leave a gap at the top right where the sparkle sits.
        let degrees = angle * 180 / .pi
        if degrees > 12 && degrees < 72 { continue }
        ctx.fillEllipse(in: CGRect(x: p.x - 13, y: p.y - 13, width: 26, height: 26))
    }

    // Repair sparkles at the top right.
    drawSparkle(in: ctx, at: CGPoint(x: 712, y: 712), radius: 118, fill: color(0xFFF3B0))
    drawSparkle(in: ctx, at: CGPoint(x: 806, y: 600), radius: 48, fill: color(0xFFFFFF))
}

/// Four-point star with curved sides.
func drawSparkle(in ctx: CGContext, at c: CGPoint, radius r: CGFloat, fill: CGColor) {
    let waist = r * 0.18
    let path = CGMutablePath()
    path.move(to: CGPoint(x: c.x, y: c.y + r))
    path.addQuadCurve(to: CGPoint(x: c.x + r, y: c.y), control: CGPoint(x: c.x + waist, y: c.y + waist))
    path.addQuadCurve(to: CGPoint(x: c.x, y: c.y - r), control: CGPoint(x: c.x + waist, y: c.y - waist))
    path.addQuadCurve(to: CGPoint(x: c.x - r, y: c.y), control: CGPoint(x: c.x - waist, y: c.y - waist))
    path.addQuadCurve(to: CGPoint(x: c.x, y: c.y + r), control: CGPoint(x: c.x - waist, y: c.y + waist))
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 18, color: color(0xFFFFFF, 0.6))
    ctx.addPath(path)
    ctx.setFillColor(fill)
    ctx.fillPath()
    ctx.restoreGState()
}

let fm = FileManager.default
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)

for points in [16, 32, 128, 256, 512] {
    for multiplier in [1, 2] {
        let suffix = multiplier == 2 ? "@2x" : ""
        let file = iconset.appendingPathComponent("icon_\(points)x\(points)\(suffix).png")
        try! render(size: CGFloat(points * multiplier)).write(to: file)
    }
}
try! render(size: 1024).write(to: URL(fileURLWithPath: "Resources/AppIcon.png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try! iconutil.run()
iconutil.waitUntilExit()
print(iconutil.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
