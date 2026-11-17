import AppKit
import SwiftUI

/// The selected extension in full, or what a list row opens.
struct ExtensionStorePreview: View {
    @Environment(\.metrics) private var metrics
    let row: ExtensionStoreRow?
    /// What a list row's preview names; the index sorts each list once.
    let leadingTitles: (ExtensionStoreBrowse) -> [String]
    let installed: ExtensionStoreInstallState.Installed
    let installing: String?
    let failure: String?
    let refreshFailure: String?

    /// Larger than a row's icon: here the artwork is how an extension is recognised.
    private static let iconSide: CGFloat = 48

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch row?.item {
            case .entry(let entry)?:
                ScrollView {
                    details(entry)
                        .padding(.vertical, metrics.spacing.md)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            case .browse(let browse, let count)?:
                browsing(browse, count: count)
            case nil:
                Color.clear
            }
            if let refreshFailure {
                Label(refreshFailure, systemImage: "exclamationmark.triangle")
                    .font(metrics.typography.keyCap)
                    .foregroundStyle(Theme.Colors.warning)
                    .padding(.bottom, metrics.spacing.md)
            }
        }
        .padding(.horizontal, metrics.spacing.xl)
    }

    private func details(_ entry: ExtensionStoreEntry) -> some View {
        VStack(alignment: .leading, spacing: metrics.spacing.xl) {
            HStack(alignment: .center, spacing: metrics.spacing.lg) {
                ExtensionStoreIcon(entry: entry, side: Self.iconSide)
                VStack(alignment: .leading, spacing: metrics.spacing.xxs) {
                    Text(verbatim: entry.title)
                        .font(metrics.typography.previewTitle)
                        .lineLimit(2)
                    if !entry.author.isEmpty {
                        Text(verbatim: entry.author)
                            .font(metrics.typography.rowTrailing)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                ExtensionStoreBadge(state: ExtensionStoreInstallState.of(entry, in: installed))
            }
            status
            if !entry.summary.isEmpty {
                Text(verbatim: entry.summary)
                    .font(metrics.typography.menuRow)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            if !entry.commands.isEmpty {
                ExtensionStoreCommands(commands: entry.commands)
            }
            ExtensionStoreInformation(entry: entry)
        }
    }

    @ViewBuilder private var status: some View {
        if let installing {
            HStack(spacing: metrics.spacing.sm) {
                ProgressView().controlSize(.small)
                Text(verbatim: installing)
            }
            .font(metrics.typography.rowTrailing)
            .foregroundStyle(.secondary)
        } else if let failure {
            Label(failure, systemImage: "exclamationmark.triangle")
                .font(metrics.typography.rowTrailing)
                .foregroundStyle(Theme.Colors.warning)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// A list row says what ↵ will show, and a category its biggest names.
    private func browsing(_ browse: ExtensionStoreBrowse, count: Int) -> some View {
        let top = leadingTitles(browse)
        return VStack(alignment: .leading, spacing: metrics.spacing.md) {
            Text(verbatim: browse.title)
                .font(metrics.typography.previewTitle)
            Text("\(count) extensions")
                .font(metrics.typography.rowTrailing)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            if !top.isEmpty {
                Text(verbatim: top.joined(separator: " · "))
                    .font(metrics.typography.menuRow)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Press ↵ to list them all; Escape comes back here.")
                .font(metrics.typography.rowTrailing)
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
        }
        .padding(.vertical, metrics.spacing.md)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

private struct ExtensionStoreCommands: View {
    @Environment(\.metrics) private var metrics
    let commands: [ExtensionStoreEntry.Command]

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.spacing.sm) {
            Text("Commands")
                .font(metrics.typography.sectionHeader)
                .foregroundStyle(Theme.Colors.textSecondary)
            ForEach(Array(commands.enumerated()), id: \.offset) { _, command in
                VStack(alignment: .leading, spacing: metrics.spacing.xxs) {
                    Text(verbatim: command.title)
                        .font(metrics.typography.rowTrailing.weight(.medium))
                    if !command.summary.isEmpty {
                        Text(verbatim: command.summary)
                            .font(metrics.typography.keyCap)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The "Information" block, laid out as Clipboard History's is.
private struct ExtensionStoreInformation: View {
    @Environment(\.metrics) private var metrics
    let entry: ExtensionStoreEntry

    var body: some View {
        PreviewInfoSection(rows: rows)
            .padding(.top, metrics.spacing.md)
    }

    private var rows: [PreviewInfoRow] {
        var rows: [PreviewInfoRow] = []
        if !entry.author.isEmpty {
            rows.append(PreviewInfoRow(String(localized: "Author"), entry.author))
        }
        rows.append(PreviewInfoRow(String(localized: "Downloads"), entry.downloads.formatted()))
        if !entry.categories.isEmpty {
            rows.append(
                PreviewInfoRow(String(localized: "Categories"), entry.categories.joined(separator: ", ")))
        }
        if let created = entry.createdAt {
            rows.append(
                PreviewInfoRow(
                    String(localized: "Published", comment: "When an extension first reached the store"),
                    created.formatted(date: .abbreviated, time: .omitted)))
        }
        if let updated = entry.updatedAt {
            rows.append(
                PreviewInfoRow(
                    String(localized: "Updated", comment: "When an extension last changed in the store"),
                    updated.formatted(date: .abbreviated, time: .omitted)))
        }
        if let url = entry.storeURL {
            rows.append(
                PreviewInfoRow(
                    String(localized: "Store page"), url.host().map { $0 + url.path() } ?? url.absoluteString,
                    destination: url))
        }
        return rows
    }
}
