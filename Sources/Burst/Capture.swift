import AppKit
import ScreenCaptureKit
import UniformTypeIdentifiers

/// One grab. The image arrives a few frames after the gesture; PNG bytes are
/// encoded once, off the main thread, and shared by clipboard, paste and save.
final class Shot: @unchecked Sendable {
    let id = UUID()
    let scale: CGFloat
    var image: CGImage?
    var task: Task<Void, Never>?
    private var png: Data?
    private let lock = NSLock()

    init(scale: CGFloat) { self.scale = scale }

    func pngData() -> Data? {
        lock.lock(); defer { lock.unlock() }
        if let png { return png }
        guard let image else { return nil }
        png = Self.encodePNG(image, scale: scale)
        return png
    }

    func tiffData() -> Data? {
        if let image { return NSBitmapImageRep(cgImage: image).tiffRepresentation }
        return pngData().flatMap { NSBitmapImageRep(data: $0)?.tiffRepresentation }
    }

    /// After the drop only the compressed bytes are kept: "Copy Last Burst
    /// Again" shouldn't pin a few hundred MB of raw Retina pixels.
    func compact() {
        guard pngData() != nil else { return }
        lock.lock(); defer { lock.unlock() }
        image = nil
    }

    func prepare() async {
        await Task.detached(priority: .userInitiated) { _ = self.pngData() }.value
    }

    private static func encodePNG(_ image: CGImage, scale: CGFloat) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        // Same 144 dpi tag macOS screenshots carry, so native apps show them at point size.
        let dpi = 72 * scale
        CGImageDestinationAddImage(dest, image, [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }
}

/// A normal app window on screen, front to back, from the window server's list.
struct WindowInfo {
    let id: CGWindowID
    let frame: CGRect   // Cocoa global coordinates (bottom-left origin)

    static func onScreen() -> [WindowInfo] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]],
              let primary = NSScreen.screens.first else { return [] }
        let me = ProcessInfo.processInfo.processIdentifier
        return list.compactMap { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  (info[kCGWindowOwnerPID as String] as? pid_t) != me,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0.01,
                  let number = info[kCGWindowNumber as String] as? CGWindowID,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let cg = CGRect(dictionaryRepresentation: bounds),
                  cg.width >= 40, cg.height >= 40 else { return nil }
            let cocoa = CGRect(x: cg.minX, y: primary.frame.height - cg.maxY, width: cg.width, height: cg.height)
            return WindowInfo(id: number, frame: cocoa)
        }
    }
}

enum CaptureError: LocalizedError {
    case noPermission, noDisplay, noWindow
    var errorDescription: String? {
        switch self {
        case .noPermission: "Burst needs Screen Recording access"
        case .noDisplay: "That display went away"
        case .noWindow: "That window closed"
        }
    }
}

enum Capturer {
    static func content() async throws -> SCShareableContent {
        do {
            return try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw Permissions.screenRecording ? error : CaptureError.noPermission
        }
    }

    /// Captures a rectangle (Cocoa global coordinates) of one display, leaving
    /// Burst's own overlay out of the picture.
    static func region(_ rect: CGRect, on screen: NSScreen, content: SCShareableContent) async throws -> CGImage {
        guard let id = screen.displayID,
              let display = content.displays.first(where: { $0.displayID == id }) else { throw CaptureError.noDisplay }
        let me = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])
        let local = CGRect(x: rect.minX - screen.frame.minX, y: screen.frame.maxY - rect.maxY,
                           width: rect.width, height: rect.height)
        let scale = CGFloat(filter.pointPixelScale)
        let config = SCStreamConfiguration()
        config.sourceRect = local
        config.width = max(1, Int((local.width * scale).rounded()))
        config.height = max(1, Int((local.height * scale).rounded()))
        config.showsCursor = false
        config.captureResolution = .best
        config.colorSpaceName = CGColorSpace.sRGB
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    /// Captures one window on its own, shadow and background excluded.
    static func window(_ id: CGWindowID, content: SCShareableContent) async throws -> CGImage {
        var window = content.windows.first(where: { $0.windowID == id })
        if window == nil {   // opened after the session started
            window = try await Self.content().windows.first(where: { $0.windowID == id })
        }
        guard let window else { throw CaptureError.noWindow }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = CGFloat(filter.pointPixelScale)
        let config = SCStreamConfiguration()
        config.width = max(1, Int((window.frame.width * scale).rounded()))
        config.height = max(1, Int((window.frame.height * scale).rounded()))
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        config.captureResolution = .best
        config.colorSpaceName = CGColorSpace.sRGB
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }
}
