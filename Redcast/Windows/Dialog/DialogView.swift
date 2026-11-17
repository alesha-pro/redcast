import SwiftUI

extension DialogTone {
    /// Tints the subject glyph only; buttons take their color from `DialogAction.Role`.
    var tint: Color {
        switch self {
        case .neutral: return .secondary
        case .success: return Theme.Colors.success
        case .danger: return Theme.Colors.destructive
        }
    }

    /// The tile's wash, a step stronger at its top edge so it reads lit rather than flat.
    fileprivate var tileFill: LinearGradient {
        let wash = self == .neutral ? Theme.Opacity.toneTileNeutral : Theme.Opacity.toneTile
        return LinearGradient(
            colors: [tint.opacity(wash + Theme.Opacity.toneTileLift), tint.opacity(wash)],
            startPoint: .top, endPoint: .bottom)
    }
}

/// Redcast's Liquid Glass dialog, compact unless a native control needs more room.
struct DialogView: View {
    @Environment(\.metrics) private var metrics
    let request: DialogRequest
    let width: CGFloat
    let focus: DialogFocusState
    let onChoose: (Int) -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: metrics.radius.panel, style: .continuous)
        VStack(alignment: .leading, spacing: metrics.spacing.xxl) {
            VStack(alignment: .leading, spacing: metrics.spacing.xxl) {
                if let symbol = request.symbol {
                    DialogSymbol(name: symbol, tone: request.tone)
                }

                VStack(alignment: .leading, spacing: metrics.spacing.sm) {
                    Text(request.title)
                        .font(metrics.typography.panelTitle)
                    if let message = request.message {
                        Text(message)
                            .font(metrics.typography.rowTitle)
                            .foregroundStyle(Theme.Colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                switch request.accessory {
                case .volume(let volume): VolumeSlider(state: volume)
                case .snippetArguments(let arguments): SnippetArgumentFields(state: arguments)
                case .clipboardText(let state): ClipboardEditField(state: state)
                case nil: EmptyView()
                }
            }
            .padding(.horizontal, metrics.spacing.xs)
            .padding(.top, metrics.spacing.xs)
            .frame(maxWidth: .infinity, alignment: .leading)

            actions
        }
        .padding(metrics.spacing.dialogInset)
        .frame(width: width, alignment: .leading)
        .glassSurface(.modal, in: shape)
    }

    @ViewBuilder private var actions: some View {
        if request.actions.count == 2 {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: metrics.spacing.md) { actionButtons(singleLine: true) }
                VStack(spacing: metrics.spacing.md) { actionButtons(singleLine: false) }
            }
        } else if request.actions.count > 2 {
            VStack(spacing: metrics.spacing.md) { actionButtons }
        } else {
            HStack(spacing: metrics.spacing.md) { actionButtons }
        }
    }

    private var actionButtons: some View {
        actionButtons(singleLine: false)
    }

    private func actionButtons(singleLine: Bool) -> some View {
        ForEach(visualOrder, id: \.self) { index in
            DialogButton(
                action: request.actions[index],
                isDefault: index == request.defaultIndex,
                keyCaps: keyCaps(for: index),
                isFocused: focus.index == index,
                panelWalks: request.panelWalksActions,
                singleLine: singleLine,
                onActivate: { onChoose(index) }
            )
        }
    }

    private var visualOrder: [Int] { Self.visualOrder(of: request.actions) }

    /// Cancel leads a horizontal pair; a vertical choice keeps the caller's semantic order.
    static func visualOrder(of actions: [DialogAction]) -> [Int] {
        guard actions.count < 3 else { return Array(actions.indices) }
        return actions.indices.sorted { rank(of: actions[$0]) < rank(of: actions[$1]) }
    }

    private static func rank(of action: DialogAction) -> Int {
        action.role == .cancel ? 0 : 1
    }

    /// Only the keys the panel handles are advertised, so a tooltip can't drift.
    private func keyCaps(for index: Int) -> [String] {
        if index == request.defaultIndex {
            return request.accessory?.acceptsLineBreaks == true ? ["⌘", "↵"] : ["↵"]
        }
        if index == request.cancelIndex { return ["esc"] }
        return []
    }
}

private struct DialogSymbol: View {
    @Environment(\.metrics) private var metrics
    let name: String
    let tone: DialogTone

    var body: some View {
        SymbolImage(name: name, size: metrics.size.dialogSymbol, monochrome: true)
            .foregroundStyle(symbolTint)
            .frame(
                width: metrics.size.dialogSymbolContainer,
                height: metrics.size.dialogSymbolContainer
            )
            .background {
                let tile = RoundedRectangle(cornerRadius: metrics.radius.dialogSymbol, style: .continuous)
                tile.fill(tone.tileFill)
                    .overlay {
                        tile.strokeBorder(
                            tone.tint.opacity(Theme.Opacity.toneTileEdge), lineWidth: Theme.Size.hairline)
                    }
            }
    }

    /// Neutral glyphs need the same legibility as a key-cap symbol; semantic colours stay intact.
    private var symbolTint: Color {
        tone == .neutral ? Theme.Colors.textSecondary : tone.tint
    }
}

private struct DialogButton: View {
    @Environment(\.metrics) private var metrics
    let action: DialogAction
    let isDefault: Bool
    let keyCaps: [String]
    let isFocused: Bool
    let panelWalks: Bool
    var singleLine = false
    let onActivate: () -> Void

    var body: some View {
        Group {
            if panelWalks {
                // Tab is the panel's, so a system focus and ring would only be a second one.
                button.focusable(false)
            } else {
                button
            }
        }
        .overlay {
            // Stood off the capsule: on the solid accent an inset ring would vanish into it.
            if isFocused {
                Capsule()
                    .strokeBorder(Theme.Colors.focusRing, lineWidth: Theme.Size.focusRingWidth)
                    .padding(-metrics.spacing.xs)
                    .allowsHitTesting(false)
            }
        }
        .tooltip(keyCaps: keyCaps)
    }

    private var button: some View {
        Button(action: onActivate) {
            Text(action.title)
                .fixedSize(horizontal: singleLine, vertical: false)
                .multilineTextAlignment(.center)
        }
        .buttonStyle(.modalAction(role))
    }

    private var role: ModalActionButtonStyle.Role {
        if isDefault, action.role == .standard { return .primary }
        return switch action.role {
        case .standard: .standard
        case .destructive: .destructive
        case .cancel: .cancel
        }
    }
}

/// The button Tab has walked to: nil until Tab is pressed, so a dialog opens with no ring.
@MainActor
@Observable
final class DialogFocusState {
    private(set) var index: Int?

    /// Steps through `order`, the buttons as drawn, wrapping at either end.
    func move(forward: Bool, through order: [Int]) {
        guard !order.isEmpty else { return }
        let next: Int
        if let current = index.flatMap(order.firstIndex(of:)) {
            next = (current + (forward ? 1 : order.count - 1)) % order.count
        } else {
            next = forward ? 0 : order.count - 1
        }
        index = order[next]
    }
}
