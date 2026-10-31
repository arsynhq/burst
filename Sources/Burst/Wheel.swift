import AppKit
import SwiftUI

/*
 DIRECTION CONTRACT — the Burst aperture

 THESIS: How a burst leaves is chosen in the same gesture that made it. Tap ⇧
 during a hold and a camera iris spins open at the pointer; point at a blade,
 let go. Keeps Tangerine's DNA (an object at the pointer, pick by direction,
 hardware feel, one bold highlight) and refuses their petals: our object is
 the thing a burst is shot through.

 OWN-WORLD: Machined black metal. A bezel lit from above with engraved ticks;
 six blades that tile the eye with a clockwise twist, separated by dark seams,
 each lit from the centre outward and carrying an upright icon over its word. The chosen
 blade turns white. The eye stays empty:
 every blade says what it does. Monochrome: no accent colour anywhere.

 FORM: Marking menu. Direction picks, distance doesn't matter, the eye is a
 dead zone; arrow keys turn it. Fully opaque, so nothing behind bleeds through.

 FINISH: unreviewed and undocumented is unfinished; this build ends with the
 finish review, the verdict, and DESIGN.md
*/

/// Where a burst goes, clockwise from the top of the wheel.
enum WheelAction: Int, CaseIterable, Identifiable {
    case drop, dropSave, save, cancel, copy, files

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .drop: "Paste"
        case .dropSave: "Paste + save"
        case .save: "Save"
        case .cancel: "Cancel"
        case .copy: "Copy"
        case .files: "Files"
        }
    }

    /// The word printed on the blade, under its icon.
    var blade: String {
        switch self {
        case .drop: "PASTE"
        case .dropSave: "BOTH"   // sits between PASTE and SAVE, and does both
        case .save: "SAVE"
        case .cancel: "CANCEL"
        case .copy: "COPY"
        case .files: "FILES"
        }
    }

    var symbol: String {
        switch self {
        case .drop: "arrow.down.to.line"
        case .dropSave: "arrow.down.doc"
        case .save: "folder"
        case .cancel: "xmark"
        case .copy: "doc.on.clipboard"
        case .files: "doc.on.doc"
        }
    }

    /// Finishes "Let go of ⌃⌥ to …" in the HUD.
    var verb: String {
        switch self {
        case .drop: "paste"
        case .dropSave: "paste and save"
        case .save: "save"
        case .cancel: "cancel"
        case .copy: "copy"
        case .files: "paste as files"
        }
    }

    /// What the release does. Nil means throw the burst away. Saving is part
    /// of the choice itself (Both, Save), never a separate switch.
    var plan: DropPlan? {
        switch self {
        case .drop: DropPlan(paste: .oneByOne, save: false)
        case .dropSave: DropPlan(paste: .oneByOne, save: true)
        case .save: DropPlan(paste: .none, save: true)
        case .cancel: nil
        case .copy: DropPlan(paste: .none, save: false)
        case .files: DropPlan(paste: .files, save: false)
        }
    }

    var saves: Bool { plan?.save ?? false }

    /// The choices the setup screen offers as the default, in the aperture's order.
    static let defaults: [WheelAction] = [.drop, .dropSave, .save, .copy, .files]

    /// One plain sentence for the setup screen.
    var summary: String {
        switch self {
        case .drop: "Pastes each shot into the app you're in. Nothing is saved."
        case .dropSave: "Pastes each shot and saves a copy to your folder."
        case .save: "Saves them to your folder and the clipboard. Nothing is pasted."
        case .cancel: "Throws them away."
        case .copy: "Puts them on the clipboard. Nothing is pasted or saved."
        case .files: "Pastes them all at once as image files. Some apps keep only the first."
        }
    }

    /// The blade that's lit when the aperture opens: the setup screen's choice.
    static func standard(_ prefs: Prefs) -> WheelAction { prefs.defaultAction }
}

final class WheelModel: ObservableObject {
    @Published var isOpen = false
    @Published var selection: WheelAction
    @Published var count = 0

    init(selection: WheelAction) { self.selection = selection }
}

enum WheelLook {
    static let bezel: CGFloat = 152      // outer radius of the machined ring
    static let iris: CGFloat = 134       // the blades are clipped to this
    static let bladeRim: CGFloat = 140   // blades run past the clip, so no edge shows at the rim
    static let inner: CGFloat = 44       // the eye (empty: the blades carry the words)
    static let closed: CGFloat = 5       // the eye before the iris opens
    static let margin: CGFloat = 30      // room for the shadow
    /// The chosen blade turns white in place; sliding it out opened a black
    /// wedge at its seam that read as a glitch.
    static let lift: CGFloat = 0
    /// Degrees the blades lean clockwise; their visual centres sit this far past each sixth.
    static let twist: CGFloat = 10
    static var diameter: CGFloat { (bezel + margin) * 2 }
    static var span: CGFloat { 2 * .pi / CGFloat(WheelAction.allCases.count) }

    /// Blade centre angle, y-down (SwiftUI), blade 0 at the top.
    static func angle(_ index: Int) -> CGFloat { -.pi / 2 + CGFloat(index) * span + twist * .pi / 180 }

    /// Which blade a direction points at; y-down delta from the aperture's centre.
    static func index(dx: CGFloat, dy: CGFloat) -> Int {
        var a = atan2(dy, dx) + .pi / 2 - twist * .pi / 180
        while a < 0 { a += 2 * .pi }
        return Int((a / span).rounded()) % WheelAction.allCases.count
    }

    static let ink = Color(white: 0.04)
    static let metal = [Color(red: 0.204, green: 0.212, blue: 0.231), Color(red: 0.086, green: 0.090, blue: 0.102)]
    static let polished = [Color.white, Color(red: 0.83, green: 0.83, blue: 0.85)]
}

/// One iris blade, drawn pointing up: a sixth of the eye's edge out to past the
/// rim, leaning clockwise so the six tile the circle like a real aperture.
/// `inner` animates, so the iris can open from closed.
struct BladeShape: Shape {
    var inner: CGFloat
    var animatableData: CGFloat {
        get { inner }
        set { inner = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        func p(_ r: CGFloat, _ deg: CGFloat) -> CGPoint {
            let a = deg * .pi / 180
            return CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a))
        }
        let rim = WheelLook.bladeRim, lean = WheelLook.twist
        var path = Path()
        path.move(to: p(inner, -120))
        path.addLine(to: p(inner, -60))
        path.addLine(to: p(rim, -60 + 2 * lean + 2))
        path.addArc(center: c, radius: rim, startAngle: .degrees(-60 + 2 * lean + 2),
                    endAngle: .degrees(-120 + 2 * lean + 2), clockwise: true)
        path.closeSubpath()
        return path
    }
}

/// The aperture. One elevation (the bezel's shadow); everything opaque.
struct WheelView: View {
    @ObservedObject var model: WheelModel

    private var open: Bool { model.isOpen }

    var body: some View {
        let d = WheelLook.diameter
        ZStack {
            bezel
            Circle()
                .fill(Color(white: 0.02))
                .frame(width: (WheelLook.iris + 1) * 2, height: (WheelLook.iris + 1) * 2)
            ZStack {
                ForEach(WheelAction.allCases) { blade($0) }
            }
            .frame(width: d, height: d)
            .rotationEffect(.degrees(open || Motion.reduced ? 0 : -32))
            .mask(Circle().frame(width: WheelLook.iris * 2, height: WheelLook.iris * 2))
            Circle()
                .strokeBorder(Color.black.opacity(0.9), lineWidth: 1.5)
                .frame(width: (WheelLook.iris + 0.75) * 2, height: (WheelLook.iris + 0.75) * 2)
            // The eye stays empty: the blades already say what they do.
        }
        .frame(width: d, height: d)
        // The iris spins open about the pointer: critically damped, no bounce.
        .scaleEffect(open || Motion.reduced ? 1 : 0.94)
        .opacity(open ? 1 : 0)
        .animation(open ? .spring(response: 0.34, dampingFraction: 1) : .easeOut(duration: 0.12), value: open)
    }

    private var bezel: some View {
        let size = WheelLook.bezel * 2
        return ZStack {
            Circle()
                .fill(LinearGradient(colors: [Color(red: 0.231, green: 0.239, blue: 0.259),
                                              Color(red: 0.122, green: 0.125, blue: 0.137),
                                              Color(red: 0.059, green: 0.063, blue: 0.071)],
                                     startPoint: .top, endPoint: .bottom))
            Circle().strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
            Canvas { ctx, canvas in
                let c = CGPoint(x: canvas.width / 2, y: canvas.height / 2)
                for k in 0..<36 {
                    let a = CGFloat(k) * 10 * .pi / 180
                    let r0 = WheelLook.iris + 5, r1 = r0 + (k % 3 == 0 ? 7 : 4)
                    var tick = Path()
                    tick.move(to: CGPoint(x: c.x + r0 * cos(a), y: c.y + r0 * sin(a)))
                    tick.addLine(to: CGPoint(x: c.x + r1 * cos(a), y: c.y + r1 * sin(a)))
                    ctx.stroke(tick, with: .color(.white.opacity(0.16)), lineWidth: 1)
                }
            }
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.6), radius: 18, y: 12)
    }

    private func blade(_ action: WheelAction) -> some View {
        let i = action.rawValue
        let on = action == model.selection
        let hole = open || Motion.reduced ? WheelLook.inner : WheelLook.closed
        let iconAngle = (-90 + WheelLook.twist - 1) * .pi / 180
        let iconRadius: CGFloat = 92
        return ZStack {
            BladeShape(inner: hole)
                .fill(LinearGradient(colors: WheelLook.metal, startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.42)))
            BladeShape(inner: hole)
                .fill(LinearGradient(colors: WheelLook.polished, startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.42)))
                .opacity(on ? 1 : 0)
            BladeShape(inner: hole)
                .stroke(Color(white: 0.02), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
            VStack(spacing: 5) {
                Image(systemName: action.symbol)
                    .font(.system(size: 17, weight: .medium))
                    .frame(height: 20)
                Text(action.blade)
                    .font(.system(size: 10.5, weight: .bold))
                    .tracking(0.6)
                    .lineLimit(1)
                    .fixedSize()
            }
            .foregroundStyle(on ? WheelLook.ink : Color(white: 0.72))
            .rotationEffect(.degrees(-Double(i) * 60))
            .offset(x: iconRadius * cos(iconAngle), y: iconRadius * sin(iconAngle))
            .opacity(open ? 1 : 0)
        }
        .frame(width: WheelLook.diameter, height: WheelLook.diameter)
        .rotationEffect(.degrees(Double(i) * 60))
        .animation(.easeOut(duration: 0.12), value: on)
        .animation(.spring(response: 0.2, dampingFraction: 1), value: model.selection)
    }
}

/// Draws the wheel but never takes a click: the overlay underneath decides
/// what every click means.
final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
