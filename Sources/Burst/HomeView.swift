import AppKit
import ServiceManagement
import SwiftUI

final class AccessModel: ObservableObject {
    @Published var accessibility = Permissions.accessibility
    @Published var screenRecording = Permissions.screenRecording
    private var timer: Timer?

    var allGranted: Bool { accessibility && screenRecording }

    func watch() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            let ax = Permissions.accessibility, sr = Permissions.screenRecording
            if ax != self.accessibility { self.accessibility = ax }
            if sr != self.screenRecording { self.screenRecording = sr }
        }
    }

    func stop() { timer?.invalidate(); timer = nil }
}

enum AppInfo {
    static let name = "Burst"
    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0" }
    static let windowSize = CGSize(width: 500, height: 820)
}

/// The setup window: the shortcut as real keys, then a plain Mac form.
struct HomeView: View {
    @ObservedObject var prefs: Prefs
    @ObservedObject var live: LiveState
    @ObservedObject var history: History
    var copy: ([Shot]) -> Void = { _ in }
    @StateObject private var access = AccessModel()
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(spacing: 0) {
            hero
            Form {
                // Missing permissions are the only thing that matters until fixed.
                if !access.allGranted { permissions }
                shortcut
                letGo
                if !history.items.isEmpty { recent }
                saving
                general
                if access.allGranted { permissions }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
        .frame(width: AppInfo.windowSize.width, height: AppInfo.windowSize.height)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { access.watch() }
        .onDisappear { access.stop() }
    }

    // MARK: Hero

    private var keys: [(symbol: String, word: String, flag: CGEventFlags)] {
        let all: [(String, String, CGEventFlags)] = [
            ("⌃", "control", .maskControl), ("⌥", "option", .maskAlternate),
            ("⇧", "shift", .maskShift), ("⌘", "command", .maskCommand),
        ]
        return all.filter { prefs.chord.flags.contains($0.2) }.map { ($0.0, $0.1, $0.2) }
    }

    private var wheelKey: String { Chord.symbol(prefs.chord.apertureKey) }
    private var recordKey: String { Chord.symbol(prefs.chord.recordKey) }

    private var hero: some View {
        VStack(spacing: 22) {
            HStack(spacing: 10) {
                ForEach(keys, id: \.word) { key in
                    Keycap(symbol: key.symbol, word: key.word, down: live.held.contains(key.flag), live: live.live,
                           size: CGSize(width: 96, height: 72))
                }
            }
            VStack(spacing: 6) {
                Text(AppInfo.name)
                    .font(.system(size: 22, weight: .semibold))
                    .tracking(-0.2)
                Text("Hold \(prefs.chord.symbols) and grab areas or windows.\nLet go, and they go where you've chosen below.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
            }
        }
        .padding(.top, 52)
        .padding(.bottom, 14)
    }

    // MARK: Sections

    private var shortcut: some View {
        Section {
            Picker("Shortcut", selection: $prefs.chord) {
                ForEach(Chord.allCases) { chord in
                    Text("\(chord.symbols)  \(chord.name)").tag(chord)
                }
            }
            LabeledContent("More ways to send") {
                Text("Tap \(wheelKey) while holding")
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Record a video") {
                Text("Add \(recordKey) while holding")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var letGo: some View {
        Section {
            HStack(spacing: 6) {
                ForEach(WheelAction.defaults) { action in
                    ChoiceTile(action: action, selected: prefs.defaultAction == action) {
                        prefs.defaultAction = action
                    }
                }
            }
            .padding(.vertical, 2)
        } header: {
            Text("When you let go")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(prefs.defaultAction.summary)
                Text("Tap \(wheelKey) during a hold to pick differently for one burst.")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var saving: some View {
        Section {
            LabeledContent("Save to") {
                HStack(spacing: 8) {
                    Text((prefs.saveFolder.path as NSString).abbreviatingWithTildeInPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                    Button("Choose…", action: chooseFolder)
                }
            }
        } header: {
            Text("Folder")
        } footer: {
            Text("Both and Save put copies here. Recordings go to Downloads.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var general: some View {
        Section("General") {
            Toggle("Capture sound", isOn: $prefs.playSound)
            Toggle("Open at login", isOn: $openAtLogin)
                .onChange(of: openAtLogin) { _, on in setOpenAtLogin(on) }
        }
    }

    private var recent: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(history.items) { item in
                        RecentCard(item: item) { copy(item.shots) }
                    }
                }
                .padding(.vertical, 2)
            }
        } header: {
            HStack {
                Text("Recent")
                Spacer()
                Button("Show in Finder", action: openFolder)
                    .buttonStyle(.link)
                    .font(.callout)
            }
        }
    }

    private var permissions: some View {
        Section {
            PermissionRow(title: "Accessibility", detail: "Sees the hold and pastes for you", granted: access.accessibility) {
                Permissions.promptAccessibility()
                Permissions.open(.accessibility)
            }
            PermissionRow(title: "Screen Recording", detail: "Captures what you grab", granted: access.screenRecording) {
                Permissions.requestScreenRecording()
                Permissions.open(.screenRecording)
            }
        } header: {
            Text("Permissions")
        } footer: {
            if !access.screenRecording {
                HStack {
                    Text("macOS applies Screen Recording after a relaunch.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Relaunch \(AppInfo.name)") { Permissions.relaunch() }
                        .controlSize(.small)
                }
            }
        }
    }

    // MARK: Actions

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use Folder"
        panel.directoryURL = prefs.saveFolder
        if panel.runModal() == .OK, let url = panel.url { prefs.saveFolder = url }
    }

    private func openFolder() {
        try? FileManager.default.createDirectory(at: prefs.saveFolder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(prefs.saveFolder)
    }

    private func setOpenAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            openAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

private struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    let allow: () -> Void

    var body: some View {
        LabeledContent {
            if granted {
                Label("Allowed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Button("Allow…", action: allow)
            }
        } label: {
            Text(title)
            Text(detail)
        }
    }
}

/// One of the aperture's choices as a tile: same icon, same word. The chosen
/// one inverts, like the white blade.
private struct ChoiceTile: View {
    let action: WheelAction
    let selected: Bool
    let pick: () -> Void

    var body: some View {
        Button(action: pick) {
            VStack(spacing: 5) {
                Image(systemName: action.symbol)
                    .font(.system(size: 15, weight: .medium))
                    .frame(height: 18)   // every word on one baseline, whatever the icon's height
                Text(action.blade)
                    .font(.system(size: 10.5, weight: .bold))
                    .tracking(0.5)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .foregroundStyle(selected ? Color(nsColor: .windowBackgroundColor) : Color.primary.opacity(0.75))
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? Color.primary : Color.primary.opacity(0.06))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(Pressable())
        .animation(.easeOut(duration: 0.15), value: selected)
        .accessibilityLabel(action.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// One past burst: a small fanned stack and when it happened. Click to copy it again.
struct RecentCard: View {
    let item: History.Item
    let copy: () -> Void
    @State private var hovering = false
    @State private var copied = false

    private static let tilts: [Double] = [0, -4, 3]
    private static let ago: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    var body: some View {
        Button {
            copy()
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { copied = false }
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    ForEach(Array(item.thumbs.enumerated().reversed()), id: \.offset) { i, thumb in
                        Image(nsImage: thumb)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 84, height: 54)
                            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(.primary.opacity(0.08), lineWidth: 0.5))
                            .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                            .rotationEffect(.degrees(Self.tilts[i % Self.tilts.count]))
                            .offset(x: CGFloat(i) * 4, y: CGFloat(i) * -2)
                    }
                    if copied {
                        Label("Copied", systemImage: "checkmark")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.regularMaterial, in: Capsule())
                            .transition(.scale(scale: 0.92).combined(with: .opacity))
                    }
                }
                .frame(width: 100, height: 66)
                .offset(y: hovering ? -1 : 0)
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text("\(item.shots.count) \(item.shots.count == 1 ? "shot" : "shots") · \(Self.ago.localizedString(for: item.date, relativeTo: context.date))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.primary.opacity(hovering ? 0.05 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(Pressable())
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
        .animation(.easeOut(duration: 0.18), value: copied)
        .help("Copy these shots again")
    }
}
