import SwiftUI

/// The volume box: glyph, bar, number, on the HUD's tinted glass.
struct VolumeHUDView: View {
    let state: VolumeState
    @Environment(\.metrics) private var metrics

    var body: some View {
        let geometry = VolumeHUDGeometry(metrics: metrics)
        VStack(spacing: geometry.rowSpacing) {
            SymbolImage(
                name: VolumeLevel.symbol(level: state.level, muted: state.muted),
                size: geometry.glyph
            )
            .foregroundStyle(Color.primary)
            HStack(spacing: geometry.readoutSpacing) {
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Theme.Colors.controlSurface)
                    Capsule()
                        .fill(Theme.Colors.textPrimary.opacity(state.muted ? 0.35 : 0.85))
                        .frame(width: geometry.trackWidth * fill)
                }
                .frame(width: geometry.trackWidth, height: geometry.trackHeight)
                // Muted prints the word: the bar is empty, and a number would contradict it.
                Text(
                    state.muted
                        ? String(localized: "Muted") : VolumeLevel.percentage(state.level, locale: .current)
                )
                .font(metrics.typography.rowTrailing)
                .foregroundStyle(Theme.Colors.textSecondary)
                .monospacedDigit()
                .contentTransition(.numericText(value: state.level))
                .frame(width: geometry.readoutWidth, alignment: .trailing)
            }
        }
        .padding(.vertical, geometry.verticalInset)
        .padding(.horizontal, geometry.horizontalInset)
        .frame(width: geometry.size.width, height: geometry.size.height)
        .glassSurface(
            .hud, in: RoundedRectangle(cornerRadius: geometry.cornerRadius, style: .continuous)
        )
        .panelEntrance()
        // A repeat command slides the bar to its new value instead of cutting to it.
        .animation(.easeOut(duration: Theme.Duration.exit), value: state.level)
        .animation(.easeOut(duration: Theme.Duration.exit), value: state.muted)
    }

    private var fill: CGFloat {
        state.muted ? 0 : VolumeLevel.clamped(state.level)
    }
}
