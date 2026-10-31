import AppKit
import AVFoundation

/// `Burst --selftest` exercises the capture and clipboard plumbing without
/// showing an overlay or touching the real clipboard.
@MainActor
enum SelfTest {
    static func run() async -> Int32 {
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            print("\(ok ? "✓" : "✗") \(name)\(detail.isEmpty ? "" : "  (\(detail))")")
            if !ok { failures += 1 }
        }

        guard let screen = NSScreen.screens.first else { print("✗ no screen"); return 1 }
        let started = Date()
        do {
            let content = try await Capturer.content()
            check("shareable content", true, "\(Int(Date().timeIntervalSince(started) * 1000)) ms")

            let rect = CGRect(x: screen.frame.minX + 40, y: screen.frame.maxY - 160, width: 200, height: 120)
            let t0 = Date()
            let image = try await Capturer.region(rect, on: screen, content: content)
            let expected = Int(200 * screen.backingScaleFactor)
            check("region capture", image.width == expected, "\(image.width)×\(image.height) px in \(Int(Date().timeIntervalSince(t0) * 1000)) ms")

            if let window = WindowInfo.onScreen().first {
                let t1 = Date()
                let shot = try await Capturer.window(window.id, content: content)
                check("window capture", shot.width > 0, "\(shot.width)×\(shot.height) px in \(Int(Date().timeIntervalSince(t1) * 1000)) ms")
            } else {
                check("window capture", true, "skipped, no windows")
            }

            let shot = Shot(scale: screen.backingScaleFactor)
            shot.image = image
            await shot.prepare()
            let png = shot.pngData()
            check("png encode", png?.starts(with: [0x89, 0x50, 0x4E, 0x47]) == true, "\(png?.count ?? 0) bytes")

            // Lazy provider on a private pasteboard: nothing is served until read.
            let board = NSPasteboard(name: NSPasteboard.Name("com.mikesuastegui.handful.selftest"))
            board.clearContents()
            let provider = ShotProvider(shot: shot)
            let item = NSPasteboardItem()
            item.setDataProvider(provider, forTypes: [.png, .tiff])
            board.writeObjects([item])
            check("provider idle before read", provider.reads == 0)
            let read = board.data(forType: .png)
            check("provider serves on read", read == png && provider.reads == 1, "reads=\(provider.reads)")
            board.releaseGlobally()

            // A real 1.5 s recording of a small area, filed in a temp folder (no
            // controls on screen, clipboard untouched), then thrown away.
            let recorder = Recorder()
            let area = CGRect(x: screen.frame.minX + 40, y: screen.frame.maxY - 260, width: 320, height: 200)
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("burst-selftest-\(UUID().uuidString)")
            try await recorder.start(area: area, on: screen, sound: false, showControls: false)
            try await Task.sleep(for: .milliseconds(1500))
            if let file = await recorder.stop(sound: false, folder: folder, announce: false) {
                let seconds = try await AVURLAsset(url: file).load(.duration).seconds
                check("screen recording", seconds > 1, String(format: "%.1f s mp4", seconds))
                try? FileManager.default.removeItem(at: folder)
            } else {
                check("screen recording", false, "no file")
            }
        } catch {
            check("capture", false, error.localizedDescription)
        }
        print(failures == 0 ? "all passed" : "\(failures) failed")
        return failures == 0 ? 0 : 1
    }
}
