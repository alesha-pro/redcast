import SwiftUI

/// A list beside its selected row's preview, split by the one rule a palette screen may draw.
struct PaletteSplitView<ListContent: View, PreviewContent: View>: View {
    @Environment(\.metrics) private var metrics
    @ViewBuilder let list: ListContent
    @ViewBuilder let preview: PreviewContent

    var body: some View {
        HStack(spacing: 0) {
            list.frame(width: metrics.size.clipboardListWidth)
            Rectangle().fill(Theme.Colors.separator).frame(width: Theme.Size.hairline)
            preview
        }
    }
}

extension View {
    /// The card a preview frames its picture, page or text in; `filled` for text, which has no edge.
    func previewStage(filled: Bool = false) -> some View {
        modifier(PreviewStage(filled: filled))
    }
}

private struct PreviewStage: ViewModifier {
    let filled: Bool
    @Environment(\.metrics) private var metrics
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: metrics.radius.previewStage, style: .continuous)
        content
            .background { if filled { shape.fill(Theme.Colors.cardFill) } }
            .clipShape(shape)
            .overlay(
                shape.strokeBorder(
                    contrast == .increased ? Theme.Colors.border : Theme.Colors.cardStroke,
                    lineWidth: Theme.Size.hairline))
    }
}
