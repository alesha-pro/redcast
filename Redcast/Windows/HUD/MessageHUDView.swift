import SwiftUI

struct MessageHUDView: View {
    enum Accessory: Equatable {
        case tone(DialogTone)
        case progress
    }

    private static let glowOpacity = 0.14
    private static let glowRadius: CGFloat = 150
    private static let rimOpacity = 0.25

    let message: String
    let accessory: Accessory
    var onCancel: (() -> Void)? = nil
    @State private var hovered = false
    @Environment(\.metrics) private var metrics
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        // Always a button, so a spinner replaced by its result keeps one tree to cross-fade in.
        Button {
            onCancel?()
        } label: {
            content
        }
        .buttonStyle(.plain)
        .accessibilityRemoveTraits(onCancel == nil ? .isButton : [])
        .accessibilityLabel(onCancel == nil ? Text(message) : Text("Cancel \(message)"))
        .onHover { isHovered in
            withAnimation(Theme.Motion.hover) {
                hovered = isHovered
            }
        }
        // A pill that stops taking the mouse never hears it leave, so it forgets the hover itself.
        .onChange(of: onCancel == nil) { _, passive in
            if passive { hovered = false }
        }
        .panelEntrance()
    }

    /// Hover only lights a pill that can be cancelled; the pill it becomes may not be.
    private var lit: Bool { hovered && onCancel != nil }

    private var tint: Color {
        switch accessory {
        case .tone(let tone): tone.tint
        case .progress: Theme.Colors.progress
        }
    }

    private var content: some View {
        HStack(spacing: metrics.spacing.md) {
            mark
            Text(message)
                .font(metrics.typography.bar)
                .foregroundStyle(Color.primary)
                .lineLimit(1)
                .contentTransition(.opacity)
        }
        .animation(Theme.Motion.swap, value: message)
        .animation(Theme.Motion.swap, value: accessory)
        .padding(.horizontal, metrics.spacing.xl)
        .padding(.vertical, metrics.spacing.lg)
        .frame(maxWidth: metrics.size.hudMaxWidth, alignment: .leading)
        .fixedSize()
        .background { glow }
        // Not SwiftUI glass: with nothing to lens it falls back to an opaque backing and shows.
        .glassSurface(.hud, in: Capsule(), scrim: lit ? Theme.Colors.controlHover : nil)
        .overlay { if !reduceTransparency { rim } }
    }

    private var glow: some View {
        GeometryReader { proxy in
            Capsule().fill(
                RadialGradient(
                    colors: [tint.opacity(Self.glowOpacity), tint.opacity(0.03), .clear],
                    center: UnitPoint(
                        x: (metrics.spacing.xl + metrics.size.menuIcon / 2) / proxy.size.width,
                        y: 0.5),
                    startRadius: 0, endRadius: Self.glowRadius))
        }
    }

    /// The tone's accent only: the glass draws the pill's edge itself.
    private var rim: some View {
        Capsule().strokeBorder(
            LinearGradient(
                colors: [tint.opacity(Self.rimOpacity), tint.opacity(0.06), .clear],
                startPoint: .leading, endPoint: .trailing),
            lineWidth: Theme.Size.hairline)
    }

    /// One box for both marks, so swapping a spinner for its outcome cannot resize the pill.
    private var mark: some View {
        ZStack {
            if lit {
                Image(systemName: "xmark")
                    .font(metrics.typography.menuIcon.weight(.semibold))
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .transition(.opacity)
            } else {
                symbol
                    .font(metrics.typography.menuIcon)
                    .transition(.opacity)
            }
        }
        .frame(width: metrics.size.menuIcon, height: metrics.size.menuIcon)
    }

    private var symbol: some View {
        ZStack {
            switch accessory {
            case .tone(let tone):
                Image(systemName: tone.hudSymbol)
                    .foregroundStyle(tone.tint)
                    .transition(.opacity)
            case .progress:
                // A `ProgressView` spinner is drawn by AppKit and ignores every tint it is given.
                Image(systemName: "progress.indicator")
                    .foregroundStyle(Theme.Colors.progress)
                    .symbolEffect(.variableColor.iterative.dimInactiveLayers.nonReversing)
                    .transition(.opacity)
            }
        }
    }
}

/// File-scoped on purpose, so nothing can reach for it when building a dialog.
extension DialogTone {
    fileprivate var hudSymbol: String {
        switch self {
        case .neutral: return "info"
        case .success: return "checkmark"
        case .danger: return "exclamationmark"
        }
    }
}
