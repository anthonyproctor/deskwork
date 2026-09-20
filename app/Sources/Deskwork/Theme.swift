// How a desk's terminal looks.
//
// Deskwork exists because a terminal was not good enough, so the terminal
// looking right is not a cosmetic concern here — it is most of the product.
//
// The defaults are Gruvbox Dark Hard, JetBrains Mono, ligatures off, block
// cursor: a readable dark theme that has been around long enough to be
// uncontroversial. Everything is overridable in desks.toml, because somebody
// else's terminal taste is the last thing to hardcode:
//
//     [theme]
//     font      = "SF Mono"
//     size      = 13
//     palette   = "gruvbox-dark-hard"   # or light, nord, solarized-dark
//
// A named palette that is not recognised falls back to the default rather than
// rendering something unreadable, and a font that is not installed falls back
// to the system monospace — a missing font must never produce an empty pane.

import AppKit
import SwiftTerm
import DeskworkCore

enum Theme {

    struct Palette {
        let name: String
        let background: NSColor
        let foreground: NSColor
        let cursor: NSColor
        let selection: NSColor
        /// The sixteen ANSI colours, in the usual order.
        let ansi: [NSColor]
    }

    // MARK: - palettes

    static func hex(_ s: String) -> NSColor {
        var v: UInt64 = 0
        Scanner(string: s.replacingOccurrences(of: "#", with: "")).scanHexInt64(&v)
        return NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255,
                       green: CGFloat((v >> 8) & 0xff) / 255,
                       blue: CGFloat(v & 0xff) / 255, alpha: 1)
    }

    static let gruvboxDarkHard = Palette(
        name: "gruvbox-dark-hard",
        background: hex("1d2021"), foreground: hex("ebdbb2"),
        cursor: hex("ebdbb2"), selection: hex("665c54"),
        ansi: ["1d2021", "cc241d", "98971a", "d79921", "458588", "b16286", "689d6a", "a89984",
               "928374", "fb4934", "b8bb26", "fabd2f", "83a598", "d3869b", "8ec07c", "ebdbb2"]
            .map(hex))

    static let gruvboxLight = Palette(
        name: "gruvbox-light",
        background: hex("f9f5d7"), foreground: hex("3c3836"),
        cursor: hex("3c3836"), selection: hex("d5c4a1"),
        ansi: ["fbf1c7", "cc241d", "98971a", "d79921", "458588", "b16286", "689d6a", "7c6f64",
               "928374", "9d0006", "79740e", "b57614", "076678", "8f3f71", "427b58", "3c3836"]
            .map(hex))

    static let nord = Palette(
        name: "nord",
        background: hex("2e3440"), foreground: hex("d8dee9"),
        cursor: hex("d8dee9"), selection: hex("434c5e"),
        ansi: ["3b4252", "bf616a", "a3be8c", "ebcb8b", "81a1c1", "b48ead", "88c0d0", "e5e9f0",
               "4c566a", "bf616a", "a3be8c", "ebcb8b", "81a1c1", "b48ead", "8fbcbb", "eceff4"]
            .map(hex))

    static let solarizedDark = Palette(
        name: "solarized-dark",
        background: hex("002b36"), foreground: hex("839496"),
        cursor: hex("93a1a1"), selection: hex("073642"),
        ansi: ["073642", "dc322f", "859900", "b58900", "268bd2", "d33682", "2aa198", "eee8d5",
               "002b36", "cb4b16", "586e75", "657b83", "839496", "6c71c4", "93a1a1", "fdf6e3"]
            .map(hex))

    static let all = [gruvboxDarkHard, gruvboxLight, nord, solarizedDark]

    // MARK: - what is in force

    private static var cached: (Palette, NSFont)?

    static func current() -> (palette: Palette, font: NSFont) {
        if let c = cached { return c }
        let cfg = DeskConfig.themeSettings()

        let pal = all.first { $0.name == (cfg.palette ?? "").lowercased() } ?? gruvboxDarkHard
        let size = CGFloat(cfg.size ?? 14)

        // A font that is not installed must fall back, never produce nothing.
        // JetBrains Mono is the default and is not on a stock Mac, so this path
        // is the normal one rather than the exception.
        let wanted = cfg.font ?? "JetBrainsMono Nerd Font Mono"
        let font = NSFont(name: wanted, size: size)
            ?? NSFont(name: "JetBrains Mono", size: size)
            ?? NSFont(name: "SF Mono", size: size)
            ?? NSFont(name: "Menlo", size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)

        cached = (pal, font)
        return (pal, font)
    }

    /// Re-read after settings change.
    static func invalidate() { cached = nil }

    // MARK: - applying it

    static func apply(to term: TerminalView) {
        let (pal, font) = current()
        term.font = font
        term.nativeBackgroundColor = pal.background
        term.nativeForegroundColor = pal.foreground
        term.caretColor = pal.cursor
        term.caretTextColor = pal.background
        term.selectedTextBackgroundColor = pal.selection

        // SwiftTerm keeps its own colour type, on 0-65535 components rather
        // than 0-1, so the ANSI table has to be converted rather than assigned.
        term.installColors(pal.ansi.map { c in
            let rgb = c.usingColorSpace(.sRGB) ?? c
            return SwiftTerm.Color(red: UInt16(rgb.redComponent * 65535),
                                   green: UInt16(rgb.greenComponent * 65535),
                                   blue: UInt16(rgb.blueComponent * 65535))
        })
    }
}
