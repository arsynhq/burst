import AppKit
import ImageIO

/// What the keyboard is doing right now, for the keycaps in the window.
final class LiveState: ObservableObject {
    @Published var held: CGEventFlags = []
    @Published var live = false
}

/// The bursts dropped since launch, newest first, with small thumbnails so
/// the tray never holds full-size pixels.
@MainActor
final class History: ObservableObject {
    struct Item: Identifiable {
        let id = UUID()
        let date: Date
        let shots: [Shot]
        let thumbs: [NSImage]
    }

    @Published private(set) var items: [Item] = []
    static let limit = 12

    func add(_ shots: [Shot]) {
        guard !shots.isEmpty else { return }
        Task {
            let thumbs = await Task.detached(priority: .utility) {
                shots.prefix(3).compactMap { $0.pngData().flatMap { Self.thumbnail($0) } }
            }.value
            items.insert(Item(date: Date(), shots: shots, thumbs: thumbs), at: 0)
            if items.count > Self.limit { items.removeLast(items.count - Self.limit) }
        }
    }

    /// Synthetic entries for the off-screen design renders.
    func seed(_ items: [Item]) { self.items = items }

    nonisolated static func thumbnail(_ png: Data, maxPixels: Int = 320) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil) else { return nil }
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                       kCGImageSourceThumbnailMaxPixelSize: maxPixels,
                       kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width / 2, height: image.height / 2))
    }
}
