import CoreGraphics

/// Fork: the volume box at one Interface Size, read by its window and its view so they agree.
struct VolumeHUDGeometry: Equatable, Sendable {
    let metrics: InterfaceMetrics

    var size: CGSize { CGSize(width: metrics.size.hudWidth, height: metrics.size.hudHeight) }
    var cornerRadius: CGFloat { metrics.radius.dialog }
    var glyph: CGFloat { metrics.size.dialogIcon }
    var rowSpacing: CGFloat { metrics.spacing.lg }
    var readoutSpacing: CGFloat { metrics.spacing.md }
    /// Asymmetric: side padding costs far more on a 200pt box than a 420pt dialog.
    var verticalInset: CGFloat { metrics.spacing.xxl }
    var horizontalInset: CGFloat { metrics.spacing.xl }
    var trackHeight: CGFloat { metrics.size.volumeTrackHeight }
    var readoutWidth: CGFloat { metrics.size.volumeReadout }
    /// What the bar is left once both insets and the readout's fixed slot are taken.
    var trackWidth: CGFloat { size.width - horizontalInset * 2 - readoutSpacing - readoutWidth }
}
