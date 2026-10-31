import AppKit
import QuartzCore

/*
 DIRECTION CONTRACT — Burst capture lens

 THESIS: The hold is the session. A lens laid over the screen, not a screenshot
 editor. It refuses the capture-app arrangement: no mode toolbar, no annotation
 tools, no floating preview asking for a decision after every shot.

 OWN-WORLD: macOS's own capture grammar played straight (⌘⇧4 / ⌘⇧5). A light
 black scrim, the selection punched clear with a white hairline and a dark HUD
 size tag, hovered windows ringed in the user's accent colour. One dark HUD
 capsule in system material and the system font carries all state. The single
 signature move: each shot lifts off the screen and lands in a loosely fanned
 pile, bottom-right, where macOS already puts its screenshot thumbnail.

 STORY: Hold ⌃⌥, drag, drag, click a window, let go. The shots are in the chat
 box, and the chat box never lost focus.

 FIRST VIEWPORT: Screen dims ~22%. HUD capsule centred under the menu bar:
 "Drag an area or click a window", with ⎋ Cancel. Crosshair cursor.

 FORM: Native canon, pinned by Mike's standing rule (native grammar over
 costume); built to sit beside ⌘⇧5, CleanShot X and Shottr. No concept roll
 and no seed key: the pinned brief waives the roll, and a themed concept would
 break the rule.

 FINISH: unreviewed and undocumented is unfinished; this build ends with the
 finish review, the verdict, and DESIGN.md
*/

enum Look {
    /// Just enough to say "on": the hold should never feel like it took the screen.
    static let scrim = NSColor.black.withAlphaComponent(0.10)
    /// The only colour in Burst: it means a recording is (about to be) running.
    static let recordRed = NSColor(srgbRed: 1, green: 0.27, blue: 0.23, alpha: 1)
    static let ringWidth: CGFloat = 2
    /// macOS 26 rounds windows much more; the ring hugs the real corner.
    static let windowRadius: CGFloat =
        ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)) ? 18 : 10
    static let hudHeight: CGFloat = 36
    static let hudGap: CGFloat = 12          // below the menu bar
    static let pileInset: CGFloat = 32       // from the visible frame's corner
    static let thumbBox = CGSize(width: 184, height: 128)
    static let thumbMin: CGFloat = 36
    static let cardRadius: CGFloat = 8
    static let pileDepth = 6                 // cards drawn before older ones hide
    /// Degrees. Loose, hand-held, never the same twice in a row.
    static let tilts: [CGFloat] = [-2.5, 2.0, -1.0, 3.0, -3.5, 1.5]
    static let nudges: [CGPoint] = [
        .zero, CGPoint(x: 6, y: 2), CGPoint(x: -4, y: 4),
        CGPoint(x: 8, y: 5), CGPoint(x: -6, y: 7), CGPoint(x: 3, y: 9),
    ]
}

enum Motion {
    static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Strong ease-out for everything, arriving and leaving: no ease-in, it
    /// delays the first frames, which are the ones being watched.
    static let easeOut = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)

    /// The overlay follows a keyboard hold, so its fades only exist to stop a
    /// full-screen dim from popping; exits are quicker than entrances.
    static let overlayIn: TimeInterval = 0.12
    static let overlayOut: TimeInterval = 0.12
    static let flight = 0.42                 // perceptual duration of the lift (Apple's reposition response)
    static let flightBounce = 0.12           // the drag carried momentum; a touch of settle

    static func spring(_ keyPath: String, from: Any?, to: Any?,
                       duration: Double = flight, bounce: Double = flightBounce) -> CAAnimation {
        let a = CASpringAnimation(perceptualDuration: duration, bounce: bounce)
        a.keyPath = keyPath
        a.fromValue = from
        a.toValue = to
        a.duration = a.settlingDuration
        return a
    }

    static func basic(_ keyPath: String, from: Any?, to: Any?,
                      duration: Double, timing: CAMediaTimingFunction = easeOut) -> CAAnimation {
        let a = CABasicAnimation(keyPath: keyPath)
        a.fromValue = from
        a.toValue = to
        a.duration = duration
        a.timingFunction = timing
        return a
    }
}

extension CGRect {
    var mid: CGPoint { CGPoint(x: midX, y: midY) }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
