import AppKit
import SwiftUI

/// Pins `AGENTS.md`: a token's dark branch is the literal the forced-dark build shipped.
@main
@MainActor
struct AppearanceTests {
    static var failures = 0
    static var passes = 0

    static func check(_ label: String, _ ok: Bool, _ detail: String = "") {
        if ok {
            passes += 1
        } else {
            failures += 1
            print("FAIL  \(label)\(detail.isEmpty ? "" : ": \(detail)")")
        }
    }

    /// Quantized to the 8 bits that reach the framebuffer: `CGFloat`s carry Float error.
    static func components(_ color: Color, _ name: NSAppearance.Name) -> [Int] {
        var out: [Int] = []
        NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
            let ns = NSColor(color).usingColorSpace(.sRGB)!
            out = [ns.redComponent, ns.greenComponent, ns.blueComponent, ns.alphaComponent]
                .map { Int(($0 * 255).rounded()) }
        }
        return out
    }

    static func dark(_ label: String, _ token: Color, is expected: Color) {
        let actual = components(token, .darkAqua)
        let wanted = components(expected, .darkAqua)
        check("dark \(label)", actual == wanted, "\(actual) != \(wanted)")
    }

    /// A token that resolves identically in both never adapted at all.
    static func adapts(_ label: String, _ token: Color) {
        check(
            "\(label) adapts", components(token, .darkAqua) != components(token, .aqua),
            "light resolves identically to dark")
    }

    static func main() {
        let c = Theme.Colors.self

        print("# dark branches are the shipped literals")
        dark("panelScrim", c.panelScrim, is: Color.black.opacity(0.4))
        dark("dialogDimming", c.dialogDimming, is: Color.black.opacity(0.34))
        dark("tooltipShadow", c.tooltipShadow, is: Color.black.opacity(0.18))
        dark("selection", c.selection, is: Color.white.opacity(0.10))
        dark("rowHover", c.rowHover, is: Color.white.opacity(0.05))
        dark("menuHover", c.menuHover, is: Color.white.opacity(0.10))
        dark("separator", c.separator, is: Color.white.opacity(0.10))
        dark("controlSurface", c.controlSurface, is: Color.white.opacity(0.10))
        dark("border", c.border, is: Color.white.opacity(0.20))
        dark("textSecondary", c.textSecondary, is: Color.white.opacity(0.60))
        dark("textTertiary", c.textTertiary, is: Color.white.opacity(0.40))
        dark("noteText", c.noteText, is: Color.white.opacity(0.90))
        dark("cardFill", c.cardFill, is: Color.white.opacity(0.05))
        dark("cardStroke", c.cardStroke, is: Color.white.opacity(0.10))
        dark("dropGuide", c.dropGuide, is: Color.white.opacity(0.35))
        dark("brand", c.brand, is: Color(red: 0.525, green: 0.231, blue: 1.0))

        print("# tokens that absorbed a literal duplicated across views")
        dark("iconPlaceholder", c.iconPlaceholder, is: Color.white.opacity(0.06))
        dark("sheen", c.sheen, is: Color.white.opacity(0.04))
        dark("textPrimary", c.textPrimary, is: Color.white)
        // VolumeHUDView draws white 0.85; textPrimary is alpha 1, so opacity must reproduce it.
        dark("textPrimary at 0.85", c.textPrimary.opacity(0.85), is: Color.white.opacity(0.85))

        print("# every surface token resolves per appearance")
        for (label, token) in [
            ("panelScrim", c.panelScrim), ("selection", c.selection), ("rowHover", c.rowHover),
            ("menuHover", c.menuHover), ("separator", c.separator),
            ("controlSurface", c.controlSurface), ("border", c.border),
            ("textPrimary", c.textPrimary), ("textSecondary", c.textSecondary),
            ("textTertiary", c.textTertiary), ("noteText", c.noteText), ("cardFill", c.cardFill),
            ("cardStroke", c.cardStroke), ("dropGuide", c.dropGuide),
            ("iconPlaceholder", c.iconPlaceholder), ("sheen", c.sheen)
        ] {
            adapts(label, token)
        }

        print("# the scrim inverts rather than ramping: it lightens the light surface")
        check("light scrim is white", components(c.panelScrim, .aqua)[0] == 255)
        check("dark scrim is black", components(c.panelScrim, .darkAqua)[0] == 0)

        print("# the palette's scrim and tint keep the panel's ink, and its scrim is the thinner one")
        for (label, name, ink) in [("dark", NSAppearance.Name.darkAqua, 0), ("light", .aqua, 255)] {
            let tint = components(c.paletteGlassTint, name)
            let scrim = components(c.paletteScrim, name)
            check("\(label) palette ink", tint[0] == ink && scrim[0] == ink)
            check("\(label) palette scrim is thinner", scrim[3] < components(c.panelScrim, name)[3])
        }
        print("# a read panel's veil is heavier than the palette's, a HUD's is the thinnest")
        for (label, name, ink) in [("dark", NSAppearance.Name.darkAqua, 0), ("light", .aqua, 255)] {
            let palette = components(c.paletteScrim, name)[3]
            let reading = components(c.readingScrim, name)
            let hud = components(c.hudScrim, name)
            let tints = [components(c.readingGlassTint, name)[0], components(c.hudGlassTint, name)[0]]
            check("\(label) role ink", reading[0] == ink && hud[0] == ink && tints == [ink, ink])
            check("\(label) reading scrim is heavier than the palette's", reading[3] > palette)
            check("\(label) reading scrim is thinner", reading[3] < components(c.panelScrim, name)[3])
            check("\(label) hud scrim is the thinnest", hud[3] < palette)
            check(
                "\(label) hud tint carries the weight",
                components(c.hudGlassTint, name)[3] > components(c.paletteGlassTint, name)[3])
        }
        check("the opaque surface is opaque", components(c.opaqueSurface, .darkAqua)[3] == 255)
        adapts("opaqueSurface", c.opaqueSurface)

        print("# .system hands the choice back to AppKit")
        check("system is nil", AppAppearance.system.nsAppearance == nil)
        check("light is aqua", AppAppearance.light.nsAppearance?.isDark == false)
        check("dark is darkAqua", AppAppearance.dark.nsAppearance?.isDark == true)
        check("an unknown stored value is rejected", AppAppearance(rawValue: "sepia") == nil)

        print("\n\(passes) passed, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
