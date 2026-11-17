import SwiftUI

/// The extension's search-bar dropdown, drawn as a header control. Not `HeaderMenuButton`: the
/// choice it states carries an extension's own icon, which `PopoverMenuIcon` cannot name.
struct ExtensionSearchAccessoryButton: View {
    @Environment(\.metrics) private var metrics
    /// Room for a long choice beside its icon and tick, without a form field's 360pt sprawl.
    static let listWidth: CGFloat = 240

    let accessory: ExtensionSearchAccessory
    /// The choice it holds; nil only until the first commit seeds one.
    let value: String?
    let assetsPath: String?
    let isOpen: Bool
    let action: () -> Void

    /// Read from the view, so a resolved icon repaints when the surface flips appearance.
    @Environment(\.isDarkAppearance) private var isDark
    @State private var hovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: metrics.radius.barControl, style: .continuous)
        // Its own chrome, not `BarButton`: a restyle of the header's controls must not reach it.
        return Button(action: action) {
            HStack(spacing: metrics.spacing.sm) {
                if let icon {
                    ExtensionIconView(
                        resolved: icon, size: metrics.size.menuIcon, usesMenuSymbolStyle: true)
                }
                Text(accessory.title(for: value) ?? "")
                    .font(metrics.typography.bar)
                    .lineLimit(1)
                    .truncationMode(.middle)
                // The panel always drops below the header, so it never points back up flipped.
                ExtensionDisclosureChevron(open: isOpen)
            }
            .foregroundStyle(Theme.Colors.textSecondary)
            .padding(.horizontal, metrics.spacing.md)
            .frame(height: metrics.size.barButtonHeight)
            .contentShape(shape)
            .background(shape.fill(hovered ? Theme.Colors.rowHover : Color.clear))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(
            Text(
                verbatim:
                    "\(accessory.tooltip ?? accessory.placeholder ?? String(localized: "Filter"))  ⌘P"))
    }

    private var icon: ExtensionImage.Resolved? {
        ExtensionImage.resolve(
            accessory.item(for: value)?.iconValue, assetsPath: assetsPath, isDark: isDark)
    }
}
