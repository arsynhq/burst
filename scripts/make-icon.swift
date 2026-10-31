// Renders Resources/AppIcon.icns: a graphite tile holding a small fanned pile of shots.
// Usage: swift scripts/make-icon.swift   (from the project root)
import AppKit

let canvas: CGFloat = 1024
let image = NSImage(size: NSSize(width: canvas, height: canvas), flipped: false) { _ in
    let ctx = NSGraphicsContext.current!.cgContext
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: 186, yRadius: 186)

    NSGraphicsContext.saveGraphicsState()
    let drop = NSShadow()
    drop.shadowColor = NSColor.black.withAlphaComponent(0.35)
    drop.shadowBlurRadius = 24
    drop.shadowOffset = NSSize(width: 0, height: -10)
    drop.set()
    NSColor(white: 0.16, alpha: 1).setFill()
    tilePath.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    tilePath.addClip()
    NSGradient(starting: NSColor(srgbRed: 0.26, green: 0.27, blue: 0.29, alpha: 1),
               ending: NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1))!.draw(in: tile, angle: -90)

    func card(_ angle: CGFloat, _ dx: CGFloat, _ dy: CGFloat, front: Bool, tint: NSColor) {
        ctx.saveGState()
        ctx.translateBy(x: 512 + dx, y: 500 + dy)
        ctx.rotate(by: angle * .pi / 180)
        let rect = CGRect(x: -250, y: -175, width: 500, height: 350)
        let path = NSBezierPath(roundedRect: rect, xRadius: 34, yRadius: 34)
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
        shadow.shadowBlurRadius = 30
        shadow.shadowOffset = NSSize(width: 0, height: -14)
        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        tint.setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
        if front {
            path.addClip()
            NSColor(srgbRed: 0.04, green: 0.52, blue: 1, alpha: 1).setFill()
            CGRect(x: rect.minX, y: rect.maxY - 96, width: rect.width, height: 96).fill()
            NSColor(white: 0.84, alpha: 1).setFill()
            for (i, w) in [360.0, 290, 380, 220].enumerated() {
                NSBezierPath(roundedRect: CGRect(x: rect.minX + 44, y: rect.maxY - 150 - CGFloat(i) * 46, width: w, height: 22),
                             xRadius: 11, yRadius: 11).fill()
            }
        }
        ctx.restoreGState()
    }
    card(-11, -34, 46, front: false, tint: NSColor(white: 0.62, alpha: 1))
    card(7, 30, 22, front: false, tint: NSColor(white: 0.80, alpha: 1))
    card(-2, 0, -20, front: true, tint: NSColor(white: 0.98, alpha: 1))
    NSGraphicsContext.restoreGraphicsState()
    return true
}

let fm = FileManager.default
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Burst.iconset")
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: CGRect(x: 0, y: 0, width: px, height: px))
        NSGraphicsContext.restoreGraphicsState()
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try! task.run()
task.waitUntilExit()
try? fm.copyItem(at: iconset.appendingPathComponent("icon_512x512@2x.png"), to: URL(fileURLWithPath: "Resources/icon-preview.png"))
print(task.terminationStatus == 0 ? "✓ Resources/AppIcon.icns" : "✗ iconutil failed")
