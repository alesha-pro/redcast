import AppKit

/// Fork: every built-in tile, in one place, on a 24-unit grid: a lit gradient, an accent colour on
/// the glyph, and real colour for objects that have one, so that no tile is just white on flat.
nonisolated enum TileArtwork {
    private typealias Art = @Sendable (NSColor) -> Void

    /// Grey for a tile no family claims; fixed like the hues, so white ink holds either way.
    static let neutral = NSColor(srgbRed: 0x7A / 255.0, green: 0x7F / 255.0, blue: 0x8A / 255.0, alpha: 1)

    private static let grid: CGFloat = 24
    private static let ink = NSColor.white
    private static let amber = rgb(0xFFC531)
    private static let mint = rgb(0x59D499)

    /// Grey only while Colourful Icons is off; on, a grey tile is slate with an accent.
    private static let slate = rgb(0x56688F)

    /// Real emoji, set small on the tile like any glyph; the glaze would dull its own colours.
    private static let tileEmoji = ["face.smiling": "😀"]

    /// Objects with a colour of their own, whatever the tile: a bolt is yellow, a leaf is green.
    private static let objectColors: [String: NSColor] = [
        "bolt": amber, "bolt.fill": amber, "moon.zzz": amber, "folder": amber, "lock": amber,
        "book.closed": rgb(0xFFE3A3), "bell.slash": amber, "clock": rgb(0xFFE3A3),
        "plus": amber, "plus.forwardslash.minus": rgb(0xFFE3A3), "wand.and.sparkles": amber,
        "wand.and.stars": amber, "pencil": amber, "pencil.and.scribble": amber,
        "curlybraces": rgb(0xFFE3A3), "link": rgb(0xD9CCFF), "trash": rgb(0xFFD9D6),
        "power": rgb(0xB8FFD6), "camera": rgb(0xD6F5E3), "video.fill": rgb(0xFFE3A3),
        "person.crop.circle": amber, "pin": rgb(0xFF8A80)
    ]

    /// Draws into the current context. Pinned to Aqua: some symbols swap shape with appearance.
    static func draw(symbol name: String, base proposed: NSColor?, in tile: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let vividBase = proposed.map(vivid) ?? neutral
        // A yellow face on a gold tile washes out; a deeper tone behind it lets it pop.
        let base = tileEmoji[name] == nil ? vividBase : shade(vividBase, 0.32)
        let unit = tile.width / grid
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
            context.saveGState()
            context.translateBy(x: tile.minX, y: tile.minY)
            context.scaleBy(x: unit, y: unit)
            drawBody(base: base, unit: unit, context: context)
            context.setShadow(
                offset: CGSize(width: 0, height: -0.35 * unit), blur: 0.9 * unit,
                color: NSColor.black.withAlphaComponent(0.22).cgColor)
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            if let emoji = tileEmoji[name] {
                drawEmoji(emoji, in: NSRect(x: 4.5, y: 4.5, width: 15, height: 15))
            } else if let art = compositions[name] {
                art(base)
                glaze(accent(for: base))
            } else {
                drawGlyph(name, base: base, unit: unit)
                glaze(accent(for: base))
            }
            context.endTransparencyLayer()
            context.restoreGState()
        }
    }

    private static func drawBody(base: NSColor, unit: CGFloat, context: CGContext) {
        let bounds = NSRect(x: 0, y: 0, width: grid, height: grid)
        let path = NSBezierPath(roundedRect: bounds, xRadius: 5.6, yRadius: 5.6)
        context.saveGState()
        context.setShadow(
            offset: CGSize(width: 0, height: -0.6 * unit), blur: 1.8 * unit,
            color: NSColor.black.withAlphaComponent(0.3).cgColor)
        base.setFill()
        path.fill()
        context.restoreGState()
        NSGradient(colors: [lighten(base, 0.1), shade(base, 0.14)])?.draw(in: path, angle: 90)
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        NSGradient(colors: [ink.withAlphaComponent(0.16), ink.withAlphaComponent(0)])?
            .draw(in: NSRect(x: 0, y: 0, width: grid, height: grid / 2), angle: 90)
        NSGraphicsContext.restoreGraphicsState()

        let ring = NSBezierPath(roundedRect: bounds, xRadius: 5.6, yRadius: 5.6)
        ring.append(
            NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 5.1, yRadius: 5.1))
        ring.windingRule = .evenOdd
        NSGradient(colors: [ink.withAlphaComponent(0.34), ink.withAlphaComponent(0.08)])?
            .draw(in: ring, angle: 90)
    }

    // MARK: - Glyphs

    /// Tints the glyph's lower half with the accent, so even a one-colour glyph has depth.
    private static func glaze(_ accent: NSColor) {
        guard let current = NSGraphicsContext.current else { return }
        current.saveGraphicsState()
        current.compositingOperation = .sourceAtop
        NSGradient(colors: [accent.withAlphaComponent(0), accent.withAlphaComponent(0.2)])?
            .draw(in: NSRect(x: 0, y: 0, width: grid, height: grid), angle: 90)
        current.restoreGraphicsState()
    }

    /// Any symbol or brand asset: its filled form where that reads, in the tile's second colour.
    private static func drawGlyph(_ name: String, base: NSColor, unit: CGFloat) {
        guard NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil else {
            drawAsset(name, unit: unit)
            return
        }
        let second = accent(for: base)
        switch filledForm(of: name) {
        case .plain(let symbol):
            // A line glyph has no body to carry white, so the accent is what gives it presence.
            let isLine = symbol == name && !name.hasSuffix(".fill") && !name.contains("filled")
            draw(symbol, 14.5, .semibold, colors: [objectColors[name] ?? (isLine ? second : ink)], unit: unit)
        case .marked(let symbol):
            draw(symbol, 14.5, .semibold, colors: [shade(base, 0.2), objectColors[name] ?? ink], unit: unit)
        case .layered(let symbol):
            draw(symbol, 14.5, .semibold, colors: [second, ink], unit: unit)
        }
    }

    private enum FilledForm {
        case plain(String)
        /// A mark inside a fill, inked deep so it holds on white.
        case marked(String)
        /// Two parts side by side, or a mark reaching past its fill: the second takes the accent.
        case layered(String)
    }

    /// Counted, not listed, so a symbol upstream adds needs no entry: a mark knocked out of a fill
    /// vanishes in one colour, and an off-centre one reads only against the outline.
    private static func filledForm(of name: String) -> FilledForm {
        let filled = name.hasSuffix(".fill") ? name : name + ".fill"
        let hasFill = NSImage(systemSymbolName: filled, accessibilityDescription: nil) != nil
        guard hasFill, let layers = LayerExtents(symbol: filled) else {
            guard let layers = LayerExtents(symbol: name), layers.hasMark else { return .plain(name) }
            return .layered(name)
        }
        guard layers.hasMark else { return .plain(filled) }
        if layers.markIsEnclosed { return .marked(filled) }
        return layers.markIsInside ? .layered(name) : .layered(filled)
    }

    /// Where a symbol's two palette layers land, from one small raster.
    private struct LayerExtents {
        private static let side = 32
        private var mark = NSRect.null
        private var fill = NSRect.null

        var hasMark: Bool { !mark.isNull && !fill.isNull }

        var markIsInside: Bool { fill.insetBy(dx: 1, dy: 1).contains(mark) }

        var markIsEnclosed: Bool {
            let center = NSPoint(x: fill.midX, y: fill.midY)
            let reach = CGFloat(Self.side) * 0.14
            return markIsInside
                && abs(mark.midX - center.x) < reach && abs(mark.midY - center.y) < reach
        }

        init?(symbol: String) {
            guard
                let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                    .withSymbolConfiguration(
                        NSImage.SymbolConfiguration(pointSize: CGFloat(Self.side) / 2, weight: .semibold)
                            .applying(NSImage.SymbolConfiguration(paletteColors: [.red, .blue]))),
                let rep = NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: Self.side, pixelsHigh: Self.side,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                let context = NSGraphicsContext(bitmapImageRep: rep)
            else { return nil }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            let size = image.size
            image.draw(
                in: NSRect(
                    x: (CGFloat(Self.side) - size.width) / 2, y: (CGFloat(Self.side) - size.height) / 2,
                    width: size.width, height: size.height))
            NSGraphicsContext.restoreGraphicsState()
            for y in 0..<Self.side {
                for x in 0..<Self.side {
                    guard let pixel = rep.colorAt(x: x, y: y), pixel.alphaComponent > 0.5 else { continue }
                    let dot = NSRect(x: x, y: y, width: 1, height: 1)
                    if pixel.redComponent > 0.5 {
                        mark = mark.union(dot)
                    } else {
                        fill = fill.union(dot)
                    }
                }
            }
        }
    }

    private static func draw(
        _ name: String, _ points: CGFloat, _ weight: NSFont.Weight, colors: [NSColor], unit: CGFloat,
        center: NSPoint = NSPoint(x: grid / 2, y: grid / 2)
    ) {
        let configuration = NSImage.SymbolConfiguration(pointSize: points * unit, weight: weight)
            .applying(NSImage.SymbolConfiguration(paletteColors: colors))
        guard
            let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration)
        else { return }
        let size = NSSize(width: image.size.width / unit, height: image.size.height / unit)
        image.draw(
            in: NSRect(
                x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width,
                height: size.height),
            from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    private static func drawAsset(_ name: String, unit: CGFloat) {
        guard let asset = NSImage(named: name) else { return }
        let side: CGFloat = 15
        let white = NSImage(size: NSSize(width: side * unit, height: side * unit), flipped: false) { rect in
            asset.draw(in: rect)
            ink.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        white.draw(
            in: NSRect(x: (grid - side) / 2, y: (grid - side) / 2, width: side, height: side),
            from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    private static let compositions: [String: Art] = [
        "switch.2": general,
        "keyboard": shortcuts,
        "square.grid.2x2": applications,
        "terminal": commands,
        "doc.on.clipboard": clipboard,
        "doc.text.magnifyingglass": fileSearch,
        "macwindow": windowManagement,
        "text.page": notes,
        "calendar": calendar,
        "waveform": dictation,
        "sparkles": ai,
        "gearshape": gear
    ]

    // MARK: - Compositions

    private static let general: Art = { base in
        fill(5.5, 12.8, 13, 5.2, 2.6, ink.withAlphaComponent(0.4))
        fill(6.2, 13.5, 3.8, 3.8, 1.9, ink)
        fill(5.5, 6, 13, 5.2, 2.6, ink)
        fill(13.9, 6.7, 3.8, 3.8, 1.9, shade(base, 0.25))
    }

    private static let shortcuts: Art = { base in
        fill(4.5, 5.4, 15, 15, 3.8, ink.withAlphaComponent(0.55))
        fill(4.5, 4.2, 15, 14, 3.6, ink)
        let unit = NSGraphicsContext.current?.cgContext.ctm.a.magnitude ?? 1
        draw("command", 9.5, .bold, colors: [shade(base, 0.2)], unit: unit, center: NSPoint(x: 12, y: 11.2))
    }

    /// Colour only on a coloured tile: with the switch off, four tones of white.
    private static let applications: Art = { base in
        let colorful = base != neutral
        let side: CGFloat = 6
        let gap: CGFloat = 1.4
        let origin: CGFloat = 5.3
        fill(origin, origin, side, side, 1.7, ink)
        fill(origin + side + gap, origin, side, side, 1.7, colorful ? amber : ink.withAlphaComponent(0.82))
        fill(origin, origin + side + gap, side, side, 1.7, colorful ? mint : ink.withAlphaComponent(0.7))
        fill(origin + side + gap, origin + side + gap, side, side, 1.7, ink.withAlphaComponent(0.62))
    }

    private static let commands: Art = { base in
        fill(4.5, 6, 15, 12, 3, shade(base, 0.8))
        stroke([(7.6, 9.3), (10, 11.6), (7.6, 13.9)], 1.4, ink)
        stroke([(11.6, 14.4), (15.6, 14.4)], 1.4, ink.withAlphaComponent(0.8))
    }

    private static let clipboard: Art = { base in
        fill(6.5, 5.6, 11, 14, 2.4, ink)
        fill(9, 4, 6, 3.2, 1.2, shade(base, 0.35))
        fill(8.7, 10.4, 6.6, 1.4, 0.7, base)
        fill(8.7, 13.6, 4.6, 1.4, 0.7, base.withAlphaComponent(0.65))
    }

    private static let fileSearch: Art = { base in
        fill(5.2, 4.2, 11, 14.5, 2.2, ink)
        let faint = base.withAlphaComponent(0.45)
        fill(7.2, 7.2, 7, 1.3, 0.65, faint)
        fill(7.2, 9.8, 4.2, 1.3, 0.65, faint)
        let lens = shade(base, 0.35)
        let ring = NSBezierPath(ovalIn: NSRect(x: 10.6, y: 10.6, width: 7.4, height: 7.4))
        ring.lineWidth = 1.8
        ink.setFill()
        ring.fill()
        lens.setStroke()
        ring.stroke()
        stroke([(17.2, 17.2), (19.4, 19.4)], 2.1, lens)
    }

    private static let windowManagement: Art = { _ in
        fill(4.5, 6, 8.8, 12, 2.2, ink)
        fill(14.3, 6, 5.2, 5.5, 1.8, ink.withAlphaComponent(0.8))
        fill(14.3, 12.5, 5.2, 5.5, 1.8, ink.withAlphaComponent(0.55))
    }

    private static let gear: Art = { base in
        let hub = NSBezierPath(ovalIn: NSRect(x: 8.5, y: 8.5, width: 7, height: 7))
        accent(for: base).setFill()
        hub.fill()
        let unit = NSGraphicsContext.current?.cgContext.ctm.a.magnitude ?? 1
        draw("gearshape.fill", 15, .medium, colors: [ink], unit: unit)
    }

    private static let notes: Art = { base in
        let page = NSBezierPath()
        page.move(to: NSPoint(x: 8.4, y: 4.5))
        page.line(to: NSPoint(x: 14, y: 4.5))
        page.line(to: NSPoint(x: 18, y: 8.5))
        page.line(to: NSPoint(x: 18, y: 17.1))
        page.appendArc(
            withCenter: NSPoint(x: 15.6, y: 17.1), radius: 2.4, startAngle: 0, endAngle: 90)
        page.line(to: NSPoint(x: 8.4, y: 19.5))
        page.appendArc(
            withCenter: NSPoint(x: 8.4, y: 17.1), radius: 2.4, startAngle: 90, endAngle: 180)
        page.line(to: NSPoint(x: 6, y: 6.9))
        page.appendArc(
            withCenter: NSPoint(x: 8.4, y: 6.9), radius: 2.4, startAngle: 180, endAngle: 270)
        page.close()
        ink.setFill()
        page.fill()
        let fold = NSBezierPath()
        fold.move(to: NSPoint(x: 14, y: 4.5))
        fold.line(to: NSPoint(x: 14, y: 8.5))
        fold.line(to: NSPoint(x: 18, y: 8.5))
        fold.close()
        base.blended(withFraction: 0.45, of: .white)?.setFill()
        fold.fill()
        let lines = shade(base, 0.05)
        fill(8.2, 10.4, 7.6, 1.3, 0.65, lines)
        fill(8.2, 13, 7.6, 1.3, 0.65, lines)
        fill(8.2, 15.6, 4.6, 1.3, 0.65, lines)
    }

    private static let calendar: Art = { base in
        let page = NSRect(x: 5, y: 5.5, width: 14, height: 13.5)
        fill(page.minX, page.minY, page.width, page.height, 3, ink)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: page, xRadius: 3, yRadius: 3).addClip()
        shade(base, 0.35).setFill()
        NSRect(x: page.minX, y: page.minY, width: page.width, height: 4).fill()
        NSGraphicsContext.restoreGraphicsState()
        let dot = neutral
        for row in 0..<2 {
            for column in 0..<3 {
                let today = row == 1 && column == 1
                fill(
                    7.4 + CGFloat(column) * 3.5, 11.2 + CGFloat(row) * 3.2, 2, 2, 0.7,
                    today ? shade(base, 0.05) : dot)
            }
        }
    }

    private static let dictation: Art = { _ in
        let bars: [(x: CGFloat, height: CGFloat, alpha: CGFloat)] = [
            (6, 4.5, 0.7), (9, 9.5, 0.85), (12, 14, 1), (15, 8, 1), (18, 4.5, 0.7)
        ]
        for bar in bars {
            fill(bar.x - 1, 12 - bar.height / 2, 2, bar.height, 1, ink.withAlphaComponent(bar.alpha))
        }
    }

    private static let ai: Art = { base in
        fill(4.5, 5, 15, 12, 4, ink)
        let tail = NSBezierPath()
        tail.move(to: NSPoint(x: 8, y: 16))
        tail.line(to: NSPoint(x: 7.6, y: 20))
        tail.line(to: NSPoint(x: 12.4, y: 16.6))
        tail.close()
        ink.setFill()
        tail.fill()
        sparkle(center: NSPoint(x: 12, y: 11), radius: 5, color: base)
    }

    // MARK: - Pen

    private static func fill(
        _ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, _ radius: CGFloat,
        _ color: NSColor
    ) {
        color.setFill()
        NSBezierPath(
            roundedRect: NSRect(x: x, y: y, width: width, height: height), xRadius: radius,
            yRadius: radius
        ).fill()
    }

    private static func stroke(_ points: [(CGFloat, CGFloat)], _ width: CGFloat, _ color: NSColor) {
        guard let first = points.first else { return }
        let path = NSBezierPath()
        path.lineWidth = width
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.move(to: NSPoint(x: first.0, y: first.1))
        for point in points.dropFirst() { path.line(to: NSPoint(x: point.0, y: point.1)) }
        color.setStroke()
        path.stroke()
    }

    private static func sparkle(center: NSPoint, radius: CGFloat, color: NSColor) {
        let pull = radius * 0.16
        let path = NSBezierPath()
        let tips = [(0.0, -1.0), (1.0, 0.0), (0.0, 1.0), (-1.0, 0.0)]
        let waists = [(1.0, -1.0), (1.0, 1.0), (-1.0, 1.0), (-1.0, -1.0)]
        path.move(to: NSPoint(x: center.x, y: center.y - radius))
        for index in tips.indices {
            let next = tips[(index + 1) % tips.count]
            let waist = NSPoint(
                x: center.x + waists[index].0 * pull, y: center.y + waists[index].1 * pull)
            path.curve(
                to: NSPoint(x: center.x + next.0 * radius, y: center.y + next.1 * radius),
                controlPoint1: waist, controlPoint2: waist)
        }
        path.close()
        color.setFill()
        path.fill()
    }

    private static func drawEmoji(_ emoji: String, in tile: NSRect) {
        let probe = NSFont(name: "Apple Color Emoji", size: 100) ?? .systemFont(ofSize: 100)
        let measured = NSAttributedString(string: emoji, attributes: [.font: probe]).size()
        // The font's box is roomier than the glyph, which would otherwise sit small beside a tile.
        let points = 125 * tile.width / max(measured.width, measured.height)
        let face = NSAttributedString(string: emoji, attributes: [.font: probe.withSize(points)])
        let size = face.size()
        face.draw(at: NSPoint(x: tile.midX - size.width / 2, y: tile.midY - size.height / 2))
    }

    /// The second colour on a tile: warm on cool tiles and the reverse. White while switched off.
    private static func accent(for base: NSColor) -> NSColor {
        if base == neutral { return ink }
        guard let color = base.usingColorSpace(.sRGB) else { return ink }
        switch color.hueComponent {
        case ..<0.04, 0.95...: return amber
        case ..<0.09: return rgb(0xFFE9B8)
        case ..<0.16: return rgb(0xFFF0C2)
        case ..<0.5: return rgb(0xFFE36E)
        case ..<0.64: return color.saturationComponent < 0.5 ? rgb(0x8FE3FF) : amber
        case ..<0.8: return rgb(0xFFB3E8)
        default: return amber
        }
    }

    /// The two tones that read as dull at this size: grey becomes slate, mustard becomes gold.
    private static func vivid(_ color: NSColor) -> NSColor {
        guard let srgb = color.usingColorSpace(.sRGB) else { return color }
        if srgb.saturationComponent < 0.12 { return slate }
        return (0.09..<0.16).contains(srgb.hueComponent) ? rgb(0xDB9200) : color
    }

    private static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    private static func lighten(_ base: NSColor, _ amount: CGFloat) -> NSColor {
        base.blended(withFraction: amount, of: .white) ?? base
    }

    /// The tone mixed toward black, the art's only source of a deeper ink.
    private static func shade(_ base: NSColor, _ amount: CGFloat) -> NSColor {
        base.blended(withFraction: amount, of: .black) ?? base
    }
}
