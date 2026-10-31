# Burst — design system

Recorded from the built interface, not from intention. Mode: **Operate**. The user is mid-conversation with an AI and the tool should be a lens they look through for a few seconds, then gone.

## Thesis

The hold is the session. Burst refuses the screenshot-app arrangement (mode toolbar, annotation tools, a floating preview asking for a decision after each shot). It plays macOS's own capture grammar straight (⌘⇧4 / ⌘⇧5) and adds one signature move: shots lift off the screen into a loosely fanned pile, bottom-right, where macOS already puts its screenshot thumbnail.

## Surfaces

| Surface | Container | Notes |
|---|---|---|
| Capture overlay | Borderless `NSPanel`, `.nonactivatingPanel`, level `.screenSaver`, one per display, all Spaces | `canBecomeKey = false` and `ignoresMouseEvents = true`: the hold is non-invasive. Scrolling, gestures and right-clicks reach the apps underneath; only left-button presses (and pointer moves, so no app swaps the crosshair) are taken, through the event tap. The front app never loses focus; this is load-bearing for the paste. |
| HUD capsule | Steps aside (15% opacity) when the pointer comes within 40pt or a selection reaches it. SwiftUI view in an `NSHostingView`; background is an `NSVisualEffectView` `.hudWindow` (behind-window) wrapped as a SwiftUI view and clipped to a capsule, so the capsule animates its width with its text | Centred, `menu bar height + 12pt` from the top; only on the display under the pointer |
| Pile | Core Animation layers inside the overlay | Bottom-right of the visible frame (clears the Dock), 32pt inset. Steps aside (15% opacity) when the pointer or a selection comes within 34pt. Stays up, click-through, during the drop |
| Menu bar | `NSStatusItem`, SF Symbol `photo.stack` (template), rebuilt in `menuNeedsUpdate` | Quick toggles for drop and save live here as well as in Settings |
| Settings | `NSWindow` + `NSHostingController`, SwiftUI `Form` `.grouped`, 480pt wide | Permissions section floats to the top while anything is missing |

## Setup window

A Mac settings window with one beautiful object in it. Opens only from the menu bar (or ⌘,), or on first run when a permission is missing.

| | |
|---|---|
| Window | 500 × 800pt, transparent titlebar, system window background |
| Hero | the chord's two keys drawn as Apple-keyboard keycaps (86 × 64pt, symbol top-right, word bottom-left); they sink 2pt with the real keys (0.06s down, 0.12s up) and glow softly white only while a hold is live. Name 20pt semibold, one centred line in secondary |
| Form | native `.grouped` form, sentence case: Shortcut, When you let go, Recent, Folder, General, Permissions (moves to the top while anything is missing) |
| When you let go | one row of the aperture's own choices as tiles (icon over word: PASTE, BOTH, SAVE, COPY, FILES); the chosen tile inverts (primary fill, background-coloured ink) like the white blade; one plain sentence under it says what it does. Saving is part of the choice (Both, Save), never a separate switch |
| Recent | fanned stacks of up to three thumbnails (tilts 0°, −4°, 3°), caption "3 shots · 2 min. ago"; click copies again, shows a "Copied" capsule |

## The aperture (tap ⇧ during a hold)

A camera iris that spins open centred on the pointer. Tangerine's DNA (object at the pointer, pick by direction, hardware feel, one bold highlight) with our own object. Direction picks a blade; the eye is a dead zone; arrow keys turn it; esc, return or a click closes it. Letting go sends the burst the chosen way. Unopened, it mirrors the setup screen's default.

| | |
|---|---|
| Blades | clockwise from the top: Paste, Both (paste and save), Save, Cancel, Copy, Files. Six blades tile the eye with a 10° clockwise twist (no overlaps, so nothing can collide), dark seams 1.5pt, each lit from the centre outward (#343639 → #161719) |
| Geometry | bezel radius 152 with 36 engraved ticks; iris clip 134; blades run to 140 so no edge shows at the rim; hexagonal eye 44 |
| Icons and words | every blade carries an SF Symbol (17pt medium) over its word (10.5pt bold, +0.6 tracking: PASTE, BOTH, SAVE, CANCEL, COPY, FILES), upright at radius 92; grey #B8B8B8, ink on the chosen blade |
| Eye | empty: the blades carry the words, so the eye is just the dark hexagonal opening |
| Chosen blade | polished white (#FFF → #D4D4D9), fades in over 0.12s, stays in place |
| Material | fully opaque machined black; one shadow on the bezel (black 60%, 18pt, 12pt down). No accent colour anywhere |
| Motion | opens critically damped (spring 0.34, damping 1): the eye dilates from closed while the blades turn 32° into place and the whole thing scales from 0.94; closes in 0.12s ease-out; trackpad detent on every change; Reduce Motion fades only |

## Recording (add ⌘ during a hold)

| | |
|---|---|
| Record mode | the HUD turns to a red dot plus "Drag the area to record, or click a window"; the selection outline turns red, 2pt. Letting go of ⌘ returns to screenshots |
| While recording | a 1.5pt red frame 4pt outside the area (click-through); a black capsule under the area (above it if there's no room, inside it for full screen): red dot, mono timer, Stop on a 14% white capsule. Both are non-activating panels and are excluded from the video |
| Saved | "Saved to Downloads · Show" capsule, bottom centre, fades after 3.5s; the file is on the clipboard |
| Colour | red `#FF453B` is the only colour in Burst, and only ever means recording |
| Sound | the system's own begin/end record sounds, with Capture sound on |

## Color

**Restrained.** Neutrals plus the user's own accent colour, nothing else.

- Scrim: black at 10% over every display, just enough to say "on"; the live selection is punched clear (even-odd path).
- Selection hairline: 1pt white with a 1pt black shadow at 50% so it reads on white and black content.
- Hovered window: 2pt white line at 95% with a 2pt black shadow at 35%, 18pt radius on macOS 26 (10pt before). No fill, no colour: the content under the lens stays true. It only appears once the pointer has moved 10pt since the hold began (or since the last grab), so the first frame of every hold is a plain dim. Bare desktop gets no outline; a click there still takes the whole display.
- Count badge: white fill, black numerals. Burst has no accent colour; the one exception is recording red.
- Size tag: black at 72%, white text.
- HUD text: white; secondary at 62%; keycaps white at 14% fill.
- Settings: semantic SwiftUI roles only; granted permissions use system green.

The overlay is always dark (the system capture UI is), regardless of appearance. Settings follows the system.

## Type

System font only.

| Role | Spec |
|---|---|
| HUD status | 13pt medium |
| HUD count | 13pt medium, `monospacedDigit`, numeric content transition |
| HUD keycap | 11pt semibold in an 18pt-high, 4pt-radius cap |
| Size tag | 11pt medium, `monospacedDigitSystemFont` |
| Badge | 12pt semibold |
| Settings footnotes | `.callout`, secondary, leading-aligned |

## Space and shape

| | |
|---|---|
| HUD | 36pt tall capsule, 16pt side padding, 14pt between groups |
| Thumbnail box | fits 184 × 128pt, never upscaled, 36pt minimum side |
| Card radius | 8pt continuous, 2pt white border at 95% (a printed-photo edge, so dark shots on dark screens still read as cards) |
| Card shadow | black 50%, 12pt blur, 5pt down, declared once on the outer layer |
| Pile fan | tilts −2.5°, 2°, −1°, 3°, −3.5°, 1.5°; nudges up to 8pt; six cards deep, older ones hide |
| Size tag | 20pt tall, 5pt radius, 6pt under the selection's bottom-right (tucks inside when there's no room) |

## Motion

Product motion: fast, interruptible, never ease-in.

| | |
|---|---|
| Curve | `cubic-bezier(0.23, 1, 0.32, 1)` for every timed animation, entering and leaving |
| Overlay in / out | 0.12s / 0.12s window alpha (exists only so a full-screen dim never pops) |
| Shot flight | spring, perceptual 0.42s, bounce 0.12, on position + one transform (scale from the selected rect's size to 1, plus tilt); inner corner radius springs 0 → 8; shadow fades in over 0.3s |
| Pixels landing | 0.12s fade from the white "flash" placeholder to the captured image |
| Window outline | fades in over 0.12s where it appears; glides to the next window over 0.12s (plain swap under Reduce Motion); vanishes at once when a drag starts |
| Undo (⌫) | 0.1s fade from the card's on-screen state, no flourish (keyboard action) |
| Badge | lands with its card (0.28s after lift-off), then springs 0.3s, bounce 0.2, from 0.85 scale; pinned to the pile, never the top card's nudge |
| Release | the lens (scrim, ring, HUD) fades in 0.12s; the pile stays. Each card sinks 14pt and fades over 0.16s the moment its paste lands, so the badge counts down as shots go in. Whatever is left sinks 14pt and scales to 0.96 around the pile's anchor |
| Cancel | everything fades 0.12s, the pile shrinks to 0.92 |
| Reduced motion | flights become 0.18s fades; exits fade only |

The flight scales a fixed-size card rather than animating bounds, so the clipped image layer and its shadow layer stay in lockstep with no per-frame layout.

## Sound

The system's own `Screen Capture.aif`, played on mouse-up, the same frame the card lifts. One switch in Settings.

## Rules

- Never take focus. Anything that would make the overlay key or activate the app breaks the drop.
- One HUD, one pile. No second panel, no toasts. The pile is also the drop's progress indicator.
- Saving never holds up the paste; only "All at once, as files" writes before pasting, because it pastes the files.
- A white line is what you'll get: the drag selection and the window outline share it. Colour never lands on the user's content.
- Copy names the action in plain words: "Drag an area or click a window", "Let go of ⌃⌥ to drop".
