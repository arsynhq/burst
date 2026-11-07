import AppKit
import AVFoundation
import ScreenCaptureKit
import SwiftUI

/*
 DIRECTION CONTRACT — recording

 THESIS: The hold that grabs screenshots also records video: add the next
 finger (⌘ for ⌃⌥), drag an area, and it's recording. Once it starts it runs
 hands-free, so the area can be demoed with mouse and keyboard.

 OWN-WORLD: Burst's monochrome, with one exception that means one thing: red
 = recording. A thin red frame just outside the area, a black capsule with a
 red dot, a mono timer and Stop. All of it is Burst's own windows, left out of
 the video.

 FINISH: unreviewed and undocumented is unfinished; this build ends with the
 finish review, the verdict, and DESIGN.md
*/

final class RecordingModel: ObservableObject {
    @Published var seconds = 0
    var text: String { String(format: "%d:%02d", seconds / 60, seconds % 60) }
}

/// Records one area of one display to an MP4, then files it in Downloads and
/// puts it on the clipboard.
@MainActor
final class Recorder: NSObject {
    private(set) var isRecording = false
    var onChange: (() -> Void)?

    private var stream: SCStream?
    private var tempURL: URL?
    private var finished: CheckedContinuation<Void, Never>?
    private let sink = FrameSink()
    private var panels: [NSPanel] = []
    private var ticker: Timer?
    private let model = RecordingModel()
    private var started = Date()
    private var screen: NSScreen?

    private static let sounds = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/"
    private let beginSound = NSSound(contentsOfFile: sounds + "begin_record.caf", byReference: true)
    private let endSound = NSSound(contentsOfFile: sounds + "end_record.caf", byReference: true)

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd 'at' h.mm.ss a"
        return f
    }()

    /// `area` is in Cocoa global coordinates and is clipped to `screen`.
    func start(area: CGRect, on screen: NSScreen, sound: Bool, showControls: Bool = true) async throws {
        guard !isRecording else { return }
        let content = try await Capturer.content()
        guard let id = screen.displayID, let display = content.displays.first(where: { $0.displayID == id }) else {
            throw CaptureError.noDisplay
        }
        let me = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])
        let clipped = area.intersection(screen.frame).integral
        let local = CGRect(x: clipped.minX - screen.frame.minX, y: screen.frame.maxY - clipped.maxY,
                           width: clipped.width, height: clipped.height)
        let scale = CGFloat(filter.pointPixelScale)
        // H.264 wants even dimensions.
        func even(_ v: CGFloat) -> Int { max(2, Int((v * scale).rounded()) & ~1) }

        let config = SCStreamConfiguration()
        config.sourceRect = local
        config.width = even(local.width)
        config.height = even(local.height)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.showsCursor = true
        config.queueDepth = 6
        config.captureResolution = .best
        config.colorSpaceName = CGColorSpace.sRGB

        // macOS occasionally refuses the first start ("audio/video capture
        // failure"); a fresh stream a moment later goes through.
        var attempt = 0
        var launched: (SCStream, URL)?
        while launched == nil {
            attempt += 1
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("burst-\(UUID().uuidString).mp4")
            let recording = SCRecordingOutputConfiguration()
            recording.outputURL = url
            recording.outputFileType = .mp4
            recording.videoCodecType = .h264
            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            do {
                try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: sink.queue)
                try stream.addRecordingOutput(SCRecordingOutput(configuration: recording, delegate: self))
                try await stream.startCapture()
                launched = (stream, url)
            } catch {
                burstLog.error("recording start \(attempt, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                if attempt >= 3 { throw error }
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
        guard let (stream, url) = launched else { return }

        self.stream = stream
        self.tempURL = url
        self.screen = screen
        isRecording = true
        started = Date()
        model.seconds = 0
        if sound { beginSound?.stop(); beginSound?.play() }
        if showControls { showControlsAround(clipped, on: screen) }
        ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let s = Int(Date().timeIntervalSince(self.started))
                if s != self.model.seconds { self.model.seconds = s }
            }
        }
        burstLog.info("recording \(config.width, privacy: .public)x\(config.height, privacy: .public)")
        onChange?()
    }

    /// Stops, waits for the file to be finished, and files it. `folder` nil
    /// means Downloads; `announce` puts it on the clipboard and shows the note.
    @discardableResult
    func stop(sound: Bool, folder: URL? = nil, announce: Bool = true) async -> URL? {
        guard isRecording, let stream, let tempURL else { return nil }
        isRecording = false
        ticker?.invalidate()
        ticker = nil
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
        if sound { endSound?.stop(); endSound?.play() }
        onChange?()

        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            finished = done
            Task {
                try? await stream.stopCapture()
                // The recording output reports when the file is complete; never wait forever.
                try? await Task.sleep(for: .seconds(4))
                self.resumeFinished()
            }
        }
        self.stream = nil
        self.tempURL = nil

        let fm = FileManager.default
        let dir = folder ?? fm.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let base = "Burst Recording \(Self.stamp.string(from: started))"
        var dest = dir.appendingPathComponent(base + ".mp4")
        var n = 2
        while fm.fileExists(atPath: dest.path) {
            dest = dir.appendingPathComponent("\(base) \(n).mp4")
            n += 1
        }
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try fm.moveItem(at: tempURL, to: dest)
        } catch {
            burstLog.error("couldn't file the recording: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        if announce {
            Clipboard.put(files: [dest])
            if let screen { Toast.show("Saved to Downloads", file: dest, on: screen) }
        }
        return dest
    }

    fileprivate func resumeFinished() {
        finished?.resume()
        finished = nil
    }

    // MARK: Controls

    private func showControlsAround(_ area: CGRect, on screen: NSScreen) {
        let frame = BorderPanel(around: area)
        frame.orderFrontRegardless()

        let pill = ClickPanel(content: RecordingPill(model: model) { [weak self] in
            guard let self else { return }
            Task { await self.stop(sound: Prefs.shared.playSound) }
        })
        let size = pill.frame.size
        let visible = screen.visibleFrame
        var origin = CGPoint(x: area.midX - size.width / 2, y: area.minY - 12 - size.height)
        if origin.y < visible.minY + 8 { origin.y = area.maxY + 12 }                    // no room below
        if origin.y + size.height > visible.maxY - 8 { origin.y = area.minY + 16 }     // full screen: inside
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        pill.setFrameOrigin(origin)
        pill.orderFrontRegardless()
        panels = [frame, pill]
    }
}

extension Recorder: SCStreamDelegate, SCRecordingOutputDelegate {
    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor in self.resumeFinished() }
    }

    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        burstLog.error("recording failed: \(error.localizedDescription, privacy: .public)")
        Task { @MainActor in self.resumeFinished() }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        burstLog.error("recording stream stopped: \(error.localizedDescription, privacy: .public)")
        Task { @MainActor in
            if self.isRecording { await self.stop(sound: false) }
        }
    }
}

/// The recording output writes the file; frames still need somewhere to go.
private final class FrameSink: NSObject, SCStreamOutput {
    let queue = DispatchQueue(label: "burst.recording.frames")
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {}
}

// MARK: - Recording chrome

/// A thin red frame just outside the recorded area. Never takes a click.
private final class BorderPanel: NSPanel {
    init(around area: CGRect) {
        let pad: CGFloat = 4
        super.init(contentRect: area.insetBy(dx: -pad, dy: -pad), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        sharingType = .none          // the red frame is never in the video
        let view = NSView(frame: CGRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        view.layer?.borderColor = Look.recordRed.cgColor
        view.layer?.borderWidth = 1.5
        view.layer?.cornerRadius = 3
        contentView = view
    }

    override var canBecomeKey: Bool { false }
}

/// A small floating panel whose buttons work without activating Burst, so the
/// app being recorded keeps focus.
final class ClickPanel<Content: View>: NSPanel {
    init(content: Content) {
        let host = FirstMouseHostingView(rootView: content)
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        super.init(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        sharingType = .none          // controls and toasts stay out of captures
        host.frame = CGRect(origin: .zero, size: size)
        contentView = host
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func shouldDelayWindowOrdering(for event: NSEvent) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        NSApp.preventWindowOrdering()
        super.mouseDown(with: event)
    }
}

private let pillBlack = Color(red: 0.043, green: 0.047, blue: 0.055)

struct RecordingPill: View {
    @ObservedObject var model: RecordingModel
    let stop: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Color(nsColor: Look.recordRed))
                .frame(width: 8, height: 8)
            Text(model.text)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.white)
            Button(action: stop) {
                HStack(spacing: 5) {
                    Image(systemName: "stop.fill").font(.system(size: 9, weight: .bold))
                    Text("Stop").font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(Capsule().fill(Color.white.opacity(0.14)))
                .contentShape(Capsule())
            }
            .buttonStyle(Pressable())
            .help("Stop recording")
        }
        .padding(.leading, 13)
        .padding(.trailing, 5)
        .frame(height: 34)
        .background(Capsule().fill(pillBlack))
        .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
        .padding(1)
        .fixedSize()
    }
}

/// "Saved to Downloads · Show", bottom centre, for a few seconds.
@MainActor
enum Toast {
    private static var current: NSPanel?

    static func show(_ message: String, file: URL, on screen: NSScreen) {
        current?.orderOut(nil)
        let panel = ClickPanel(content: ToastView(message: message) {
            NSWorkspace.shared.activateFileViewerSelecting([file])
        })
        let size = panel.frame.size
        let v = screen.visibleFrame
        panel.setFrameOrigin(CGPoint(x: v.midX - size.width / 2, y: v.minY + 48))
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = Motion.easeOut
            panel.animator().alphaValue = 1
        }
        current = panel
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
            guard current === panel else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.18
                ctx.timingFunction = Motion.easeOut
                panel.animator().alphaValue = 0
            }, completionHandler: {
                MainActor.assumeIsolated {
                    panel.orderOut(nil)
                    if current === panel { current = nil }
                }
            })
        }
    }
}

struct ToastView: View {
    let message: String
    let show: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.white)
            Text(message).foregroundStyle(.white)
            Button("Show", action: show)
                .buttonStyle(Pressable())
                .foregroundStyle(.white)
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(Capsule().fill(Color.white.opacity(0.14)))
        }
        .font(.system(size: 13, weight: .medium))
        .padding(.leading, 14)
        .padding(.trailing, 5)
        .frame(height: 34)
        .background(Capsule().fill(pillBlack))
        .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
        .padding(1)
        .fixedSize()
    }
}
