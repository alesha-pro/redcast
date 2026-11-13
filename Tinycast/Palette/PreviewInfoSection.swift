import AppKit
import SwiftUI

/// One fact in a preview's "Information" block; the label is already localized.
struct PreviewInfoRow: Identifiable {
    let label: String
    let value: Text
    var icon: NSImage?
    /// Makes the value a link, as the store page row is.
    var destination: URL?
    var id: String { label }

    init(_ label: String, _ value: String, icon: NSImage? = nil, destination: URL? = nil) {
        self.label = label
        self.value = Text(verbatim: value)
        self.icon = icon
        self.destination = destination
    }

    init(_ label: String, keycaps: [String]) {
        self.label = label
        value = KeyCapChip.inlineText(keycaps)
    }
}

/// The "Information" block under every split screen's preview, so each states its facts alike.
struct PreviewInfoSection: View {
    @Environment(\.metrics) private var metrics
    @Environment(\.colorSchemeContrast) private var contrast
    let rows: [PreviewInfoRow]

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.spacing.sm) {
            Text("Information")
                .font(metrics.typography.sectionHeader)
                .foregroundStyle(Theme.Colors.textSecondary)
            VStack(spacing: 0) {
                ForEach(rows) { row in
                    if row.id != rows.first?.id {
                        Rectangle()
                            .fill(contrast == .increased ? Theme.Colors.border : Theme.Colors.separator)
                            .frame(height: Theme.Size.hairline)
                    }
                    line(row)
                }
            }
        }
    }

    private func line(_ row: PreviewInfoRow) -> some View {
        HStack(spacing: metrics.spacing.sm) {
            Text(row.label).foregroundStyle(Theme.Colors.textSecondary)
            Spacer(minLength: metrics.spacing.lg)
            if let icon = row.icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: metrics.size.menuIcon, height: metrics.size.menuIcon)
            }
            value(row).lineLimit(1).truncationMode(.middle)
        }
        .font(metrics.typography.rowTrailing)
        .monospacedDigit()
        .padding(.vertical, metrics.spacing.sm)
        .accessibilityElement(children: row.destination == nil ? .combine : .contain)
    }

    @ViewBuilder
    private func value(_ row: PreviewInfoRow) -> some View {
        if let destination = row.destination {
            Link(destination: destination) { row.value }
        } else {
            row.value
        }
    }
}
