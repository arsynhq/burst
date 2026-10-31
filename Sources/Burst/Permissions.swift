import AppKit
import ApplicationServices
import CoreGraphics

enum Permissions {
    /// Watching the chord and posting ⌘V both need Accessibility.
    static var accessibility: Bool { AXIsProcessTrusted() }

    static func promptAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static var screenRecording: Bool { CGPreflightScreenCaptureAccess() }

    static func requestScreenRecording() { _ = CGRequestScreenCaptureAccess() }

    static var allGranted: Bool { accessibility && screenRecording }

    enum Pane: String {
        case accessibility = "Privacy_Accessibility"
        case screenRecording = "Privacy_ScreenCapture"
    }

    static func open(_ pane: Pane) {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)")!
        NSWorkspace.shared.open(url)
    }

    /// Screen Recording only takes effect after a relaunch.
    static func relaunch() {
        let path = Bundle.main.bundleURL.path
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.6; /usr/bin/open \"\(path)\""]
        try? task.run()
        NSApp.terminate(nil)
    }
}

/// Lets the crosshair stick while another app stays frontmost. Private
/// WindowServer property, looked up at runtime so a future macOS that drops it
/// just falls back to the arrow.
enum BackgroundCursor {
    static func enable() {
        typealias DefaultConnection = @convention(c) () -> Int32
        typealias SetProperty = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32
        guard let handle = dlopen(nil, RTLD_LAZY),
              let conn = dlsym(handle, "_CGSDefaultConnection"),
              let set = dlsym(handle, "CGSSetConnectionProperty") else { return }
        let cid = unsafeBitCast(conn, to: DefaultConnection.self)()
        _ = unsafeBitCast(set, to: SetProperty.self)(cid, cid, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
    }
}
