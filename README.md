# Burst

Hold **⌃⌥** (Control + Option), grab as many parts of the screen as you want, let go. Every shot drops into the app you were typing in: Claude, ChatGPT, Grok, a browser chat, Cursor, VS Code, or Claude Code in a terminal.

## Download

Get `Burst.zip` from this repo's Releases page, unzip it, and drag Burst to your Applications folder. It runs on both Apple silicon and Intel Macs, and needs macOS 15 or newer.

Burst is a free personal project and isn't notarized by Apple, so the first time you open it macOS says it can't verify the app. Open System Settings › Privacy & Security and click **Open Anyway** (the button appears once you've tried to open Burst). Then grant Accessibility and Screen Recording, as described under [Permissions](#permissions).

## Using it

| While holding ⌃⌥ | Does |
|---|---|
| Drag | Grabs that area |
| Click a window | Grabs just that window (no background, no shadow) |
| Click bare desktop | Grabs the whole display |
| Tap ⇧ | Opens the aperture at the pointer: point at Paste, Both (paste and save), Save, Copy, Files or Cancel, and letting go sends this burst that way |
| Add ⌘ (keep ⌃⌥ held) | Record mode: the bar turns red. Drag an area or click a window and it starts recording; recording then runs hands-free. Stop with the small Stop control, by holding ⌃⌥ again, or from the menu bar. The MP4 lands in Downloads and on the clipboard |
| ⌫ | Takes back the last shot |
| esc | Cancels, nothing is dropped |
| Let go | Drops every shot into the front app |

- The hold kicks in after about a quarter second. Quick ⌃⌥ shortcuts (window managers, ⌃⌥ + arrows) keep working: pressing any key before your first shot cancels and passes the key through.
- Holding never locks the screen: scroll, swipe between Spaces or right-click as usual, so you can grab, scroll down, and grab again in one hold. Only left-button drags and clicks are taken for capturing.
- The app you're typing in never loses focus. The overlay is a lens, it never becomes the active window.
- While you hold, the clipboard already holds every shot. After the drop it still does, so you can paste the same burst somewhere else (or use **Copy Last Burst Again** in the menu bar).
- In terminals Burst pastes with ⌃V, which is how Claude Code reads clipboard images.

## The setup window (menu bar icon › Open Burst, or ⌘,)

The keys at the top move with your real keys. Below: the shortcut, what letting go does by default, your recent bursts (click one to copy it again), saving, sound, login and permissions.

## Recording

Hold ⌃⌥, add ⌘ (the next finger), then drag the area to record (or click a window, or bare desktop for the whole display). Let go of ⌘ before dragging to go back to screenshots. Once it starts, recording keeps going after you let go, so you can demo with your mouse and keyboard. A thin red frame marks the area and a small black control under it shows the time and a Stop button; holding ⌃⌥ again or the menu bar's Stop Recording also stops it. Files go to Downloads as `Burst Recording 2026-10-30 at 10.32.05 PM.mp4` (H.264, 60 fps, with the pointer, no audio) and onto the clipboard, ready to paste. Burst's own controls are never in the video. Needs macOS 15 or newer.

## Settings

- **Hold to grab**: ⌃⌥ by default; ⌥⌘, ⌃⌘, ⌃⇧, ⌥⇧, ⇧⌘ also available. Fn is never used (dictation owns it).
- **When you let go**: one choice, in the aperture's own words. **Paste** (each shot into the app you're in), **Both** (paste and save a copy), **Save** (to your folder and the clipboard), **Copy** (clipboard only) or **Files** (one paste of image files). Pick Both or Save to save by default, Paste or Copy to not. The menu bar has the same choices. Tap ⇧ during a hold to pick differently for one burst.
- **Folder**: where Both and Save put copies (default `~/Pictures/Burst`), named like macOS screenshots: `Burst 2026-10-30 at 2.32.05 PM (2 of 3).png`.
- **Capture sound**, **Open at login**.

## Permissions

Burst needs two, both under System Settings › Privacy & Security:

1. **Accessibility**: to see the hold and to paste for you.
2. **Screen Recording**: to capture. macOS applies this one after a relaunch (Settings has a **Relaunch Burst** button).

The downloadable app, and any build made without a signing identity (see Building), is signed ad-hoc. macOS treats an ad-hoc build as a new app each time it changes, so you may need to grant these again after an update or a rebuild. A build signed with a stable identity keeps them.

Known limit: while a password field or Terminal's *Secure Keyboard Entry* is active, macOS hides keystrokes from every app, Burst included, so the hold won't start there.

## Building

```bash
./build.sh               # build, sign, install to /Applications, launch
./build.sh --no-install  # build into ./dist only
```

With no signing identity, `build.sh` signs the app ad-hoc, so macOS may ask for Accessibility and Screen Recording again after each rebuild. To keep them, set `BURST_SIGN_IDENTITY` to a codesigning identity (its name or hash, as listed by `security find-identity -v -p codesigning`), or put that identity in a `.sign-identity` file next to `build.sh` (it is git-ignored).

Other tools:

```bash
swift scripts/make-icon.swift                                  # regenerate Resources/AppIcon.icns
dist/Burst.app/Contents/MacOS/Burst --selftest             # capture + clipboard checks, no overlay
dist/Burst.app/Contents/MacOS/Burst --snapshot /tmp/snaps  # render overlay + settings off-screen for review
```

## How it works

| File | Job |
|---|---|
| `ChordMonitor.swift` | Session event tap: idle → armed → active → spent state machine for the held pair; eats esc/⌫ during a session |
| `Session.swift` | One hold: overlay per display, hover tracking, capture tasks, exit |
| `Overlay.swift` | Non-activating overlay panel, selection, size tag, HUD capsule |
| `Pile.swift` | The thumbnail pile and the lift-off flight |
| `Capture.swift` | ScreenCaptureKit region and window capture (Burst's own windows excluded), PNG encoding |
| `Dropper.swift` | Clipboard items with lazy data, paste-and-wait, saving |
| `AppController.swift` | The app delegate: menu bar item and menu, opens the setup window, starts and ends holds and recordings |
| `HomeView.swift` | The setup window (SwiftUI): shortcut keys, what letting go does, recent bursts, folder, sound, login, permissions |
| `Keycap.swift` | The keycap view in the setup window, and the press style for its buttons |
| `Wheel.swift` | The aperture: the six-way picker that opens when you tap ⇧ |
| `Recorder.swift` | Screen recording to MP4 with ScreenCaptureKit, plus the red frame and the Stop control |
| `Prefs.swift` | Saved settings: hold keys, what letting go does, folder, sound |
| `History.swift` | The recent-bursts list and the live key state shown in the setup window |
| `Permissions.swift` | Accessibility and Screen Recording checks, opening the right Settings pane, relaunch |
| `Design.swift` | Shared sizes, colour and motion values for the overlay |
| `BurstApp.swift` | Entry point; also handles the `--selftest`, `--snapshot` and `--status` flags |
| `SelfTest.swift`, `Snapshot.swift` | The `--selftest` and `--snapshot` tools |

## License

MIT. See [LICENSE](LICENSE).
