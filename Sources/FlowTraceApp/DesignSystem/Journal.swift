import SwiftUI
import AppKit
import FlowTraceCore

/// The journal palette.
///
/// Warm on purpose, but not the cream-and-terracotta that every "warm" palette
/// defaults to: the ground is aged notebook paper with a green cast, the ink is
/// the brown-black that real ink dries to, and the accent is fountain-pen blue.
///
/// Amber has exactly one meaning — unexplained — and appears nowhere else, so a
/// day can be scanned for what still needs a reason.
/// The colours everything is drawn in.
///
/// A facade over whichever `Palette` is selected, so views name a role — ground,
/// ink, accent — and never a specific colour. Switching theme is then one stored
/// string rather than an edit everywhere.
///
/// Semantic colours are deliberately *not* part of the palette: green means live
/// and amber means wants-attention in every theme, because a meaning that changes
/// with the theme is not a meaning.
enum Journal {
    private static var palette: Palette { Palette.current }

    static var paper: Color { Palette.adaptive(light: palette.paperLight, dark: palette.paperDark) }
    static var paperDeep: Color { Palette.adaptive(light: palette.deepLight, dark: palette.deepDark) }
    static var card: Color { Palette.adaptive(light: palette.cardLight, dark: palette.cardDark) }

    static var ink: Color { Palette.adaptive(light: palette.inkLight, dark: palette.inkDark) }
    static var inkMid: Color { Palette.adaptive(light: palette.inkMidLight, dark: palette.inkMidDark) }
    static var inkSoft: Color { Palette.adaptive(light: palette.inkSoftLight, dark: palette.inkSoftDark) }

    static var rule: Color { Palette.adaptive(light: palette.ruleLight, dark: palette.ruleDark) }
    static var ruleFirm: Color { Palette.adaptive(light: palette.ruleFirmLight, dark: palette.ruleFirmDark) }

    /// The one colour a theme gets to choose the character of.
    static var pen: Color { Palette.adaptive(light: palette.accentLight, dark: palette.accentDark) }
    static var penSoft: Color { Palette.adaptive(light: palette.accentSoftLight, dark: palette.accentSoftDark) }

    /// Wants attention. The same in every theme, and used for one thing only.
    static let amber = Palette.adaptive(light: "A8752E", dark: "E0AC61")
    static let amberSoft = Palette.adaptive(light: "F6EBD8", dark: "33280F")
    /// Alive right now.
    static let live = Palette.adaptive(light: "2C7A4B", dark: "5FBF85")

    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 13
        static let l: CGFloat = 20
        static let xl: CGFloat = 30
    }
}

extension Font {
    /// The user's own words. macOS ships New York as its serif, so this needs no
    /// bundled font — and italic serif reads as a hand, which is the point: your
    /// voice has to look different from the system's.
    static func yourWords(_ size: CGFloat) -> Font {
        .system(size: size, weight: .regular, design: .serif).italic()
    }

    /// Headings, in the same serif but upright.
    static func journalTitle(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }

    /// Anything the machine observed.
    static func observed(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
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
