import SwiftUI

/// Fork: what a surface is. The role owns its glass, tint, scrim and Reduce Transparency fallback.
enum GlassRole {
    /// The launcher's root: tinted glass with its own corner under a thin scrim.
    case palette
    /// A panel that is read: Notes, the camera, a Quick Action's result.
    case panel
    /// A transient readout: the volume box and the message pill.
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
        case .panel, .hud: .backdrop(.panel)
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

    static let panel = GlassBackdrop(scrim: Theme.Colors.panelScrim)
    static let balanced = GlassBackdrop(
        scrim: Theme.Colors.paletteScrim, tint: Theme.Colors.paletteGlassTint, ownsCorner: true)

    #if DEBUG
        /// What the palette shipped before its glass was tinted, kept to compare against.
        static let classic = panel
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
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        switch role.recipe {
        case .backdrop(let backdrop):
            content
                .background(scrim ?? backdrop.scrim)
                .background {
                    if reduceTransparency {
                        Theme.Colors.opaqueSurface
                    } else {
                        GlassEffectView(
                            cornerRadius: backdrop.ownsCorner ? cornerRadius : 0,
                            tint: backdrop.tint, style: backdrop.style)
                    }
                }
                .overlay { if reduceTransparency { rim } }
                .clipShape(shape)
        case .system(let glass, let roleScrim):
            if let veil = scrim ?? roleScrim {
                // One chain: branching around `content` would rebuild it, and drop a field's focus.
                content
                    .background(veil, in: shape)
                    .background { if reduceTransparency { shape.fill(Theme.Colors.opaqueSurface) } }
                    .glassEffect(reduceTransparency ? .identity : glass, in: shape)
                    .overlay { if reduceTransparency { rim } }
            } else {
                content.glassEffect(glass, in: shape)
            }
        }
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
    /// `scrim` replaces the role's own for a state that needs to, as the message pill's hover does.
    func glassSurface(_ role: GlassRole, in shape: some Shape, scrim: Color? = nil) -> some View {
        modifier(GlassSurface(role: role, shape: shape, scrim: scrim))
    }
}
