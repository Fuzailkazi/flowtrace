import SwiftUI
import AppKit

/// The journal palette.
///
/// Warm on purpose, but not the cream-and-terracotta that every "warm" palette
/// defaults to: the ground is aged notebook paper with a green cast, the ink is
/// the brown-black that real ink dries to, and the accent is fountain-pen blue.
///
/// Amber has exactly one meaning — unexplained — and appears nowhere else, so a
/// day can be scanned for what still needs a reason.
enum Journal {
    /// Builds a colour that resolves per appearance, so light and dark are two
    /// deliberate palettes rather than one inverted.
    private static func adaptive(light: String, dark: String) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }

    // Dark is warmer and browner than a system dark grey — closer to lamplight on
    // paper than to a terminal. Measured against the light values so the two
    // themes read as the same product rather than one inverted.
    static let paper      = adaptive(light: "F7F5EE", dark: "1E1A14")
    static let paperDeep  = adaptive(light: "F1EEE4", dark: "16130E")
    static let card       = adaptive(light: "FDFCF8", dark: "272219")

    static let ink        = adaptive(light: "2A2520", dark: "F2EDE0")
    static let inkMid     = adaptive(light: "6B6355", dark: "B3A994")
    static let inkSoft    = adaptive(light: "918876", dark: "8A806C")

    static let rule       = adaptive(light: "E3DDCF", dark: "342E23")
    static let ruleFirm   = adaptive(light: "CFC7B4", dark: "4E4634")

    static let pen        = adaptive(light: "33587D", dark: "8FB6DA")
    static let penSoft    = adaptive(light: "E4EBF2", dark: "1B2530")

    /// Unexplained. Nothing else is ever this colour.
    static let amber      = adaptive(light: "A8752E", dark: "E0AC61")
    static let amberSoft  = adaptive(light: "F6EBD8", dark: "33280F")

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
