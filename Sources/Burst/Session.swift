import AppKit
import OSLog
import ScreenCaptureKit

/// `log stream --predicate 'subsystem == "com.mikesuastegui.handful"'` shows a session's life.
let burstLog = Logger(subsystem: "com.mikesuastegui.handful", category: "session")

/// One hold of the chord: overlays on every display, the shots taken, and the
/// pile they land in.
@MainActor
final class Session: OverlayViewDelegate {
    private struct Overlay {
        let screen: NSScreen
        let window: OverlayWindow
        let view: OverlayView
    }

    private(set) var shots: [Shot] = []
    let hint: HintModel
    let wheel: WheelModel
    private weak var wheelHost: OverlayView?
    var onShotsChanged: (([Shot]) -> Void)?
    /// Record mode: the area (Cocoa global) and its display, when the user picks one.
    var onRecord: ((CGRect, NSScreen) -> Void)?
    private(set) var recordMode = false

    private var overlays: [Overlay] = []
    private var windows: [WindowInfo]
    private let content: Task<SCShareableContent?, Never>
    private var tick: Timer?
    /// Window outlines wait until the pointer moves: the first frame of every
    /// hold is a plain dim, and a hold-then-drag never sees one.
    private var restPoint: CGPoint?
    private var hoverArmed = false
    private weak var pileHost: OverlayView?
    private let prefs: Prefs
    private let shutter = NSSound(contentsOfFile:
        "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif",
        byReference: true)

    init(prefs: Prefs) {
        self.prefs = prefs
        let standard = WheelAction.standard(prefs)
        wheel = WheelModel(selection: standard)
        hint = HintModel(chord: prefs.chord, verb: standard.verb)
        windows = WindowInfo.onScreen()
        content = Task { try? await Capturer.content() }
        for screen in NSScreen.screens {
            let window = OverlayWindow(frame: screen.frame)
            let view = OverlayView(geometry: OverlayGeometry(screen: screen), hint: hint, wheel: wheel)
            view.delegate = self
            window.contentView = view
            overlays.append(Overlay(screen: screen, window: window, view: view))
        }
    }

    func begin() {
        burstLog.info("session began on \(self.overlays.count, privacy: .public) display(s)")
        for o in overlays {
            o.window.alphaValue = 0
            o.window.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Motion.overlayIn
            ctx.timingFunction = Motion.easeOut
            for o in overlays { o.window.animator().alphaValue = 1 }
        }
        update()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        RunLoop.main.add(timer, forMode: .common)
        tick = timer
    }

    /// Hover, hint placement and cursor, polled so it works while another app is active.
    private func update() {
        let mouse = NSEvent.mouseLocation
        if wheel.isOpen, let host = wheelHost, let o = overlays.first(where: { $0.view === host }) {
            // Marking menu: the direction from the wheel's centre picks the slice.
            let c = host.wheelCenter
            let dx = mouse.x - o.screen.frame.minX - c.x, dy = mouse.y - o.screen.frame.minY - c.y
            if hypot(dx, dy) > WheelLook.inner * 0.7 {
                select(WheelAction(rawValue: WheelLook.index(dx: dx, dy: -dy)) ?? wheel.selection)
            }
            NSCursor.arrow.set()
            return
        }
        for o in overlays {
            let inside = NSMouseInRect(mouse, o.screen.frame, false)
            o.view.setHintVisible(inside)
            guard inside else { o.view.setHover(nil); o.view.setPointer(nil); continue }
            if !hoverArmed {
                if let rest = restPoint, hypot(mouse.x - rest.x, mouse.y - rest.y) >= 10 { hoverArmed = true }
                if restPoint == nil { restPoint = mouse }
            }
            let origin = o.screen.frame.origin
            let window = windows.first(where: { $0.frame.contains(mouse) })?.frame
            // Bare desktop gets no outline; a click there still takes the display.
            o.view.setHover(hoverArmed ? window.map { $0.offsetBy(dx: -origin.x, dy: -origin.y) } : nil)
            o.view.setPointer(CGPoint(x: mouse.x - origin.x, y: mouse.y - origin.y))
        }
        // Your own cursor while hovering (apps under the lens still see it move);
        // the crosshair only while a press is drawing an area, when the drag
        // events are ours and nothing else will change the cursor.
        if pressed != nil { NSCursor.crosshair.set() }
    }

    // MARK: Wheel

    func toggleWheel() { wheel.isOpen ? closeWheel() : openWheel() }

    func openWheel() {
        let mouse = NSEvent.mouseLocation
        guard let o = overlays.first(where: { NSMouseInRect(mouse, $0.screen.frame, false) }) ?? overlays.first else { return }
        if let old = wheelHost, old !== o.view { old.hideWheel() }
        o.view.presentWheel(at: CGPoint(x: mouse.x - o.screen.frame.minX, y: mouse.y - o.screen.frame.minY))
        wheelHost = o.view
        wheel.count = shots.count
        wheel.isOpen = true
        hint.wheelOpen = true
    }

    func closeWheel() {
        guard wheel.isOpen else { return }
        wheel.isOpen = false
        hint.wheelOpen = false
    }

    func stepWheel(_ delta: Int) {
        let n = WheelAction.allCases.count
        select(WheelAction(rawValue: (wheel.selection.rawValue + delta + n) % n) ?? wheel.selection)
    }

    private func select(_ action: WheelAction) {
        guard action != wheel.selection else { return }
        wheel.selection = action
        hint.verb = action.verb
        // A detent under the finger as the choice changes.
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    // MARK: Record mode

    func setRecordMode(_ on: Bool) {
        guard on != recordMode else { return }
        recordMode = on
        if on { closeWheel() }
        hint.recording = on
        overlays.forEach { $0.view.setRecording(on) }
    }

    // MARK: Pointer

    private var pressed: Overlay?

    func pointerDown(_ point: CGPoint) {
        // A click while the aperture is open confirms the blade, nothing else.
        if wheel.isOpen { closeWheel(); pressed = nil; return }
        guard let o = overlays.first(where: { NSMouseInRect(point, $0.screen.frame, false) }) else {
            burstLog.error("press at \(point.x, privacy: .public),\(point.y, privacy: .public) is on no display")
            return
        }
        pressed = o
        o.view.press(at: local(point, in: o))
    }

    func pointerDragged(_ point: CGPoint) {
        guard let o = pressed else { return }
        o.view.drag(to: local(point, in: o))
    }

    func pointerUp(_ point: CGPoint) {
        guard let o = pressed else { return }
        pressed = nil
        o.view.release()
    }

    private func local(_ point: CGPoint, in o: Overlay) -> CGPoint {
        CGPoint(x: point.x - o.screen.frame.minX, y: point.y - o.screen.frame.minY)
    }

    // MARK: Grabbing

    func overlay(_ view: OverlayView, grabbed rect: CGRect) {
        guard let o = overlays.first(where: { $0.view === view }) else { return }
        let global = rect.offsetBy(dx: o.screen.frame.minX, dy: o.screen.frame.minY)
        if recordMode {
            if rect.width >= 32 && rect.height >= 32 { onRecord?(global, o.screen) }
            return
        }
        grab(on: o, from: rect) { content in
            try await Capturer.region(global, on: o.screen, content: content)
        }
    }

    func overlay(_ view: OverlayView, clickedAt point: CGPoint) {
        guard let o = overlays.first(where: { $0.view === view }) else { return }
        let global = CGPoint(x: point.x + o.screen.frame.minX, y: point.y + o.screen.frame.minY)
        if recordMode {
            // A click records that window's area, or the whole display on bare desktop.
            let area = windows.first(where: { $0.frame.contains(global) })?.frame ?? o.screen.frame
            onRecord?(area.intersection(o.screen.frame), o.screen)
            return
        }
        if let window = windows.first(where: { $0.frame.contains(global) }) {
            let local = window.frame.offsetBy(dx: -o.screen.frame.minX, dy: -o.screen.frame.minY)
            grab(on: o, from: local) { content in try await Capturer.window(window.id, content: content) }
        } else {
            // Bare desktop: the whole display.
            grab(on: o, from: view.bounds) { content in
                try await Capturer.region(o.screen.frame, on: o.screen, content: content)
            }
        }
    }

    private func grab(on o: Overlay, from source: CGRect,
                      capture: @escaping (SCShareableContent) async throws -> CGImage) {
        // After a grab the outline waits for the pointer to move again.
        hoverArmed = false
        restPoint = nil
        let shot = Shot(scale: o.screen.backingScaleFactor)
        shots.append(shot)
        hint.problem = nil
        hint.count = shots.count
        wheel.count = shots.count
        if prefs.playSound { shutter?.stop(); shutter?.play() }

        if let host = pileHost, host !== o.view { host.pile.hand(to: o.view.pile) }
        pileHost = o.view
        o.view.pile.launch(shot.id, from: source, scale: o.screen.backingScaleFactor)
        burstLog.info("grab \(self.shots.count, privacy: .public): \(Int(source.width), privacy: .public)x\(Int(source.height), privacy: .public) pile \(o.view.pile.debugState, privacy: .public)")

        shot.task = Task { [weak self] in
            do {
                guard let content = await self?.content.value else { throw CaptureError.noPermission }
                let image = try await capture(content)
                shot.image = image
                self?.pileHost?.pile.show(image, for: shot.id, scale: shot.scale)
                await shot.prepare()
                self?.publish()
            } catch is CancellationError {
            } catch {
                self?.failed(shot, error)
            }
        }
    }

    private func failed(_ shot: Shot, _ error: Error) {
        burstLog.error("capture failed: \(error.localizedDescription, privacy: .public)")
        shots.removeAll { $0 === shot }
        pileHost?.pile.remove(shot.id)
        hint.count = shots.count
        wheel.count = shots.count
        hint.problem = (error as? LocalizedError)?.errorDescription ?? "That shot didn't take"
    }

    func undo() {
        guard let shot = shots.popLast() else { return }
        shot.task?.cancel()
        pileHost?.pile.remove(shot.id)
        hint.count = shots.count
        wheel.count = shots.count
        publish()
    }

    private func publish() {
        onShotsChanged?(shots.filter { $0.image != nil })
    }

    // MARK: Ending

    enum Exit { case drop, cancel }

    /// Cancel clears the screen at once. Drop clears the lens but leaves the
    /// pile up (click-through) so each shot can be seen going in; call
    /// `peel` per pasted shot, then `close`.
    func finish(_ exit: Exit) async -> [Shot] {
        // From here the Dropper owns the clipboard; a late shot must not rewrite it mid-paste.
        onShotsChanged = nil
        closeWheel()
        tick?.invalidate()
        tick = nil
        NSCursor.arrow.set()
        guard exit == .drop else {
            dismiss(.cancel)
            shots.forEach { $0.task?.cancel() }
            return []
        }
        for o in overlays {
            o.window.ignoresMouseEvents = true
            if o.view === pileHost { o.view.fadeChrome() } else { fadeOut([o.window]) }
        }
        // Not awaited here: the drop starts pasting while late shots finish.
        return shots
    }

    /// One shot has landed in the front app.
    func peel(_ shot: Shot) {
        pileHost?.pile.remove(shot.id, sinking: true)
    }

    func close() { dismiss(.drop) }

    private func dismiss(_ exit: Exit) {
        if let pile = pileHost?.pile.layer, !Motion.reduced {
            // Dropped: the pile sinks a little as it goes. Cancelled: it just shrinks away.
            let to = exit == .drop
                ? CATransform3DScale(CATransform3DMakeTranslation(0, -14, 0), 0.96, 0.96, 1)
                : CATransform3DMakeScale(0.92, 0.92, 1)
            pile.add(Motion.basic("transform", from: NSValue(caTransform3D: CATransform3DIdentity),
                                  to: NSValue(caTransform3D: to), duration: Motion.overlayOut), forKey: "exit")
            pile.transform = to
        }
        fadeOut(overlays.map(\.window))
    }

    private func fadeOut(_ windows: [OverlayWindow]) {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Motion.overlayOut
            ctx.timingFunction = Motion.easeOut
            for w in windows { w.animator().alphaValue = 0 }
        }, completionHandler: {
            for w in windows { w.orderOut(nil) }
        })
    }
}
