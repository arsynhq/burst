import AppKit
import QuartzCore

/// One thumbnail. The outer layer carries position, tilt and shadow; the inner
/// layer clips the image. Bounds never change, the flight scales the transform,
/// so the two layers stay in lockstep without per-frame layout.
final class CardLayer: CALayer {
    let picture = CALayer()

    init(size: CGSize) {
        super.init()
        bounds = CGRect(origin: .zero, size: size)
        shadowColor = NSColor.black.cgColor
        shadowOpacity = 0
        shadowRadius = 12
        shadowOffset = CGSize(width: 0, height: -5)
        shadowPath = CGPath(roundedRect: bounds, cornerWidth: Look.cardRadius, cornerHeight: Look.cardRadius, transform: nil)

        picture.frame = bounds
        picture.cornerRadius = Look.cardRadius
        picture.cornerCurve = .continuous
        picture.masksToBounds = true
        picture.contentsGravity = .resizeAspectFill
        picture.backgroundColor = NSColor.white.withAlphaComponent(0.28).cgColor   // the flash before pixels land
        // A printed-photo edge: a dark shot on a dark screen still reads as a card.
        picture.borderColor = NSColor.white.withAlphaComponent(0.95).cgColor
        picture.borderWidth = 2
        addSublayer(picture)
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError() }

    func show(_ image: CGImage, scale: CGFloat) {
        picture.contentsScale = scale
        let fade = CATransition()
        fade.type = .fade
        fade.duration = 0.12
        picture.add(fade, forKey: "contents")
        picture.contents = image
        picture.backgroundColor = nil
    }
}

/// The hand-held pile in the corner of one overlay.
@MainActor
final class Pile {
    let layer = CALayer()
    private var order: [UUID] = []
    private var cards: [UUID: CardLayer] = [:]
    private let badge = CALayer()
    private let badgeText = CATextLayer()
    var anchor: CGPoint = .zero      // centre of the pile, overlay coordinates

    var count: Int { order.count }

    /// One line for the log: is the pile actually on screen, and where.
    var debugState: String {
        let p = layer.presentation() ?? layer
        return "cards=\(order.count) attached=\(layer.superlayer != nil) opacity=\(p.opacity) anchor=\(Int(anchor.x)),\(Int(anchor.y)) frame=\(Int(layer.frame.width))x\(Int(layer.frame.height)) hidden=\(layer.isHidden)"
    }

    init() {
        badge.bounds = CGRect(x: 0, y: 0, width: 22, height: 22)
        badge.cornerRadius = 11
        badge.backgroundColor = NSColor.white.cgColor
        badge.shadowColor = NSColor.black.cgColor
        badge.shadowOpacity = 0.25
        badge.shadowRadius = 3
        badge.shadowOffset = CGSize(width: 0, height: -1)
        badge.zPosition = 1000
        badge.opacity = 0
        badgeText.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        badgeText.fontSize = 12
        badgeText.foregroundColor = NSColor.black.cgColor
        badgeText.alignmentMode = .center
        badgeText.frame = CGRect(x: 0, y: 4, width: 22, height: 15)
        badge.addSublayer(badgeText)
        layer.addSublayer(badge)
    }

    static func thumbSize(for source: CGSize) -> CGSize {
        guard source.width > 0, source.height > 0 else { return Look.thumbBox }
        let s = min(Look.thumbBox.width / source.width, Look.thumbBox.height / source.height, 1)
        return CGSize(width: max(Look.thumbMin, source.width * s), height: max(Look.thumbMin, source.height * s))
    }

    private func slot(_ index: Int) -> (position: CGPoint, tilt: CGFloat) {
        let nudge = Look.nudges[index % Look.nudges.count]
        let tilt = Look.tilts[index % Look.tilts.count] * .pi / 180
        return (CGPoint(x: anchor.x + nudge.x, y: anchor.y + nudge.y), tilt)
    }

    /// The region lifts off the screen where it was and settles on the pile.
    func launch(_ id: UUID, from source: CGRect, scale: CGFloat) {
        let size = Self.thumbSize(for: source.size)
        let card = CardLayer(size: size)
        card.contentsScale = scale
        let (position, tilt) = slot(order.count)
        let start = CATransform3DMakeScale(source.width / size.width, source.height / size.height, 1)
        let end = CATransform3DMakeRotation(tilt, 0, 0, 1)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        card.zPosition = CGFloat(order.count)
        card.position = position
        card.transform = end
        card.shadowOpacity = 0.5
        layer.insertSublayer(card, below: badge)
        CATransaction.commit()

        if Motion.reduced {
            card.add(Motion.basic("opacity", from: 0, to: 1, duration: 0.18), forKey: "in")
        } else {
            card.add(Motion.spring("position", from: NSValue(point: source.mid), to: NSValue(point: position)), forKey: "fly")
            card.add(Motion.spring("transform", from: NSValue(caTransform3D: start), to: NSValue(caTransform3D: end)), forKey: "shape")
            card.picture.add(Motion.spring("cornerRadius", from: 0, to: Look.cardRadius), forKey: "radius")
            card.add(Motion.basic("shadowOpacity", from: 0, to: 0.5, duration: 0.3), forKey: "shadow")
        }

        order.append(id)
        cards[id] = card
        restack(landing: true)
    }

    func show(_ image: CGImage, for id: UUID, scale: CGFloat) {
        cards[id]?.show(image, scale: scale)
    }

    /// Undo comes from the keyboard: a quick fade, no flourish. A drop sinks
    /// the card toward the app it just landed in. Both continue from wherever
    /// the card is on screen, even mid-flight.
    func remove(_ id: UUID, sinking: Bool = false) {
        guard let card = cards.removeValue(forKey: id) else { return }
        order.removeAll { $0 == id }
        let current = card.presentation()
        let from = current?.position ?? card.position
        CATransaction.begin()
        CATransaction.setCompletionBlock { card.removeFromSuperlayer() }
        card.position = from
        card.transform = current?.transform ?? card.transform
        card.removeAllAnimations()
        card.opacity = 0
        let duration = sinking ? 0.16 : 0.1
        card.add(Motion.basic("opacity", from: current?.opacity ?? 1, to: 0, duration: duration), forKey: "out")
        if sinking && !Motion.reduced {
            card.position = CGPoint(x: from.x, y: from.y - 14)
            card.add(Motion.basic("position", from: NSValue(point: from), to: NSValue(point: card.position),
                                  duration: duration), forKey: "sink")
        }
        CATransaction.commit()
        restack()
    }

    /// The pile's footprint plus a margin: the pointer inside it means the
    /// user wants what's underneath.
    var region: CGRect {
        CGRect(x: anchor.x - Look.thumbBox.width / 2, y: anchor.y - Look.thumbBox.height / 2,
               width: Look.thumbBox.width, height: Look.thumbBox.height).insetBy(dx: -34, dy: -34)
    }

    private var dimmed = false

    func setDimmed(_ dim: Bool) {
        guard dim != dimmed else { return }
        dimmed = dim
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.15)
        CATransaction.setAnimationTimingFunction(Motion.easeOut)
        layer.opacity = dim ? 0.15 : 1
        CATransaction.commit()
    }

    /// Moves every card to another overlay (shots taken on a second display).
    func hand(to other: Pile) {
        for id in order {
            guard let card = cards[id] else { continue }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            card.removeAllAnimations()
            card.removeFromSuperlayer()
            let (position, tilt) = other.slot(other.order.count)
            card.position = position
            card.transform = CATransform3DMakeRotation(tilt, 0, 0, 1)
            card.zPosition = CGFloat(other.order.count)
            other.layer.insertSublayer(card, below: other.badge)
            CATransaction.commit()
            other.order.append(id)
            other.cards[id] = card
        }
        order.removeAll()
        cards.removeAll()
        restack()
        other.restack()
    }

    private var badgeUpdate: DispatchWorkItem?

    /// A new card's count lands with the card, not when it leaves the screen.
    private func restack(landing: Bool = false) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.18)
        CATransaction.setAnimationTimingFunction(Motion.easeOut)
        for (i, id) in order.enumerated() {
            cards[id]?.opacity = i >= order.count - Look.pileDepth ? 1 : 0
        }
        CATransaction.commit()

        badgeUpdate?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.updateBadge(pop: landing) }
        badgeUpdate = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (landing && !Motion.reduced ? 0.28 : 0), execute: work)
    }

    private func updateBadge(pop: Bool) {
        guard order.count >= 2, let top = order.last.flatMap({ cards[$0] }) else {
            badge.opacity = 0
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        badgeText.contentsScale = top.contentsScale
        badgeText.string = "\(order.count)"
        // Pinned to the pile, not the top card's nudge, so it never wanders.
        badge.position = CGPoint(x: anchor.x + top.bounds.width / 2 - 2, y: anchor.y + top.bounds.height / 2 - 2)
        badge.opacity = 1
        CATransaction.commit()
        if pop && !Motion.reduced {
            badge.add(Motion.spring("transform.scale", from: 0.85, to: 1, duration: 0.3, bounce: 0.2), forKey: "pop")
        }
    }
}
