import Foundation

/// The fork's Raycast palette: its values, the agent colour rule and the glyph families.
@main
@MainActor
struct ColorfulIconsTests {
    static var failures = 0
    static var passes = 0

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if condition() {
            passes += 1
        } else {
            failures += 1
            print("FAIL: \(message)")
        }
    }

    static func main() {
        theTableIsRaycasts()
        tilesHoldAWhiteGlyph()
        glyphsReadOnTheirSurface()
        theAccentReads()
        anAgentKeepsItsColour()
        everyFamilyHasAHue()
        menuGlyphsFollowTheirMeaning()

        print("\(passes) passed, \(failures) failed")
        if failures > 0 { exit(1) }
    }

    /// Pinned, so a stray edit can't drift an extension's `Color.<hue>` away from Raycast's.
    static func theTableIsRaycasts() {
        let dark: [RaycastHue: UInt32] = [
            .red: 0xFF6363, .orange: 0xFF9217, .yellow: 0xFFC531, .green: 0x59D499, .blue: 0x56C2FF,
            .purple: 0xA485FF, .magenta: 0xCF2F98
        ]
        let light: [RaycastHue: UInt32] = [
            .red: 0xB12424, .orange: 0xC75D07, .yellow: 0xF8A300, .green: 0x006B4F, .blue: 0x138AF2,
            .purple: 0x6A3DEC, .magenta: 0x9A1B6E
        ]
        for hue in RaycastHue.agentChoices {
            expect(hue.dark == dark[hue], "\(hue) on dark is Raycast Dark's value")
            expect(hue.light == light[hue], "\(hue) on light is Raycast Light's value")
        }
        expect(RaycastHue.red.dark == 0xFF6363, "red on dark is Raycast's brand red")
    }

    /// WCAG's 3:1 for a glyph, so a thin white stroke still reads on the amber and orange tiles.
    static func tilesHoldAWhiteGlyph() {
        for hue in RaycastHue.allCases {
            let ratio = contrast(hue.tile, 0xFFFFFF)
            expect(ratio >= 3, "a white glyph reads on the \(hue) tile (\(ratio))")
        }
        let tiles = Set(RaycastHue.allCases.map(\.tile))
        expect(tiles.count == RaycastHue.allCases.count, "every hue has a tile of its own")
    }

    /// Against the darkest and lightest the panel's scrim settles on over a desktop.
    static func glyphsReadOnTheirSurface() {
        for hue in RaycastHue.allCases {
            expect(contrast(hue.dark, 0x1E1E1E) >= 3, "\(hue) reads on the dark surface")
            expect(contrast(hue.tile, 0xF2F2F2) >= 3, "\(hue)'s tile tone reads as a glyph on the light one")
        }
    }

    /// The catalog's reds: a fill under white ink, text on either surface, a wash of the fill.
    static func theAccentReads() {
        guard let fill = colorSet("AccentColor"), let ink = colorSet("AccentInk"),
            let wash = colorSet("AccentSelection")
        else { return expect(false, "the accent colour sets read") }
        expect(contrast(fill.light.rgb, 0xFFFFFF) >= 4.5, "white reads on the light accent, and it on white")
        expect(contrast(fill.dark.rgb, 0xFFFFFF) >= 4, "white reads on the dark accent")
        expect(contrast(fill.dark.rgb, 0x1E1E1E) >= 4, "and the dark accent on the dark surface")
        expect(contrast(ink.light.rgb, 0xF2F2F2) >= 4.5, "a link reads on the light surface")
        expect(contrast(ink.dark.rgb, 0x1E1E1E) >= 4.5, "and on the dark one")
        expect(ink.dark.rgb == RaycastHue.red.dark, "dark links are Raycast's brand red")
        let sameRed = wash.light.rgb == fill.light.rgb && wash.dark.rgb == fill.dark.rgb
        expect(sameRed, "the selection is the accent's")
        expect(
            (0.1...0.3).contains(wash.light.alpha) && (0.1...0.3).contains(wash.dark.alpha),
            "a wash, never a fill white text would need")
    }

    static func anAgentKeepsItsColour() {
        let id = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!
        expect(RaycastHue.stable(for: id) == RaycastHue.stable(for: id), "the derived colour is stable")
        expect(RaycastHue.stable(for: id) == .purple, "and the same in every build: FNV-1a over the bytes")
        var seen: Set<RaycastHue> = []
        for _ in 0..<700 { seen.insert(RaycastHue.stable(for: UUID())) }
        expect(seen == Set(RaycastHue.agentChoices), "every agent colour is reachable, grey never")
        expect(RaycastHue.agent(named: nil, id: id) == RaycastHue.stable(for: id), "nil is derived")
        expect(RaycastHue.agent(named: "purple", id: id) == .purple, "a chosen colour wins")
        expect(RaycastHue.agent(named: "gray", id: id) == RaycastHue.stable(for: id), "grey is no agent's")
        expect(
            RaycastHue.agent(named: "chartreuse", id: id) == RaycastHue.stable(for: id),
            "a colour from a newer build reads as the derived one")
        expect(!RaycastHue.agentChoices.contains(.gray), "the swatches leave grey out")
    }

    static func everyFamilyHasAHue() {
        let unmapped = CommandID.allCases.filter { GlyphCategory.of($0) == nil }
        expect(unmapped.isEmpty, "every command has a family; give these one: \(unmapped)")
        let used = Set(GlyphCategory.allCases.map(\.hue))
        expect(used == Set(RaycastHue.allCases).subtracting([.magenta]), "families use every hue but magenta")
        expect(GlyphCategory.of(.quickAI)?.hue == .red, "AI is Raycast's red")
        expect(GlyphCategory.of(.clipboardHistory)?.hue == .orange, "clipboard is orange")
        expect(GlyphCategory.of(.askByVoice)?.hue == .blue, "voice is dictation's blue")
        expect(GlyphCategory.of(.switchWindows)?.hue == .purple, "windows are purple")
        expect(GlyphCategory.of(.searchQuicklinks)?.hue == .purple, "and quicklinks, as Raycast's tiles are")
        expect(GlyphCategory.of(.showNotes)?.hue == .yellow, "notes are yellow")
        expect(GlyphCategory.of(.settings)?.hue == .gray, "Tinycast's own housekeeping stays grey")
        let ai: [CommandID] = [.runAgentTask, .searchAgentSessions, .jumpToAgent, .aiUsage, .summarize]
        expect(ai.allSatisfy { GlyphCategory.of($0) == .ai }, "agent and AI commands share AI's red")
    }

    static func menuGlyphsFollowTheirMeaning() {
        expect(GlyphCategory.menuHue(forSymbol: "doc.on.doc") == .orange, "Copy is clipboard's orange")
        expect(GlyphCategory.menuHue(forSymbol: "folder") == .blue, "Show in Finder is blue")
        expect(GlyphCategory.menuHue(forSymbol: "star") == .yellow, "a favourite is yellow")
        expect(GlyphCategory.menuHue(forSymbol: "link") == .purple, "a link is quicklinks' purple")
        expect(GlyphCategory.menuHue(forSymbol: "sparkles") == nil, "an AI row stays neutral")
        expect(GlyphCategory.menuHue(forSymbol: "trash") == nil, "a delete row keeps the menu's own red")
        expect(GlyphCategory.menuHue(forSymbol: "eye.slash") == nil, "an unlisted glyph stays neutral")
        let hues = ["sparkles", "bubble.left", "person.crop.circle", "doc.on.doc", "pencil"]
            .compactMap(GlyphCategory.menuHue(forSymbol:))
        expect(!hues.contains(.red), "red in a menu is the destructive rows' alone")
    }

    /// A colour set's universal and dark entries, as `xcassets` writes them.
    static func colorSet(_ name: String) -> (light: Swatch, dark: Swatch)? {
        let url = URL(fileURLWithPath: "Tinycast/Assets.xcassets/\(name).colorset/Contents.json")
        guard let data = try? Data(contentsOf: url),
            let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let colors = root["colors"] as? [[String: Any]]
        else { return nil }
        let swatches = colors.map { entry -> (isDark: Bool, swatch: Swatch?) in
            let appearances = entry["appearances"] as? [[String: String]] ?? []
            return (appearances.contains { $0["value"] == "dark" }, Swatch(entry["color"]))
        }
        guard let light = swatches.first(where: { !$0.isDark })?.swatch,
            let dark = swatches.first(where: \.isDark)?.swatch
        else { return nil }
        return (light, dark)
    }

    struct Swatch {
        let rgb: UInt32
        let alpha: Double

        init?(_ color: Any?) {
            guard let components = (color as? [String: Any])?["components"] as? [String: String],
                let red = components["red"].flatMap(Self.channel),
                let green = components["green"].flatMap(Self.channel),
                let blue = components["blue"].flatMap(Self.channel),
                let alpha = components["alpha"].flatMap(Double.init)
            else { return nil }
            rgb = red << 16 | green << 8 | blue
            self.alpha = alpha
        }

        private static func channel(_ hex: String) -> UInt32? { UInt32(hex.dropFirst(2), radix: 16) }
    }

    static func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        let (la, lb) = (luminance(a), luminance(b))
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    static func luminance(_ hex: UInt32) -> Double {
        func channel(_ shift: UInt32) -> Double {
            let value = Double((hex >> shift) & 0xFF) / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(16) + 0.7152 * channel(8) + 0.0722 * channel(0)
    }
}
