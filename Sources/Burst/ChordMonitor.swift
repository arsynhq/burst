import AppKit
import CoreGraphics

@MainActor
protocol ChordMonitorDelegate: AnyObject {
    var sessionHasShots: Bool { get }
    func chordBegan()
    func chordReleased()
    func chordCancelled()
    func chordUndo()
    var wheelOpen: Bool { get }
    func chordWheelToggle()
    func chordWheelStep(_ delta: Int)
    func chordWheelClose()
    /// Left-button presses during a hold, in Cocoa global coordinates. Only
    /// these are taken from the apps; scrolling and gestures pass straight through.
    func pointerDown(_ point: CGPoint)
    func pointerDragged(_ point: CGPoint)
    func pointerUp(_ point: CGPoint)
    /// The record key went down or up during a hold.
    func chordRecordKey(_ held: Bool)
}

/// Watches every keyboard event through a session event tap and turns a held
/// modifier pair into a capture session.
///
///   idle ──chord down──▶ armed ──held 0.25s──▶ active ──chord broken──▶ drop
///                          │                      │
///                  key/click pressed       esc ▶ cancel, ⌫ ▶ undo,
///                          ▼               any key before a shot ▶ cancel + pass through
///                        spent ◀───────────────────┘
///
/// "spent" waits for the chord to change before it can arm again, so ⌃⌥→ for a
/// window manager never turns into a capture.
@MainActor
final class ChordMonitor {
    enum State { case idle, armed, active, spent }

    weak var delegate: ChordMonitorDelegate?
    var chord: Chord = .controlOption { didSet { reset() } }
    /// True while a drop is pasting; a new session would fight the synthetic ⌘V.
    var suspended = false
    /// Every modifier change, so the window's keycaps can move with the real keys.
    var onFlags: ((CGEventFlags) -> Void)?

    private(set) var state: State = .idle
    private var tap: CFMachPort?
    private var arming: DispatchWorkItem?
    private var swallowed = Set<Int64>()
    private var watchdog: Timer?

    static let holdDelay: TimeInterval = 0.25

    private enum Key {
        static let escape: Int64 = 53
        static let delete: Int64 = 51
        static let forwardDelete: Int64 = 117
        static let returnKey: Int64 = 36
        static let enter: Int64 = 76
        static let left: Int64 = 123
        static let right: Int64 = 124
        static let down: Int64 = 125
        static let up: Int64 = 126
    }

    /// Tapped during a hold to open the wheel: Shift, or Command when the
    /// chord itself uses Shift.
    var wheelKey: CGEventFlags { chord.apertureKey }
    private var recordHeld = false
    private var wheelKeyDownAt: Date?
    /// A press that began during a hold: its drag and release are ours too,
    /// even if the keys come up first, so no app ever sees half a click.
    private var holdingPointer = false

    var isRunning: Bool { tap != nil }

    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let types: [CGEventType] = [.flagsChanged, .keyDown, .keyUp, .leftMouseDown, .leftMouseDragged, .leftMouseUp,
                                    .rightMouseDown, .otherMouseDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << CGEventMask($1.rawValue)) }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: chordTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    /// Returns true when the event should be swallowed.
    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        case .flagsChanged:
            let held = event.flags.intersection(Chord.relevant)
            onFlags?(held)
            flagsChanged(held)
            return false
        case .keyDown:
            return keyDown(event.getIntegerValueField(.keyboardEventKeycode))
        case .keyUp:
            return swallowed.remove(event.getIntegerValueField(.keyboardEventKeycode)) != nil
        case .leftMouseDown:
            // ⌃-click and friends: a click during the hold delay means the
            // chord was meant for something else.
            if state == .armed { disarm(to: .spent); return false }
            guard state == .active else { return false }
            holdingPointer = true
            delegate?.pointerDown(Self.cocoa(event.location))
            return true
        case .leftMouseDragged:
            guard holdingPointer else { return false }
            if state == .active { delegate?.pointerDragged(Self.cocoa(event.location)) }
            return true
        case .leftMouseUp:
            guard holdingPointer else { return false }
            holdingPointer = false
            if state == .active { delegate?.pointerUp(Self.cocoa(event.location)) }
            return true
        case .rightMouseDown, .otherMouseDown:
            if state == .armed { disarm(to: .spent) }
            return false
        default:
            return false
        }
    }

    /// Event-tap points are top-left based; Cocoa's are bottom-left.
    private static func cocoa(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x, y: (NSScreen.screens.first?.frame.height ?? 0) - p.y)
    }

    private func flagsChanged(_ held: CGEventFlags) {
        switch state {
        case .idle:
            if held == chord.flags && !suspended { arm() }
        case .armed:
            if held != chord.flags { disarm(to: .idle) }
        case .active:
            guard held.contains(chord.flags) else {
                wheelKeyDownAt = nil
                end { $0.chordReleased() }
                return
            }
            let recording = held.contains(chord.recordKey)
            if recording != recordHeld {
                recordHeld = recording
                delegate?.chordRecordKey(recording)
            }
            if held == chord.flags.union(wheelKey) {
                wheelKeyDownAt = Date()
            } else if held == chord.flags, let down = wheelKeyDownAt {
                // A tap, not a hold: open or close the wheel.
                wheelKeyDownAt = nil
                if Date().timeIntervalSince(down) < 0.5 { delegate?.chordWheelToggle() }
            } else {
                wheelKeyDownAt = nil
            }
        case .spent:
            if held != chord.flags { state = .idle }
        }
    }

    private func keyDown(_ code: Int64) -> Bool {
        if swallowed.contains(code) { return true }   // auto-repeat of a key we already ate
        switch state {
        case .armed:
            disarm(to: .spent)
            return false
        case .active:
            wheelKeyDownAt = nil
            if delegate?.wheelOpen == true {
                // The wheel has the keyboard: arrows turn it, esc/return close it.
                switch code {
                case Key.left, Key.up: delegate?.chordWheelStep(-1)
                case Key.right, Key.down: delegate?.chordWheelStep(1)
                case Key.escape, Key.returnKey, Key.enter: delegate?.chordWheelClose()
                case Key.delete, Key.forwardDelete: delegate?.chordUndo()
                default: break
                }
                swallowed.insert(code)
                return true
            }
            let hasShots = delegate?.sessionHasShots ?? false
            switch code {
            case Key.escape:
                end(to: .spent) { $0.chordCancelled() }
            case Key.delete, Key.forwardDelete:
                guard hasShots else {
                    end(to: .spent) { $0.chordCancelled() }
                    return false
                }
                delegate?.chordUndo()
            default:
                guard hasShots else {
                    // Nothing grabbed yet: this was a shortcut, not a capture.
                    end(to: .spent) { $0.chordCancelled() }
                    return false
                }
            }
            swallowed.insert(code)
            return true
        default:
            return false
        }
    }

    private func arm() {
        state = .armed
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.state == .armed else { return }
            let held = CGEventSource.flagsState(.combinedSessionState).intersection(Chord.relevant)
            guard held == self.chord.flags else { self.state = .idle; return }
            self.state = .active
            self.startWatchdog()
            self.delegate?.chordBegan()
        }
        arming = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.holdDelay, execute: work)
    }

    private func disarm(to next: State) {
        arming?.cancel()
        arming = nil
        state = next
    }

    private func end(to next: State = .idle, _ notify: (ChordMonitorDelegate) -> Void) {
        watchdog?.invalidate()
        watchdog = nil
        recordHeld = false
        state = next
        if let delegate { notify(delegate) }
    }

    /// Belt and braces: if the tap ever misses the release (secure input, a
    /// disabled tap), the overlay must still never get stuck on screen.
    private func startWatchdog() {
        watchdog = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.state == .active else { return }
                let held = CGEventSource.flagsState(.combinedSessionState).intersection(Chord.relevant)
                if !held.contains(self.chord.flags) { self.end { $0.chordReleased() } }
            }
        }
    }

    private func reset() {
        arming?.cancel()
        if state == .active { end { $0.chordCancelled() } }
        state = .idle
    }
}

private func chordTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                              refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<ChordMonitor>.fromOpaque(refcon).takeUnretainedValue()
    // The tap's run-loop source lives on the main run loop.
    let swallow = MainActor.assumeIsolated { monitor.handle(type, event) }
    return swallow ? nil : Unmanaged.passUnretained(event)
}
