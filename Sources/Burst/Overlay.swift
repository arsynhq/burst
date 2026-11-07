import AppKit
import SwiftUI

/// Borderless panel over one whole display. Takes no mouse events and never
/// key focus: scrolling and gestures reach the apps underneath, presses come
/// in through the event tap, and the app being dropped into stays frontmost.
final class OverlayWindow: NSPanel {
    init(frame: CGRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        setFrame(frame, display: false)
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        // Never part of anyone's capture: ScreenCaptureKit's app exclusion
        // depends on a content snapshot taken before these windows exist, so a
        // mid-flight pile card could be baked into the next grab.
        sharingType = .none
        appearance = NSAppearance(named: .darkAqua)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
protocol OverlayViewDelegate: AnyObject {
    func overlay(_ view: OverlayView, grabbed rect: CGRect)
    func overlay(_ view: OverlayView, clickedAt point: CGPoint)
}

/// Geometry an overlay needs from its display, in the overlay's own coordinates.
struct OverlayGeometry {
    var size: CGSize
    var topInset: CGFloat      // menu bar
    var bottomInset: CGFloat   // Dock, when it sits at the bottom
    var rightInset: CGFloat    // Dock, when it sits on the right

    init(size: CGSize, topInset: CGFloat = 0, bottomInset: CGFloat = 0, rightInset: CGFloat = 0) {
        self.size = size; self.topInset = topInset; self.bottomInset = bottomInset; self.rightInset = rightInset
    }

    init(screen: NSScreen) {
        let f = screen.frame, v = screen.visibleFrame
        self.init(size: f.size, topInset: f.maxY - v.maxY, bottomInset: v.minY - f.minY, rightInset: f.maxX - v.maxX)
    }
}

@MainActor
final class OverlayView: NSView {
    weak var delegate: OverlayViewDelegate?
    let geometry: OverlayGeometry
    let pile = Pile()
    let hint: HintModel

    private let scrim = CAShapeLayer()
    private let outline = CAShapeLayer()
    private let ring = CAShapeLayer()
    private let sizeTag = SizeTag()
    private let hud: NSView

    private var dragOrigin: CGPoint?
    private(set) var dragRect: CGRect?
    private var hovered: CGRect?
    private var hintShown = true
    private var hudNear = false

    let wheel: WheelModel
    private let wheelHost: PassthroughHostingView<WheelView>

    init(geometry: OverlayGeometry, hint: HintModel, wheel: WheelModel) {
        self.wheel = wheel
        self.wheelHost = PassthroughHostingView(rootView: WheelView(model: wheel))
        self.geometry = geometry
        self.hint = hint
        self.hud = NSHostingView(rootView: HintView(model: hint))
        super.init(frame: CGRect(origin: .zero, size: geometry.size))
        wantsLayer = true
        guard let root = layer else { return }

        scrim.fillColor = Look.scrim.cgColor
        scrim.fillRule = .evenOdd
        root.addSublayer(scrim)

        // Same white line as the selection: a white line is what you'll get.
        // No fill, no colour: the content under the lens stays true.
        ring.fillColor = nil
        ring.strokeColor = NSColor.white.withAlphaComponent(0.95).cgColor
        ring.lineWidth = Look.ringWidth
        ring.shadowColor = NSColor.black.cgColor
        ring.shadowOpacity = 0.35
        ring.shadowRadius = 2
        ring.shadowOffset = .zero
        ring.opacity = 0
        root.addSublayer(ring)

        outline.fillColor = nil
        outline.strokeColor = NSColor.white.cgColor
        outline.lineWidth = 1
        outline.shadowColor = NSColor.black.cgColor
        outline.shadowOpacity = 0.5
        outline.shadowRadius = 1
        outline.shadowOffset = .zero
        root.addSublayer(outline)

        pile.anchor = CGPoint(
            x: geometry.size.width - geometry.rightInset - Look.pileInset - Look.thumbBox.width / 2,
            y: geometry.bottomInset + Look.pileInset + Look.thumbBox.height / 2)
        // Exit scaling happens around the pile, not the middle of the screen.
        pile.layer.anchorPoint = CGPoint(x: pile.anchor.x / geometry.size.width, y: pile.anchor.y / geometry.size.height)
        pile.layer.frame = bounds
        root.addSublayer(pile.layer)

        addSubview(sizeTag)
        hud.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hud)
        // The wheel follows the system's light or dark, not the overlay's forced dark.
        wheelHost.appearance = NSApp.effectiveAppearance
        wheelHost.frame = CGRect(x: 0, y: 0, width: WheelLook.diameter, height: WheelLook.diameter)
        wheelHost.isHidden = true
        addSubview(wheelHost)
        NSLayoutConstraint.activate([
            hud.centerXAnchor.constraint(equalTo: centerXAnchor),
            hud.topAnchor.constraint(equalTo: topAnchor, constant: geometry.topInset + Look.hudGap),
        ])
        redraw()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: State from the session

    /// The window a click would take, or nil.
    func setHover(_ rect: CGRect?) {
        guard dragRect == nil, rect != hovered else { return }
        hovered = rect
        updateRing(animated: true)
    }

    /// The pile and the HUD both step aside when the pointer or a selection
    /// reaches them, so neither ever hides what you're aiming at.
    func setPointer(_ point: CGPoint?) {
        let region = pile.region
        let near = pile.count > 0 && ((point.map(region.contains) ?? false) || (dragRect?.intersects(region) ?? false))
        pile.setDimmed(near)

        let hudZone = hud.frame.insetBy(dx: -40, dy: -40)
        let nearHUD = (point.map(hudZone.contains) ?? false) || (dragRect?.intersects(hud.frame.insetBy(dx: -12, dy: -12)) ?? false)
        if nearHUD != hudNear {
            hudNear = nearHUD
            updateHUD()
        }
    }

    /// Release: the lens goes, the pile stays to show each shot dropping in.
    func fadeChrome() {
        dragOrigin = nil
        dragRect = nil
        hovered = nil
        pile.setDimmed(false)
        CATransaction.begin()
        CATransaction.setAnimationDuration(Motion.overlayOut)
        CATransaction.setAnimationTimingFunction(Motion.easeOut)
        for layer in [scrim, ring, outline] { layer.opacity = 0 }
        CATransaction.commit()
        sizeTag.isHidden = true
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Motion.overlayOut
            hud.animator().alphaValue = 0
        }
    }

    func setHintVisible(_ visible: Bool) {
        guard visible != hintShown else { return }
        hintShown = visible
        updateHUD()
    }

    private func updateHUD() {
        let alpha: CGFloat = hintShown ? (hudNear ? 0.15 : 1) : 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            ctx.timingFunction = Motion.easeOut
            hud.animator().alphaValue = alpha
        }
    }

    /// Used by the snapshot renderer to pose a selection without a mouse.
    func pose(selection: CGRect?) {
        dragRect = selection
        redraw()
    }

    /// Record mode: the selection outline turns red, the one colour that means "recording".
    func setRecording(_ on: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        outline.strokeColor = (on ? Look.recordRed : NSColor.white).cgColor
        outline.lineWidth = on ? 2 : 1
        CATransaction.commit()
    }

    // MARK: Wheel

    /// Places the wheel centred on the pointer, nudged inward to stay whole on screen.
    func presentWheel(at point: CGPoint) {
        let r = WheelLook.diameter / 2, m: CGFloat = 12
        let x = min(max(point.x, r + m), bounds.maxX - r - m)
        let y = min(max(point.y, r + m + geometry.bottomInset), bounds.maxY - r - m - geometry.topInset)
        wheelHost.frame.origin = CGPoint(x: x - r, y: y - r)
        wheelHost.isHidden = false
        hovered = nil
        updateRing(animated: false)
    }

    var wheelCenter: CGPoint { CGPoint(x: wheelHost.frame.midX, y: wheelHost.frame.midY) }
    var showsWheel: Bool { !wheelHost.isHidden }

    func hideWheel() { wheelHost.isHidden = true }

    // MARK: Pointer (fed by the session from the event tap)

    func press(at point: CGPoint) {
        dragOrigin = point
        dragRect = nil
    }

    func drag(to point: CGPoint) {
        guard let origin = dragOrigin else { return }
        var p = point
        p.x = min(max(p.x, 0), bounds.maxX)
        p.y = min(max(p.y, 0), bounds.maxY)
        // Hysteresis: a wobble during a click is not a drag.
        if dragRect == nil && hypot(p.x - origin.x, p.y - origin.y) < 4 { return }
        let x0 = floor(min(origin.x, p.x)), y0 = floor(min(origin.y, p.y))
        let x1 = ceil(max(origin.x, p.x)), y1 = ceil(max(origin.y, p.y))
        dragRect = CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
        hovered = nil
        redraw()
    }

    func release() {
        defer { dragOrigin = nil; dragRect = nil; redraw() }
        if let rect = dragRect {
            if rect.width >= 4 && rect.height >= 4 { delegate?.overlay(self, grabbed: rect) }
        } else if let origin = dragOrigin {
            delegate?.overlay(self, clickedAt: origin)
        }
    }

    // MARK: Drawing

    private func redraw() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        scrim.frame = bounds
        let dim = CGMutablePath()
        dim.addRect(bounds)
        if let r = dragRect { dim.addRect(r) }
        scrim.path = dim
        outline.path = dragRect.map { CGPath(rect: $0.insetBy(dx: -0.5, dy: -0.5), transform: nil) }
        CATransaction.commit()
        sizeTag.place(for: dragRect, in: bounds)
        if dragRect != nil { updateRing(animated: false) }   // a drag owns the screen at once
    }

    /// Appearing fades in where the window is; moving to another window glides
    /// the line across (a plain swap under Reduce Motion).
    private func updateRing(animated: Bool) {
        let target = dragRect == nil ? hovered : nil
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.12)
        CATransaction.setAnimationTimingFunction(Motion.easeOut)
        CATransaction.setDisableActions(!animated)
        if let target {
            let path = CGPath(roundedRect: target.insetBy(dx: Look.ringWidth / 2, dy: Look.ringWidth / 2),
                              cornerWidth: Look.windowRadius, cornerHeight: Look.windowRadius, transform: nil)
            if ring.opacity == 0 || Motion.reduced {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                ring.path = path
                CATransaction.commit()
            } else {
                ring.path = path
            }
            ring.opacity = 1
        } else {
            ring.opacity = 0
        }
        CATransaction.commit()
    }
}

/// "640 × 400" under the selection's corner, the way ⌘⇧4 reports it.
final class SizeTag: NSView {
    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
        layer?.cornerRadius = 5
        layer?.cornerCurve = .continuous
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        label.textColor = .white
        addSubview(label)
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    func place(for rect: CGRect?, in bounds: CGRect) {
        guard let rect, rect.width >= 4, rect.height >= 4 else { isHidden = true; return }
        label.stringValue = "\(Int(rect.width)) × \(Int(rect.height))"
        label.sizeToFit()
        let size = CGSize(width: label.frame.width + 12, height: 20)
        var origin = CGPoint(x: rect.maxX - size.width, y: rect.minY - size.height - 6)
        if origin.y < bounds.minY + 4 { origin.y = rect.minY + 6 }           // no room below: tuck inside
        origin.x = min(max(origin.x, bounds.minX + 4), bounds.maxX - size.width - 4)
        frame = CGRect(origin: origin, size: size)
        label.frame.origin = CGPoint(x: 6, y: (size.height - label.frame.height) / 2)
        isHidden = false
    }
}

// MARK: - HUD

final class HintModel: ObservableObject {
    @Published var count = 0
    @Published var problem: String?
    @Published var verb: String
    @Published var wheelOpen = false
    @Published var recording = false
    let chord: Chord
    let wheelKey: String
    let recordKey: String

    init(chord: Chord, verb: String) {
        self.chord = chord
        self.verb = verb
        wheelKey = Chord.symbol(chord.apertureKey)
        recordKey = Chord.symbol(chord.recordKey)
    }
}

struct HintView: View {
    @ObservedObject var model: HintModel

    var body: some View {
        HStack(spacing: 14) {
            status
            Divider().frame(height: 14).overlay(Color.white.opacity(0.12))
            HStack(spacing: 12) {
                if model.wheelOpen {
                    KeyHint(key: model.wheelKey, label: "Close")
                } else if model.recording {
                    KeyHint(key: model.recordKey, label: "Let go for shots")
                    KeyHint(key: "esc", label: "Cancel")
                } else {
                    KeyHint(key: model.wheelKey, label: "Options")
                    KeyHint(key: model.recordKey, label: "Video")
                    if model.count > 0 { KeyHint(key: "⌫", label: "Undo") }
                    KeyHint(key: "esc", label: "Cancel")
                }
            }
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .frame(height: Look.hudHeight)
        // The one capsule of state. Its blur lives in SwiftUI so the capsule
        // resizes with the same animation as the text inside it.
        // Solid, so window titles underneath can never show through the words.
        .background(Capsule().fill(Color(red: 0.043, green: 0.047, blue: 0.055)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
        .fixedSize()
        .animation(.snappy(duration: 0.2), value: model.count)
        .animation(.snappy(duration: 0.2), value: model.wheelOpen)
        .animation(.snappy(duration: 0.2), value: model.recording)
        .animation(.snappy(duration: 0.2), value: model.verb)
    }

    @ViewBuilder private var status: some View {
        if let problem = model.problem {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                Text(problem)
            }
        } else if model.recording {
            HStack(spacing: 7) {
                Circle().fill(Color(nsColor: Look.recordRed)).frame(width: 8, height: 8)
                Text("Drag the area to record, or click a window")
            }
        } else if model.wheelOpen {
            Text("Point at where this burst goes")
        } else if model.count == 0 {
            Text("Drag an area or click a window")
        } else {
            HStack(spacing: 8) {
                Text("\(model.count) \(model.count == 1 ? "shot" : "shots")")
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(model.count)))
                Text("Let go of \(model.chord.symbols) to \(model.verb)")
                    .foregroundStyle(.white.opacity(0.62))
            }
        }
    }
}

private struct KeyHint: View {
    let key: String
    let label: String

    var body: some View {
        HStack(spacing: 5) {
            Text(key)
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 5)
                .frame(minWidth: 20, minHeight: 18)
                .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(.white.opacity(0.14)))
            Text(label).foregroundStyle(.white.opacity(0.62))
        }
    }
}
