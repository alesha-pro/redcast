import SwiftUI

/// `AppCore` projects `AppSettings.interfaceMaterial` here; observed, so every surface swaps live.
@MainActor @Observable
final class SurfaceMaterial {
    static let shared = SurfaceMaterial()
    var isSolid = false

    private init() {}
}

/// Fork: what a surface is. The role owns its glass, tint, scrim and Reduce Transparency fallback.
enum GlassRole {
    /// The launcher's root: tinted glass with its own corner under a thin scrim.
    case palette
    /// A panel that is read, under a heavier veil: Notes, the camera, a Quick Action's result.
    case panel
    /// A transient readout, under the thinnest veil: the volume box and the message pill.
    case hud
    /// A dialog or an editor panel, which holds the user until it is answered.
    case modal
    /// A menu, switcher or callout hung off a control.
    case menu
    /// A small passive readout floating on its own: the dictation capsule, a mode caption.
    case chip
    /// A floating control. Its glass answers a press itself, so it takes no pressed fill.
    case control

    fileprivate var recipe: GlassRecipe {
        switch self {
        case .palette: .backdrop(.palette)
        case .panel: .backdrop(.reading)
        case .hud: .backdrop(.hud)
        case .modal: .system(.regular, scrim: Theme.Colors.panelScrim)
        case .menu, .chip: .system(.regular, scrim: nil)
        case .control: .system(.regular.interactive(), scrim: nil)
        }
    }
}

private enum GlassRecipe {
    /// AppKit glass behind a hand scrim, for a surface that is its whole window.
    case backdrop(GlassBackdrop)
    /// SwiftUI glass on the content itself, which draws its own edge and elevation.
    case system(Glass, scrim: Color?)
}

private struct GlassBackdrop: Sendable {
    let scrim: Color
    var tint: Color?
    var style = NSGlassEffectView.Style.regular
    /// Whether the glass rounds itself to the surface, so its edge light follows the corner.
    var ownsCorner = false

    static let balanced = GlassBackdrop(
        scrim: Theme.Colors.paletteScrim, tint: Theme.Colors.paletteGlassTint, ownsCorner: true)
    static let reading = GlassBackdrop(
        scrim: Theme.Colors.readingScrim, tint: Theme.Colors.readingGlassTint, ownsCorner: true)
    static let hud = GlassBackdrop(
        scrim: Theme.Colors.hudScrim, tint: Theme.Colors.hudGlassTint, ownsCorner: true)

    #if DEBUG
        /// What every backdrop shipped before its glass was tinted, kept to compare against.
        static let classic = GlassBackdrop(scrim: Theme.Colors.panelScrim)
        static let clear = GlassBackdrop(
            scrim: Theme.Colors.paletteScrim, tint: Theme.Colors.paletteGlassTint, style: .clear,
            ownsCorner: true)
    #endif

    /// Read once, when the palette's surface is first built; relaunch to switch presets.
    static let palette: GlassBackdrop = {
        #if DEBUG
            switch UserDefaults.standard.string(forKey: "paletteGlassPreset") {
            case "classic": return classic
            case "clear": return clear
            default: return balanced
            }
        #else
            return balanced
        #endif
    }()
}

private struct GlassSurface<S: Shape>: ViewModifier {
    let role: GlassRole
    let shape: S
    let scrim: Color?
    let tint: Color?
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        let opaque = reduceTransparency || SurfaceMaterial.shared.isSolid
        switch role.recipe {
        case .backdrop(let backdrop):
            content
                .background(scrim ?? backdrop.scrim)
                .background {
                    if opaque {
                        Theme.Colors.opaqueSurface
                    } else if backdrop.ownsCorner, shape is Capsule {
                        // A capsule's corner is half its short side, known only once laid out.
                        GeometryReader { proxy in
                            glass(backdrop, cornerRadius: min(proxy.size.width, proxy.size.height) / 2)
                        }
                    } else {
                        glass(backdrop, cornerRadius: backdrop.ownsCorner ? cornerRadius : 0)
                    }
                }
                .overlay { if opaque { rim } }
                .clipShape(shape)
        case .system(let base, let roleScrim):
            let glass = tint.map(base.tint) ?? base
            if let veil = scrim ?? roleScrim {
                // One chain: branching around `content` would rebuild it, and drop a field's focus.
                content
                    .background(veil, in: shape)
                    .background { if opaque { shape.fill(Theme.Colors.opaqueSurface) } }
                    .glassEffect(opaque ? .identity : glass, in: shape)
                    .overlay { if opaque { rim } }
            } else {
                // Not `opaque`: Reduce Transparency alone leaves system glass its own look.
                let solid = SurfaceMaterial.shared.isSolid
                content
                    .background { if solid { lifted(tint: tint) } }
                    .glassEffect(solid ? .identity : glass, in: shape)
                    .overlay { if solid { rim } }
            }
        }
    }

    private func glass(_ backdrop: GlassBackdrop, cornerRadius: CGFloat) -> GlassEffectView {
        GlassEffectView(cornerRadius: cornerRadius, tint: tint ?? backdrop.tint, style: backdrop.style)
    }

    /// A floating layer's solid stand-in, lifted off the solid backdrop it hangs over.
    private func lifted(tint: Color?) -> some View {
        shape.fill(Theme.Colors.elevatedSurface)
            .overlay { if let tint { shape.fill(tint) } }
    }

    /// AppKit's glass only rounds evenly, so any other shape leaves the corner to the clip.
    private var cornerRadius: CGFloat {
        (shape as? RoundedRectangle)?.cornerSize.width ?? 0
    }

    /// Stroked at twice the width and clipped, which insets it for a shape that cannot inset.
    private var rim: some View {
        shape.stroke(Theme.Colors.border, lineWidth: Theme.Size.hairline * 2)
            .clipShape(shape)
            .allowsHitTesting(false)
    }
}

extension View {
    /// `scrim` and `tint` replace the role's for one state: the pill's hover, a live microphone.
    func glassSurface(
        _ role: GlassRole, in shape: some Shape, scrim: Color? = nil, tint: Color? = nil
    ) -> some View {
        modifier(GlassSurface(role: role, shape: shape, scrim: scrim, tint: tint))
    }
}
