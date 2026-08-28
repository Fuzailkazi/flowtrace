import Foundation

/// A complete set of surface and text colours, in both appearances.
///
/// Semantic colours — green for live, amber for wants-attention — are shared
/// across every palette rather than defined per theme. They mean something, and a
/// meaning that changes with the theme is not a meaning.
public struct Palette: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var blurb: String

    public var paperLight: String,  paperDark: String
    public var deepLight: String,   deepDark: String
    public var cardLight: String,   cardDark: String
    public var inkLight: String,    inkDark: String
    public var inkMidLight: String, inkMidDark: String
    public var inkSoftLight: String, inkSoftDark: String
    public var ruleLight: String,   ruleDark: String
    public var ruleFirmLight: String, ruleFirmDark: String
    public var accentLight: String, accentDark: String
    public var accentSoftLight: String, accentSoftDark: String

    public static let all: [Palette] = [.paper, .slate, .nocturne, .linen]

    /// Warm notebook paper with a green cast, brown-black ink, fountain-pen blue.
    public static let paper = Palette(
        id: "paper", name: "Paper",
        blurb: "Warm and written-in. Ink on aged notebook stock.",
        paperLight: "F7F5EE", paperDark: "1E1A14",
        deepLight: "F1EEE4", deepDark: "16130E",
        cardLight: "FDFCF8", cardDark: "272219",
        inkLight: "2A2520", inkDark: "F2EDE0",
        inkMidLight: "6B6355", inkMidDark: "B3A994",
        inkSoftLight: "918876", inkSoftDark: "8A806C",
        ruleLight: "E3DDCF", ruleDark: "342E23",
        ruleFirmLight: "CFC7B4", ruleFirmDark: "4E4634",
        accentLight: "33587D", accentDark: "8FB6DA",
        accentSoftLight: "E4EBF2", accentSoftDark: "1B2530"
    )

    /// Cool blue-grey with crisp contrast. Reads as an instrument, not a diary.
    public static let slate = Palette(
        id: "slate", name: "Slate",
        blurb: "Cool and precise. Highest legibility of the four.",
        paperLight: "F4F6F8", paperDark: "0F1419",
        deepLight: "EAEEF2", deepDark: "0A0E12",
        cardLight: "FFFFFF", cardDark: "161C23",
        inkLight: "111820", inkDark: "E9EEF3",
        inkMidLight: "48586A", inkMidDark: "9CACBC",
        inkSoftLight: "72808F", inkSoftDark: "6D7C8B",
        ruleLight: "DCE3EA", ruleDark: "212A34",
        ruleFirmLight: "BFCAD6", ruleFirmDark: "35424F",
        accentLight: "1F6FEB", accentDark: "6CA8F5",
        accentSoftLight: "E3EDFD", accentSoftDark: "13212F"
    )

    /// Deep indigo-black, low glare, for working after dark.
    public static let nocturne = Palette(
        id: "nocturne", name: "Nocturne",
        blurb: "Deep and quiet. Easiest on the eyes late at night.",
        paperLight: "F3F3F7", paperDark: "121218",
        deepLight: "EBEBF1", deepDark: "0C0C11",
        cardLight: "FBFBFD", cardDark: "1A1A22",
        inkLight: "16161D", inkDark: "EDEDF3",
        inkMidLight: "56566A", inkMidDark: "A3A3B8",
        inkSoftLight: "7E7E93", inkSoftDark: "74748A",
        ruleLight: "E1E1EA", ruleDark: "26262F",
        ruleFirmLight: "C6C6D4", ruleFirmDark: "3B3B48",
        accentLight: "5B4BC4", accentDark: "A79AF0",
        accentSoftLight: "EAE7FA", accentSoftDark: "1F1B33"
    )

    /// Light-first and soft. For people who never turn the lights off.
    public static let linen = Palette(
        id: "linen", name: "Linen",
        blurb: "Bright and soft. Built for working in daylight.",
        paperLight: "FBFAF8", paperDark: "1A1917",
        deepLight: "F3F1ED", deepDark: "121110",
        cardLight: "FFFFFF", cardDark: "232220",
        inkLight: "24211D", inkDark: "F0EEEA",
        inkMidLight: "5F5A53", inkMidDark: "ADA79E",
        inkSoftLight: "8B857B", inkSoftDark: "827C72",
        ruleLight: "E8E4DD", ruleDark: "2E2C29",
        ruleFirmLight: "CFC9BF", ruleFirmDark: "45423D",
        accentLight: "1D6B5E", accentDark: "6FC0AE",
        accentSoftLight: "E0F0EC", accentSoftDark: "13251F"
    )

    // MARK: - Selection

    private static let defaultsKey = "flowtrace.palette"

    public static var current: Palette {
        let id = UserDefaults.standard.string(forKey: defaultsKey) ?? paper.id
        return all.first { $0.id == id } ?? paper
    }

    public func select() {
        UserDefaults.standard.set(id, forKey: Self.defaultsKey)
    }
}
