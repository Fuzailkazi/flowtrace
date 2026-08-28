import SwiftUI
import AppKit
import FlowTraceCore

/// Turns a palette's stored values into colours SwiftUI can draw.
///
/// The palette itself is plain data in Core so it can be checked by tests —
/// a theme whose ink matches its ground is unreadable, and the cheapest way to
/// ship one is to mistype a hex value.
extension Palette {
    /// Ground, ink and accent — enough to judge a theme without applying it.
    var previewGround: Color { Palette.adaptive(light: paperLight, dark: paperDark) }
    var previewInk: Color { Palette.adaptive(light: inkLight, dark: inkDark) }
    var previewAccent: Color { Palette.adaptive(light: accentLight, dark: accentDark) }

    /// Resolves per appearance, so light and dark are two deliberate palettes
    /// rather than one inverted.
    static func adaptive(light: String, dark: String) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }
}
