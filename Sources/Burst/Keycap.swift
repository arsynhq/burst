import AppKit
import SwiftUI

/*
 DIRECTION CONTRACT — Burst setup window

 THESIS: A Mac settings window that happens to have one beautiful object in
 it. Native grouped form, sentence case, system controls; the hero is the
 shortcut itself, drawn as real keys that move with your real keys. Refuses
 the hardware costume of the first draft (engraved caps, LEDs, wells).

 OWN-WORLD: System window background and grouped sections; system font;
 Apple-keyboard keycaps (light aluminium-white, or space grey in dark mode);
 the keys glow softly white only while a hold is live.

 FIRST VIEWPORT: Keys centred under the traffic lights, name and one line
 beneath, then the form.

 FORM: Native canon, pinned by Mike ("apple design").

 FINISH: unreviewed and undocumented is unfinished; this build ends with the
 finish review, the verdict, and DESIGN.md
*/

enum Brand {
    /// The live keys glow white: Burst has no accent colour.
    static let live = Color.white
}

/// A modifier key as it looks on an Apple keyboard: symbol top-right, word
/// bottom-left, a hair of depth below the top face. Goes down with the real key.
struct Keycap: View {
    let symbol: String
    let word: String
    let down: Bool
    var live = false
    var size = CGSize(width: 86, height: 64)
    @Environment(\.colorScheme) private var scheme

    private var dark: Bool { scheme == .dark }
    private var scale: CGFloat { size.height / 64 }

    var body: some View {
        let r = 9 * scale
        let depth = (down ? 1 : 3) * scale
        ZStack(alignment: .top) {
            // The key's side, showing only as a thin lip under the top face.
            RoundedRectangle(cornerRadius: r, style: .continuous)
                .fill(dark ? Color(white: 0.13) : Color(white: 0.80))
                .frame(height: size.height - (down ? 2 * scale : 0))
                .offset(y: down ? 2 * scale : 0)
                .shadow(color: .black.opacity(dark ? 0.5 : 0.16), radius: down ? 0.5 : 1, y: down ? 0.5 : 1)
                .shadow(color: .black.opacity(down ? 0 : (dark ? 0.35 : 0.10)), radius: 8, y: 4)
                .shadow(color: live && down ? Brand.live.opacity(0.35) : .clear, radius: 12)
            RoundedRectangle(cornerRadius: r, style: .continuous)
                .fill(LinearGradient(colors: dark ? [Color(white: 0.29), Color(white: 0.24)]
                                                  : [Color(white: 1.0), Color(white: 0.955)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(
                    RoundedRectangle(cornerRadius: r, style: .continuous)
                        .strokeBorder(dark ? Color.white.opacity(0.07) : Color.black.opacity(0.05), lineWidth: 0.5)
                )
                .overlay(alignment: .topTrailing) {
                    Text(symbol)
                        .font(.system(size: 13 * scale, weight: .light))
                        .padding(.top, 7 * scale)
                        .padding(.trailing, 9 * scale)
                }
                .overlay(alignment: .bottomLeading) {
                    Text(word)
                        .font(.system(size: 10 * scale))
                        .padding(.bottom, 7 * scale)
                        .padding(.leading, 9 * scale)
                }
                .foregroundStyle(dark ? Color(white: 0.92) : Color(white: 0.16))
                .frame(height: size.height - depth)
                .offset(y: down ? 2 * scale : 0)
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        // Real key travel: quick down, a touch slower up.
        .animation(down ? .easeOut(duration: 0.06) : .easeOut(duration: 0.12), value: down)
    }
}

/// Every pressable custom thing answers the press: 0.97, fast in, a little slower out.
struct Pressable: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: configuration.isPressed ? 0.08 : 0.16), value: configuration.isPressed)
    }
}
