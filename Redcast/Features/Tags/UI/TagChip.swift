import SwiftUI

/// Fork: one tag as a small capsule in its own colour, which reads on the light and dark surface.
struct TagChip: View {
    let tag: String
    var onRemove: (() -> Void)?

    @Environment(\.metrics) private var metrics

    var body: some View {
        let hue = RaycastHue.tag(tag).color
        HStack(spacing: metrics.spacing.xxs) {
            Text(verbatim: tag)
                .lineLimit(1)
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(metrics.typography.compactKeyCap.weight(.bold))
                        .imageScale(.small)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Remove tag \(tag)"))
            }
        }
        .font(onRemove == nil ? metrics.typography.compactKeyCap : metrics.typography.keyCap)
        .foregroundStyle(hue)
        .padding(.horizontal, metrics.spacing.sm)
        .padding(.vertical, metrics.spacing.xxs / 2)
        .background(Capsule(style: .continuous).fill(hue.opacity(0.16)))
        .fixedSize()
    }
}

/// Fork: a row's tags, a couple of chips and a count of the rest, so a long list never wraps.
struct TagChips: View {
    let tags: [String]
    var limit = 2

    @Environment(\.metrics) private var metrics

    var body: some View {
        if !tags.isEmpty {
            HStack(spacing: metrics.spacing.xs) {
                ForEach(tags.prefix(limit), id: \.self) { TagChip(tag: $0) }
                if tags.count > limit {
                    Text(verbatim: "+\(tags.count - limit)")
                        .font(metrics.typography.compactKeyCap)
                        .foregroundStyle(Theme.Colors.textTertiary)
                }
            }
            .fixedSize()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Tags: \(tags.formatted(.list(type: .and)))"))
        }
    }
}

/// Fork: chips left to right, wrapping onto as many lines as they need.
struct TagFlow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let frames = arrange(subviews, width: width)
        let height = frames.map(\.maxY).max() ?? 0
        let used = frames.map(\.maxX).max() ?? 0
        return CGSize(width: proposal.width ?? used, height: height)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        for (subview, frame) in zip(subviews, arrange(subviews, width: bounds.width)) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [CGRect] {
        var frames: [CGRect] = []
        var origin = CGPoint.zero
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if origin.x > 0, origin.x + size.width > width {
                origin = CGPoint(x: 0, y: origin.y + lineHeight + spacing)
                lineHeight = 0
            }
            frames.append(CGRect(origin: origin, size: size))
            origin.x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return frames
    }
}
