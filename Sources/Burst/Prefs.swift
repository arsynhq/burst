import AppKit
import CoreGraphics

enum Chord: String, CaseIterable, Identifiable {
    case controlOption, optionCommand, controlCommand, controlShift, optionShift, shiftCommand

    var id: String { rawValue }

    var flags: CGEventFlags {
        switch self {
        case .controlOption: [.maskControl, .maskAlternate]
        case .optionCommand: [.maskAlternate, .maskCommand]
        case .controlCommand: [.maskControl, .maskCommand]
        case .controlShift: [.maskControl, .maskShift]
        case .optionShift: [.maskAlternate, .maskShift]
        case .shiftCommand: [.maskShift, .maskCommand]
        }
    }

    var symbols: String {
        switch self {
        case .controlOption: "⌃⌥"
        case .optionCommand: "⌥⌘"
        case .controlCommand: "⌃⌘"
        case .controlShift: "⌃⇧"
        case .optionShift: "⌥⇧"
        case .shiftCommand: "⇧⌘"
        }
    }

    var name: String {
        switch self {
        case .controlOption: "Control + Option"
        case .optionCommand: "Option + Command"
        case .controlCommand: "Control + Command"
        case .controlShift: "Control + Shift"
        case .optionShift: "Option + Shift"
        case .shiftCommand: "Shift + Command"
        }
    }

    /// Tapped during a hold to open the aperture: Shift, or the first free
    /// modifier when the chord itself uses Shift.
    var apertureKey: CGEventFlags {
        guard flags.contains(.maskShift) else { return .maskShift }
        return [CGEventFlags.maskControl, .maskAlternate, .maskCommand].first { !flags.contains($0) } ?? .maskCommand
    }

    /// Added during a hold to record video instead of screenshots: the next
    /// finger along (Command for ⌃⌥).
    var recordKey: CGEventFlags {
        [CGEventFlags.maskCommand, .maskControl, .maskAlternate].first { !flags.contains($0) && $0 != apertureKey } ?? .maskCommand
    }

    static func symbol(_ key: CGEventFlags) -> String {
        if key == .maskCommand { return "⌘" }
        if key == .maskControl { return "⌃" }
        if key == .maskAlternate { return "⌥" }
        return "⇧"
    }

    /// The four modifiers a chord can be built from. Fn and Caps Lock are ignored
    /// on purpose: Fn belongs to dictation (Wispr Flow, gesture-fn).
    static let relevant: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand, .maskShift]
}

final class Prefs: ObservableObject {
    static let shared = Prefs()
    private let store = UserDefaults.standard

    static let defaultFolder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Pictures/Burst", isDirectory: true)

    @Published var chord: Chord { didSet { store.set(chord.rawValue, forKey: "chord") } }
    /// What letting go does when the aperture isn't opened: one of its own
    /// blades (never Cancel), so the setup screen and the aperture speak alike.
    @Published var defaultAction: WheelAction { didSet { store.set(defaultAction.rawValue, forKey: "defaultAction") } }
    @Published var saveFolder: URL { didSet { store.set(saveFolder.path, forKey: "saveFolder") } }
    @Published var playSound: Bool { didSet { store.set(playSound, forKey: "playSound") } }

    private init() {
        store.register(defaults: ["playSound": true])
        chord = Chord(rawValue: store.string(forKey: "chord") ?? "") ?? .controlOption
        if let raw = store.object(forKey: "defaultAction") as? Int, let action = WheelAction(rawValue: raw), action != .cancel {
            defaultAction = action
        } else {
            // Carry over the old "drop / style / save" switches.
            let paste = store.object(forKey: "autoDrop") as? Bool ?? true
            let save = store.bool(forKey: "saveToDisk")
            let files = store.string(forKey: "dropStyle") == "filesAtOnce"
            let carried: WheelAction = !paste ? (save ? .save : .copy) : files ? .files : (save ? .dropSave : .drop)
            defaultAction = carried
            store.set(carried.rawValue, forKey: "defaultAction")   // carried over once, then it's the setting
        }
        saveFolder = store.string(forKey: "saveFolder").map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? Prefs.defaultFolder
        playSound = store.bool(forKey: "playSound")
    }
}
