import AppKit
import SwiftUI

/// `Burst --snapshot <dir>` renders the overlay and settings off-screen to
/// PNGs for design review, without taking over anyone's display. Every image
/// in the overlay shot is synthetic.
@MainActor
enum Snapshot {
    static func render(to dir: URL) {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // First frame of a hold (pointer resting on a big chat window), then
        // the same moment once the pointer has moved.
        overlay(to: dir.appendingPathComponent("start.png"), hover: nil, selection: nil, shots: 0)
        overlay(to: dir.appendingPathComponent("hover.png"), hover: bigWindow, selection: nil, shots: 0)
        // Mid-session: three shots in the pile, a fourth being dragged.
        overlay(to: dir.appendingPathComponent("overlay.png"), hover: nil,
                selection: CGRect(x: 820, y: 180, width: 420, height: 250), shots: 3)
        // The wheel mid-hold, in both appearances.
        overlay(to: dir.appendingPathComponent("wheel-light.png"), hover: nil, selection: nil, shots: 3,
                wheel: (CGPoint(x: 700, y: 470), .copy, .aqua))
        overlay(to: dir.appendingPathComponent("wheel-dark.png"), hover: nil, selection: nil, shots: 3,
                wheel: (CGPoint(x: 700, y: 470), .drop, .darkAqua))
        NSApp.appearance = nil
        // Recording: picking the area, then the controls while it runs, then the note.
        overlay(to: dir.appendingPathComponent("record-pick.png"), hover: nil,
                selection: CGRect(x: 360, y: 180, width: 520, height: 320), shots: 0, record: true)
        recordingControls(to: dir.appendingPathComponent("record-running.png"))
        // Light: idle, a few past bursts. Dark: mid-hold, keys down and glowing.
        home(.aqua, holding: false, history: true, to: dir.appendingPathComponent("home-light.png"))
        home(.darkAqua, holding: true, history: true, to: dir.appendingPathComponent("home-dark.png"))
        home(.aqua, holding: false, history: false, to: dir.appendingPathComponent("home-empty.png"))
    }

    static let bigWindow = CGRect(x: 60, y: 84, width: 1392, height: 856)

    private static func overlay(to url: URL, hover: CGRect?, selection: CGRect?, shots count: Int,
                                wheel open: (CGPoint, WheelAction, NSAppearance.Name)? = nil, record: Bool = false) {
        if let open { NSApp.appearance = NSAppearance(named: open.2) }
        let size = CGSize(width: 1512, height: 982)
        let window = offscreenWindow(size: size)
        window.appearance = NSAppearance(named: .darkAqua)
        let root = NSView(frame: CGRect(origin: .zero, size: size))
        root.wantsLayer = true
        let desktop = NSImageView(frame: root.bounds)
        desktop.image = NSImage(cgImage: fakeDesktop(size), size: size)
        root.addSubview(desktop)

        let hint = HintModel(chord: .controlOption, verb: (open?.1 ?? .drop).verb)
        let wheel = WheelModel(selection: open?.1 ?? .drop)
        let view = OverlayView(geometry: OverlayGeometry(size: size, topInset: 37, bottomInset: 72), hint: hint, wheel: wheel)
        root.addSubview(view)
        window.contentView = root
        window.orderFrontRegardless()

        let shots: [(CGRect, NSColor)] = [
            (CGRect(x: 120, y: 520, width: 520, height: 300), .systemBlue),
            (CGRect(x: 700, y: 560, width: 380, height: 240), .systemOrange),
            (CGRect(x: 160, y: 200, width: 600, height: 260), .systemGreen),
        ]
        for (i, (rect, color)) in shots.prefix(count).enumerated() {
            let id = UUID()
            view.pile.launch(id, from: rect, scale: 2)
            view.pile.show(swatch(rect.size, color, dark: i == 2), for: id, scale: 2)
        }
        hint.count = count
        if record {
            view.setRecording(true)
            hint.recording = true
        }
        if let open {
            wheel.count = count
            wheel.isOpen = true
            hint.wheelOpen = true
            view.presentWheel(at: open.0)
        }
        view.setHover(hover)
        view.pose(selection: selection)
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        write(window.contentView!, to: url, layerTree: true)
        window.orderOut(nil)
    }

    private static func recordingControls(to url: URL) {
        let size = CGSize(width: 1512, height: 982)
        let window = offscreenWindow(size: size)
        window.appearance = NSAppearance(named: .darkAqua)
        let root = NSView(frame: CGRect(origin: .zero, size: size))
        root.wantsLayer = true
        let desktop = NSImageView(frame: root.bounds)
        desktop.image = NSImage(cgImage: fakeDesktop(size), size: size)
        root.addSubview(desktop)
        let area = CGRect(x: 360, y: 400, width: 520, height: 320)   // clear of the note at the bottom
        let border = NSView(frame: area.insetBy(dx: -4, dy: -4))
        border.wantsLayer = true
        border.layer?.borderColor = Look.recordRed.cgColor
        border.layer?.borderWidth = 1.5
        border.layer?.cornerRadius = 3
        root.addSubview(border)
        let model = RecordingModel()
        model.seconds = 12
        let pill = NSHostingView(rootView: RecordingPill(model: model) {})
        let p = pill.fittingSize
        pill.frame = CGRect(x: area.midX - p.width / 2, y: area.minY - 12 - p.height, width: p.width, height: p.height)
        root.addSubview(pill)
        let toast = NSHostingView(rootView: ToastView(message: "Saved to Downloads") {})
        let t = toast.fittingSize
        toast.frame = CGRect(x: size.width / 2 - t.width / 2, y: 120, width: t.width, height: t.height)
        root.addSubview(toast)
        window.contentView = root
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        write(root, to: url, layerTree: true)
        window.orderOut(nil)
    }

    private static func home(_ appearance: NSAppearance.Name, holding: Bool, history seeded: Bool, to url: URL) {
        let live = LiveState()
        if holding { live.held = Prefs.shared.chord.flags; live.live = true }
        let history = History()
        if seeded {
            let colors: [NSColor] = [.systemGreen, .systemOrange, .systemPurple, .systemTeal, .systemPink]
            let counts = [3, 1, 4, 2, 5]
            let minutes = [2, 9, 26, 61, 180]
            history.seed(counts.indices.map { i in
                let thumbs = (0..<min(counts[i], 3)).map { j in
                    NSImage(cgImage: swatch(CGSize(width: 208, height: 132), colors[(i + j) % colors.count]),
                            size: NSSize(width: 208, height: 132))
                }
                return History.Item(date: Date().addingTimeInterval(TimeInterval(-60 * minutes[i])),
                                    shots: (0..<counts[i]).map { _ in Shot(scale: 2) }, thumbs: thumbs)
            })
        }
        let host = NSHostingView(rootView: HomeView(prefs: Prefs.shared, live: live, history: history))
        let size = AppInfo.windowSize
        let window = offscreenWindow(size: size)
        window.appearance = NSAppearance(named: appearance)
        host.frame = CGRect(origin: .zero, size: size)
        window.contentView = host
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        write(host, to: url)
        window.orderOut(nil)
    }

    private static func offscreenWindow(size: CGSize) -> NSWindow {
        let window = NSWindow(contentRect: CGRect(x: -30000, y: -30000, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    private static func write(_ view: NSView, to url: URL, layerTree: Bool = false) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        if layerTree, let layer = view.layer, let ctx = NSGraphicsContext(bitmapImageRep: rep) {
            // cacheDisplay skips hand-made sublayers; draw the layer tree over it.
            layer.render(in: ctx.cgContext)
        }
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    // MARK: Synthetic material

    private static func fakeDesktop(_ size: CGSize) -> CGImage {
        draw(size) { ctx in
            let colors = [NSColor(srgbRed: 0.18, green: 0.32, blue: 0.52, alpha: 1).cgColor,
                          NSColor(srgbRed: 0.52, green: 0.36, blue: 0.46, alpha: 1).cgColor] as CFArray
            let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1])!
            ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
            for frame in [CGRect(x: 1000, y: 300, width: 460, height: 560), bigWindow] {
                let path = CGPath(roundedRect: frame, cornerWidth: 14, cornerHeight: 14, transform: nil)
                ctx.setFillColor(NSColor(white: 0.97, alpha: 1).cgColor)
                ctx.addPath(path); ctx.fillPath()
                ctx.setFillColor(NSColor(white: 0.90, alpha: 1).cgColor)
                ctx.fill(CGRect(x: frame.minX, y: frame.maxY - 44, width: frame.width, height: 30))
                ctx.setFillColor(NSColor(white: 0.80, alpha: 1).cgColor)
                for row in 0..<14 {
                    let w = frame.width * (row % 3 == 0 ? 0.5 : 0.8)
                    ctx.fill(CGRect(x: frame.minX + 32, y: frame.maxY - 90 - CGFloat(row) * 38, width: w, height: 12))
                }
            }
        }
    }

    private static func swatch(_ size: CGSize, _ color: NSColor, dark: Bool = false) -> CGImage {
        draw(CGSize(width: size.width * 2, height: size.height * 2)) { ctx in
            ctx.setFillColor(NSColor(white: dark ? 0.1 : 0.98, alpha: 1).cgColor)
            ctx.fill(CGRect(origin: .zero, size: CGSize(width: size.width * 2, height: size.height * 2)))
            ctx.setFillColor(color.cgColor)
            ctx.fill(CGRect(x: 40, y: size.height * 2 - 120, width: size.width * 2 - 80, height: 60))
            ctx.setFillColor(NSColor(white: 0.82, alpha: 1).cgColor)
            for row in 0..<Int(size.height / 30) {
                ctx.fill(CGRect(x: 40, y: size.height * 2 - 180 - CGFloat(row) * 50, width: size.width * 1.4, height: 18))
            }
        }
    }

    private static func draw(_ size: CGSize, _ body: (CGContext) -> Void) -> CGImage {
        let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        body(ctx)
        return ctx.makeImage()!
    }
}
