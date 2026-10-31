import AppKit
import CoreGraphics

/// Serves one shot's bytes only when an app actually reads them, and tells us
/// when that happened, which is how a paste knows the target took it.
final class ShotProvider: NSObject, NSPasteboardItemDataProvider {
    let shot: Shot
    private(set) var reads = 0

    init(shot: Shot) { self.shot = shot }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        reads += 1
        switch type {
        case .png: if let data = shot.pngData() { item.setData(data, forType: .png) }
        case .tiff: if let data = shot.tiffData() { item.setData(data, forType: .tiff) }
        default: break
        }
    }

    func resetReads() { reads = 0 }
}

@MainActor
enum Clipboard {
    private static var providers: [ShotProvider] = []

    /// Every shot as its own clipboard item: apps that take several get all of them.
    @discardableResult
    static func put(_ shots: [Shot]) -> [ShotProvider] {
        // Undoing the last shot leaves the clipboard alone rather than wiping it.
        guard !shots.isEmpty else { return [] }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        providers = shots.map(ShotProvider.init)
        let items = providers.map { provider -> NSPasteboardItem in
            let item = NSPasteboardItem()
            // PNG only: every target reads it, and a TIFF of a Retina screen is
            // tens of MB built on the main thread for whoever asks first.
            item.setDataProvider(provider, forTypes: [.png])
            return item
        }
        pasteboard.writeObjects(items)
        return providers
    }

    static func put(files: [URL]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        providers = []
        pasteboard.writeObjects(files as [NSURL])
    }
}

/// What one release does: whether (and how) to paste, and whether to save.
/// The setup screen gives the default; the aperture can pick another per burst.
struct DropPlan {
    enum Paste { case none, oneByOne, files }
    var paste: Paste
    var save: Bool
}

/// Puts a finished burst where it belongs: the front app, the clipboard, and
/// (when asked) a folder.
@MainActor
final class Dropper {
    private let prefs: Prefs
    private(set) var lastDrop: [Shot] = [] { didSet { onDropped?(lastDrop) } }
    var onDropped: (([Shot]) -> Void)?

    init(prefs: Prefs) { self.prefs = prefs }

    /// Terminals paste text on ⌘V; Claude Code reads clipboard images on ⌃V.
    private static let terminals: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable",
        "com.github.wez.wezterm", "net.kovidgoyal.kitty", "org.alacritty", "co.zeit.hyper",
    ]

    /// Shots may still be capturing or encoding when this starts: each is
    /// awaited just before its own paste, so the first lands while the last is
    /// still being encoded. `pasted` fires as each shot lands (the pile counts
    /// down); `landed` fires once the front app has them all.
    func drop(_ pending: [Shot], plan: DropPlan, into target: NSRunningApplication? = nil,
              pasted: (Shot) -> Void = { _ in }, landed: () -> Void = {}) async {
        var shots: [Shot] = []
        var saved: [URL] = []

        if plan.paste != .none && !pending.isEmpty {
            await Self.waitForModifiersUp()
            await Self.bringForward(target)
            switch plan.paste {
            case .none:
                break
            case .oneByOne:
                let bundle = (target ?? NSWorkspace.shared.frontmostApplication)?.bundleIdentifier ?? ""
                let control = Self.terminals.contains(bundle)
                for shot in pending {
                    await shot.task?.value
                    guard shot.image != nil else { continue }
                    shots.append(shot)
                    let provider = Clipboard.put([shot])[0]
                    await paste(control: control, readBy: provider)
                    pasted(shot)
                }
            case .files:
                shots = await Self.ready(pending)
                // The only path that needs files before the paste.
                if plan.save { saved = await save(shots, to: prefs.saveFolder) }
                let files = saved.isEmpty ? await save(shots, to: Self.scratchFolder()) : saved
                Clipboard.put(files: files)
                Self.postPaste(control: false)
                try? await Task.sleep(for: .milliseconds(150))
            }
        } else {
            shots = await Self.ready(pending)
        }
        landed()
        guard !shots.isEmpty else { return }
        lastDrop = shots

        // Saving never holds up the paste.
        if plan.save && saved.isEmpty { _ = await save(shots, to: prefs.saveFolder) }

        // Whatever happened, the clipboard ends up holding the whole burst,
        // after a beat so a slow app still finds the last shot it was sent.
        if plan.paste != .files {   // that path already holds the files
            if plan.paste != .none { try? await Task.sleep(for: .milliseconds(300)) }
            Clipboard.put(shots)
        }
        shots.forEach { $0.compact() }
    }

    /// ⌘V goes to whichever app is frontmost, so make sure it's the one the
    /// hold started in.
    private static func bringForward(_ target: NSRunningApplication?) async {
        guard let target, !target.isTerminated,
              NSWorkspace.shared.frontmostApplication?.processIdentifier != target.processIdentifier else { return }
        target.activate()
        for _ in 0..<25 {
            try? await Task.sleep(for: .milliseconds(20))
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier { break }
        }
    }

    private static func ready(_ pending: [Shot]) async -> [Shot] {
        for shot in pending { await shot.task?.value }
        return pending.filter { $0.image != nil }
    }

    func copyLastAgain() {
        if !lastDrop.isEmpty { Clipboard.put(lastDrop) }
    }

    /// Posts the paste, then waits until the target has read the image so the
    /// next shot never overwrites one still in transit.
    ///
    /// A read isn't proof on its own: macOS's clipboard history, Wispr Flow and
    /// 1Password all read the clipboard the moment it changes. So watchers get a
    /// beat to take their copy before the count starts, and a read only counts
    /// once the target has had a short floor of time with the shot.
    /// About 0.23s a shot; an app that never reads gets 0.9s before moving on.
    private func paste(control: Bool, readBy provider: ShotProvider) async {
        try? await Task.sleep(for: .milliseconds(50))
        provider.resetReads()
        let start = Date()
        Self.postPaste(control: control)
        while true {
            try? await Task.sleep(for: .milliseconds(10))
            let elapsed = Date().timeIntervalSince(start)
            if (provider.reads > 0 && elapsed > 0.12) || elapsed > 0.9 { break }
        }
        try? await Task.sleep(for: .milliseconds(60))
    }

    static func postPaste(control: Bool) {
        let source = CGEventSource(stateID: .hidSystemState)
        let flags: CGEventFlags = control ? .maskControl : .maskCommand
        let v: CGKeyCode = 9   // kVK_ANSI_V
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: down)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
    }

    /// The chord's keys must be fully up or the target sees ⌃⌥⌘V and the first
    /// shot never lands. A slow second finger is normal, so wait for it.
    private static func waitForModifiersUp() async {
        let start = Date()
        while Date().timeIntervalSince(start) < 3 {
            let held = CGEventSource.flagsState(.hidSystemState).intersection(Chord.relevant)
            if held.isEmpty { return }
            try? await Task.sleep(for: .milliseconds(16))
        }
    }

    // MARK: Files

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd 'at' h.mm.ss a"
        return f
    }()

    static func scratchFolder() -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("com.mikesuastegui.handful/drops/\(UUID().uuidString)", isDirectory: true)
    }

    /// Files named the way macOS names screenshots: "Burst 2026-10-30 at 2.32.05 PM (2 of 3).png".
    private func save(_ shots: [Shot], to folder: URL) async -> [URL] {
        let base = "Burst \(Self.stamp.string(from: Date()))"
        return await Task.detached(priority: .userInitiated) {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return shots.enumerated().compactMap { i, shot -> URL? in
                let name = shots.count > 1 ? "\(base) (\(i + 1) of \(shots.count)).png" : "\(base).png"
                let url = folder.appendingPathComponent(name)
                guard let data = shot.pngData(), (try? data.write(to: url, options: .atomic)) != nil else { return nil }
                return url
            }
        }.value
    }

    /// Scratch copies from "as files" drops only need to outlive the paste.
    static func sweepScratch() {
        let root = scratchFolder().deletingLastPathComponent()
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-24 * 3600)
        for item in items {
            let created = (try? item.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
            if created < cutoff { try? fm.removeItem(at: item) }
        }
    }
}
