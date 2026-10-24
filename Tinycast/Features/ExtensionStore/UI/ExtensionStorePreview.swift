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
                    .font(.caption)
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
                        .font(.title3.weight(.semibold))
                        .lineLimit(2)
                    if !entry.author.isEmpty {
                        Text(verbatim: entry.author)
                            .font(.callout)
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
            .font(.callout)
            .foregroundStyle(.secondary)
        } else if let failure {
            Label(failure, systemImage: "exclamationmark.triangle")
                .font(.callout)
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
                .font(.title3.weight(.semibold))
            Text("\(count) extensions")
                .font(.callout)
                .foregroundStyle(.secondary)
            if !top.isEmpty {
                Text(verbatim: top.joined(separator: " · "))
                    .font(metrics.typography.menuRow)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Press ↵ to list them all; Escape comes back here.")
                .font(.callout)
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
                .foregroundStyle(.secondary)
            ForEach(Array(commands.enumerated()), id: \.offset) { _, command in
                VStack(alignment: .leading, spacing: metrics.spacing.xxs) {
                    Text(verbatim: command.title)
                        .font(.callout.weight(.medium))
                    if !command.summary.isEmpty {
                        Text(verbatim: command.summary)
                            .font(.caption)
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

    private struct InfoRow: Identifiable {
        let label: String
        let value: String
        var id: String { label }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.spacing.sm) {
            Text("Information")
                .font(metrics.typography.sectionHeader)
                .foregroundStyle(.secondary)
            VStack(spacing: 0) {
                let rows = self.rows
                ForEach(rows) { row in
                    if row.id != rows.first?.id { Divider() }
                    HStack(spacing: metrics.spacing.sm) {
                        Text(row.label).foregroundStyle(.secondary)
                        Spacer(minLength: metrics.spacing.lg)
                        Text(verbatim: row.value).lineLimit(1).truncationMode(.middle)
                    }
                    .font(.callout)
                    .padding(.vertical, metrics.spacing.sm)
                }
                if let url = entry.storeURL {
                    Divider()
                    HStack(spacing: metrics.spacing.sm) {
                        Text("Store page").foregroundStyle(.secondary)
                        Spacer(minLength: metrics.spacing.lg)
                        Link(destination: url) {
                            Text(verbatim: url.host().map { $0 + url.path() } ?? url.absoluteString)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .font(.callout)
                    .padding(.vertical, metrics.spacing.sm)
                }
            }
        }
        .padding(.top, metrics.spacing.md)
    }

    private var rows: [InfoRow] {
        var rows: [InfoRow] = []
        if !entry.author.isEmpty {
            rows.append(InfoRow(label: String(localized: "Author"), value: entry.author))
        }
        rows.append(InfoRow(label: String(localized: "Downloads"), value: entry.downloads.formatted()))
        if !entry.categories.isEmpty {
            rows.append(
                InfoRow(
                    label: String(localized: "Categories"), value: entry.categories.joined(separator: ", ")))
        }
        if let created = entry.createdAt {
            rows.append(
                InfoRow(
                    label: String(
                        localized: "Published", comment: "When an extension first reached the store"),
                    value: created.formatted(date: .abbreviated, time: .omitted)))
        }
        if let updated = entry.updatedAt {
            rows.append(
                InfoRow(
                    label: String(
                        localized: "Updated", comment: "When an extension last changed in the store"),
                    value: updated.formatted(date: .abbreviated, time: .omitted)))
        }
        return rows
    }
}
