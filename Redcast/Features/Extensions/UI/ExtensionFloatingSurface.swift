import SwiftUI

extension View {
    /// An extension's floating panel or pill: glass, or a lifted solid fill while Solid is picked.
    func extensionFloatingSurface(_ glass: Glass, in shape: some Shape) -> some View {
        modifier(ExtensionFloatingSurface(glass: glass, shape: shape))
    }
}

/// Kept apart from `glassSurface`, so the launcher's roles can change without moving these.
private struct ExtensionFloatingSurface<S: Shape>: ViewModifier {
    let glass: Glass
    let shape: S

    func body(content: Content) -> some View {
        let solid = SurfaceMaterial.shared.isSolid
        content
            .background { if solid { shape.fill(Theme.Colors.elevatedSurface) } }
            .glassEffect(solid ? .identity : glass, in: shape)
            .overlay {
                if solid {
                    shape.stroke(Theme.Colors.border, lineWidth: Theme.Size.hairline * 2)
                        .clipShape(shape)
                        .allowsHitTesting(false)
                }
            }
    }
}
