import AppKit
import Combine
import SwiftUI

@MainActor
final class AppController: NSObject, NSApplicationDelegate, ChordMonitorDelegate, NSMenuDelegate {
    let prefs = Prefs.shared
    private let monitor = ChordMonitor()
    private lazy var dropper = Dropper(prefs: prefs)
    private var session: Session?
    private var statusItem: NSStatusItem!
    private var homeWindow: NSWindow?
    private let recorder = Recorder()
    private var quietUntil = Date.distantPast
    /// The app that was frontmost when the hold began: where the shots go.
    private var dropTarget: NSRunningApplication?
    let live = LiveState()
    let history = History()
    private var trustPoll: Timer?
    private var bag = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ note: Notification) {
        BackgroundCursor.enable()
        Dropper.sweepScratch()
        buildStatusItem()

        monitor.delegate = self
        monitor.chord = prefs.chord
        monitor.onFlags = { [weak self] held in
            guard let self, self.live.held != held else { return }
            self.live.held = held
        }
        dropper.onDropped = { [weak self] shots in self?.history.add(shots) }
        recorder.onChange = { [weak self] in self?.refreshStatusIcon() }
        prefs.$chord.dropFirst().sink { [weak self] in self?.monitor.chord = $0 }.store(in: &bag)

        if !startMonitor() {
            Permissions.promptAccessibility()
            trustPoll = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] timer in
                MainActor.assumeIsolated {
                    if self?.startMonitor() == true { timer.invalidate() }
                }
            }
        }
        // Asking is what puts Burst in the Screen Recording list at all.
        if !Permissions.screenRecording { Permissions.requestScreenRecording() }
        if !Permissions.allGranted { showHome() }
    }

    /// Opening the app again (Spotlight, Finder, Dock) brings up the window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Never in the middle of, or right after, a grab: only a deliberate open.
        if session == nil && Date() > quietUntil { showHome() }
        return false
    }

    /// Belt and braces: if anything ever makes Burst active during a grab,
    /// hand focus straight back to the app the shots are going into.
    func applicationDidBecomeActive(_ note: Notification) {
        guard session != nil || Date() < quietUntil, let target = dropTarget else { return }
        target.activate()
    }

    private func startMonitor() -> Bool {
        Permissions.accessibility && monitor.start()
    }

    // MARK: ChordMonitorDelegate

    var sessionHasShots: Bool { !(session?.shots.isEmpty ?? true) }

    func chordBegan() {
        guard session == nil else { return }
        // Holding the chord while recording stops the recording.
        if recorder.isRecording {
            Task { await recorder.stop(sound: prefs.playSound) }
            return
        }
        live.live = true
        let front = NSWorkspace.shared.frontmostApplication
        dropTarget = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
        let s = Session(prefs: prefs)
        s.onShotsChanged = { shots in Clipboard.put(shots) }   // the clipboard holds them while you hold
        s.onRecord = { [weak self, weak s] area, screen in
            guard let self, let s else { return }
            self.beginRecording(area, on: screen, from: s)
        }
        session = s
        s.begin()
    }

    func chordReleased() {
        live.live = false
        quietUntil = Date().addingTimeInterval(2)
        guard let s = session else { return }
        session = nil
        // The wheel's slice decides; an unopened wheel is the setup screen's default.
        guard let plan = s.wheel.selection.plan else {
            Task { _ = await s.finish(.cancel) }
            return
        }
        monitor.suspended = true
        Task {
            let shots = await s.finish(.drop)
            await dropper.drop(shots, plan: plan, into: dropTarget, pasted: { s.peel($0) }, landed: { s.close() })
            monitor.suspended = false
        }
    }

    func chordCancelled() {
        live.live = false
        quietUntil = Date().addingTimeInterval(2)
        guard let s = session else { return }
        session = nil
        Task { _ = await s.finish(.cancel) }
    }

    func chordUndo() { session?.undo() }

    func chordRecordKey(_ held: Bool) { session?.setRecordMode(held) }

    /// The area is picked: the lens goes, recording starts at once and runs
    /// hands-free. Shots taken earlier in the same hold still go out.
    private func beginRecording(_ area: CGRect, on screen: NSScreen, from s: Session) {
        guard session === s else { return }
        session = nil
        live.live = false
        quietUntil = Date().addingTimeInterval(2)
        monitor.suspended = true
        let plan = s.wheel.selection.plan
        let target = dropTarget
        Task {
            let shots = await s.finish(.drop)
            do {
                try await recorder.start(area: area, on: screen, sound: prefs.playSound)
            } catch {
                burstLog.error("couldn't start recording: \(error.localizedDescription, privacy: .public)")
            }
            if let plan, !shots.isEmpty {
                await dropper.drop(shots, plan: plan, into: target, pasted: { s.peel($0) }, landed: { s.close() })
            } else {
                s.close()
            }
            monitor.suspended = false
        }
    }

    var wheelOpen: Bool { session?.wheel.isOpen ?? false }
    func chordWheelToggle() { session?.toggleWheel() }
    func chordWheelStep(_ delta: Int) { session?.stepWheel(delta) }
    func chordWheelClose() { session?.closeWheel() }
    func pointerDown(_ point: CGPoint) { session?.pointerDown(point) }
    func pointerDragged(_ point: CGPoint) { session?.pointerDragged(point) }
    func pointerUp(_ point: CGPoint) { session?.pointerUp(point) }

    // MARK: Menu bar

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        refreshStatusIcon()
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    /// A record dot in the menu bar while a recording runs.
    private func refreshStatusIcon() {
        let name = recorder.isRecording ? "record.circle" : "photo.stack"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: recorder.isRecording ? "Burst, recording" : "Burst")
        image?.isTemplate = true
        statusItem?.button?.image = image
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        if recorder.isRecording {
            menu.addItem(item("Stop Recording", #selector(stopRecording), symbol: "stop.circle"))
            menu.addItem(.separator())
        }
        let header = NSMenuItem(title: "Hold \(prefs.chord.symbols) to grab · add \(Chord.symbol(prefs.chord.recordKey)) to record",
                                action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        if !Permissions.accessibility {
            menu.addItem(item("Allow Accessibility…", #selector(allowAccessibility), symbol: "exclamationmark.triangle"))
        }
        if !Permissions.screenRecording {
            menu.addItem(item("Allow Screen Recording…", #selector(allowScreenRecording), symbol: "exclamationmark.triangle"))
        }

        menu.addItem(.separator())
        let again = item("Copy Last Burst Again", #selector(copyAgain), symbol: "doc.on.clipboard")
        again.isEnabled = !dropper.lastDrop.isEmpty
        menu.addItem(again)
        menu.addItem(item("Show Saved Shots", #selector(showFolder), symbol: "folder"))

        menu.addItem(.separator())
        let letGo = NSMenuItem(title: "When you let go", action: nil, keyEquivalent: "")
        letGo.isEnabled = false
        menu.addItem(letGo)
        for action in WheelAction.defaults {
            let choice = item(action.title, #selector(pickDefault(_:)), symbol: action.symbol)
            choice.tag = action.rawValue
            choice.state = prefs.defaultAction == action ? .on : .off
            menu.addItem(choice)
        }

        menu.addItem(.separator())
        menu.addItem(item("Open \(AppInfo.name)", #selector(openHome), key: ","))
        menu.addItem(item("Quit Burst", #selector(NSApplication.terminate(_:)), key: "q", target: NSApp))
    }

    private func item(_ title: String, _ action: Selector, key: String = "", symbol: String? = nil,
                      target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = target ?? self
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        return item
    }

    @objc private func copyAgain() { dropper.copyLastAgain() }
    @objc private func stopRecording() { Task { await recorder.stop(sound: prefs.playSound) } }
    @objc private func pickDefault(_ sender: NSMenuItem) {
        if let action = WheelAction(rawValue: sender.tag) { prefs.defaultAction = action }
    }
    @objc private func openHome() { showHome() }

    @objc private func showFolder() {
        try? FileManager.default.createDirectory(at: prefs.saveFolder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(prefs.saveFolder)
    }

    @objc private func allowAccessibility() {
        Permissions.promptAccessibility()
        Permissions.open(.accessibility)
    }

    @objc private func allowScreenRecording() {
        Permissions.requestScreenRecording()
        Permissions.open(.screenRecording)
    }

    // MARK: Home window

    func showHome() {
        if homeWindow == nil {
            let view = HomeView(prefs: prefs, live: live, history: history) { shots in Clipboard.put(shots) }
            let host = NSHostingController(rootView: view)
            host.sizingOptions = [.preferredContentSize]
            let window = NSWindow(contentViewController: host)
            window.title = AppInfo.name
            window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.backgroundColor = .windowBackgroundColor
            window.isReleasedWhenClosed = false
            window.setContentSize(AppInfo.windowSize)
            window.center()
            homeWindow = window
        }
        NSApp.activate()
        homeWindow?.makeKeyAndOrderFront(nil)
    }
}
