import SwiftUI
import AppKit
import FlowTraceCore

/// The colours everything is drawn in.
///
/// A facade over whichever `Palette` is selected, so views name a role — ground,
/// ink, accent — and never a specific colour. The default palette is the
/// approved Stitch design ("Ambient Recall"): quiet paper, near-black ink,
/// indigo accent, white cards.
///
/// Semantic colours are deliberately *not* part of the palette: green means live
/// and amber means wants-attention in every theme, because a meaning that changes
/// with the theme is not a meaning.
enum Journal {
    private static var palette: Palette { Palette.current }

    /// The page ground (Stitch: surface).
    static var paper: Color { Palette.adaptive(light: palette.paperLight, dark: palette.paperDark) }
    /// The sidebar and quiet sections (Stitch: surface-container-low).
    static var paperDeep: Color { Palette.adaptive(light: palette.deepLight, dark: palette.deepDark) }
    /// Chips, pills, filled containers (Stitch: surface-container).
    static var wash: Color { Palette.adaptive(light: palette.washLight, dark: palette.washDark) }
    /// Cards (Stitch: surface-container-lowest).
    static var card: Color { Palette.adaptive(light: palette.cardLight, dark: palette.cardDark) }

    static var ink: Color { Palette.adaptive(light: palette.inkLight, dark: palette.inkDark) }
    static var inkMid: Color { Palette.adaptive(light: palette.inkMidLight, dark: palette.inkMidDark) }
    static var inkSoft: Color { Palette.adaptive(light: palette.inkSoftLight, dark: palette.inkSoftDark) }

    /// Hairlines and the strongest filled surface (Stitch: surface-container-highest).
    static var rule: Color { Palette.adaptive(light: palette.ruleLight, dark: palette.ruleDark) }
    /// Outlines that need to be seen (Stitch: outline-variant).
    static var ruleFirm: Color { Palette.adaptive(light: palette.ruleFirmLight, dark: palette.ruleFirmDark) }

    /// The one colour a theme gets to choose the character of (Stitch: primary).
    static var pen: Color { Palette.adaptive(light: palette.accentLight, dark: palette.accentDark) }
    static var penSoft: Color { Palette.adaptive(light: palette.accentSoftLight, dark: palette.accentSoftDark) }
    /// Text on a `pen` fill.
    static let onPen = Color.white

    /// Wants attention. The same in every theme, and used for one thing only.
    static let amber = Palette.adaptive(light: "A8752E", dark: "E0AC61")
    static let amberSoft = Palette.adaptive(light: "F6EBD8", dark: "33280F")
    /// Alive right now.
    static let live = Palette.adaptive(light: "2C7A4B", dark: "5FBF85")
    /// Something went wrong (Stitch: error).
    static let danger = Palette.adaptive(light: "BA1A1A", dark: "FFB4AB")

    /// 4pt grid, as the design uses it.
    enum Space {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
        static let section: CGFloat = 48
    }

    /// Radii, from the design's `rounded-md / lg / xl / 2xl`.
    enum Radius {
        static let chip: CGFloat = 6
        static let field: CGFloat = 8
        static let card: CGFloat = 12
        static let panel: CGFloat = 16
    }

    /// The card shadow the design uses: barely there.
    static func cardShadow<V: View>(_ view: V) -> some View {
        view.shadow(color: .black.opacity(0.03), radius: 6, y: 2)
    }

    /// The sidebar width in the design (`w-64`).
    static let sidebarWidth: CGFloat = 232
}

extension Font {
    /// The user's own words. Italic so your voice reads differently from the
    /// system's; sans, as the design sets personal notes.
    static func yourWords(_ size: CGFloat) -> Font {
        .system(size: size, weight: .regular).italic()
    }

    /// Headlines: SF Pro semibold, tight tracking is applied at the call site.
    static func journalTitle(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight)
    }

    /// Anything the machine observed.
    static func observed(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    /// Paths, ports, timestamps, ids (Stitch: JetBrains Mono → SF Mono here).
    static func mono(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    /// Small uppercase tracked labels (Stitch: mono-caption).
    static func caption(_ size: CGFloat = 10.5, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

extension NSColor {
    convenience init(hex: String) {
        var value: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&value)
        self.init(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }
}
