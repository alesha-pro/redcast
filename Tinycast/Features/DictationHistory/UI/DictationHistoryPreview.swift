import AppKit
import SwiftUI

/// The whole entry: its text, what was said when that differs, and where and how it was made.
struct DictationHistoryPreview: View {
    @Environment(\.metrics) private var metrics
    let entry: DictationHistoryEntry?

    var body: some View {
        if let entry {
            VStack(alignment: .leading, spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: metrics.spacing.xl) {
                        Text(verbatim: entry.text)
                            .font(metrics.typography.menuRow)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                        if let transcript = entry.transcript {
                            VStack(alignment: .leading, spacing: metrics.spacing.xs) {
                                transcriptHeading(entry.kind)
                                    .font(metrics.typography.sectionHeader)
                                    .foregroundStyle(.secondary)
                                Text(verbatim: transcript)
                                    .font(metrics.typography.menuRow)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .topLeading)
                            }
                        }
                    }
                    .padding(.vertical, metrics.spacing.md)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                DictationHistoryInformation(entry: entry)
            }
            .padding(.horizontal, metrics.spacing.xl)
        } else {
            Color.clear
        }
    }

    /// What was said before a mode rewrote it, or the question or instruction an Ask or edit heard.
    private func transcriptHeading(_ kind: DictationHistoryEntry.Kind) -> Text {
        kind == .dictation
            ? Text("Raw transcript", comment: "A dictation's text before its mode rewrote it")
            : Text("Request", comment: "What was said to Ask by Voice or Edit Selection by Voice")
    }
}

/// The "Information" block, laid out as Clipboard History's is.
private struct DictationHistoryInformation: View {
    @Environment(\.metrics) private var metrics
    let entry: DictationHistoryEntry

    private struct InfoRow: Identifiable {
        let label: String
        let value: String
        var icon: NSImage?
        var id: String { label }
    }

    /// Relative day plus exact time; shared, `DateFormatter` being expensive to build.
    @MainActor private static let recordedFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

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
                        if let icon = row.icon {
                            Image(nsImage: icon)
                                .resizable()
                                .frame(width: metrics.size.menuIcon, height: metrics.size.menuIcon)
                        }
                        Text(verbatim: row.value).lineLimit(1).truncationMode(.middle)
                    }
                    .font(.callout)
                    .padding(.vertical, metrics.spacing.sm)
                }
            }
        }
        .padding(.top, metrics.spacing.xl)
        .padding(.bottom, metrics.spacing.md)
    }

    private var rows: [InfoRow] {
        let type = DictationHistoryList.kindName(entry.kind)
        var rows = [InfoRow(label: String(localized: "Type"), value: type)]
        if let mode = entry.mode { rows.append(InfoRow(label: String(localized: "Mode"), value: mode)) }
        if let name = entry.appName {
            rows.append(InfoRow(label: String(localized: "Application"), value: name, icon: appIcon))
        }
        if let engine = entry.engine {
            let value =
                engine == .cloud
                ? String(localized: "Cloud", comment: "Where a dictation was transcribed, beside On this Mac")
                : String(localized: "On this Mac", comment: "Where a dictation was transcribed, beside Cloud")
            rows.append(InfoRow(label: String(localized: "Engine"), value: value))
        }
        if let model = entry.model { rows.append(InfoRow(label: String(localized: "Model"), value: model)) }
        if let duration = entry.duration {
            let value = Duration.seconds(duration).formatted(
                .units(allowed: [.hours, .minutes, .seconds], width: .abbreviated))
            rows.append(InfoRow(label: String(localized: "Duration"), value: value))
        }
        rows.append(
            InfoRow(
                label: String(localized: "Recorded", comment: "Labels when a dictation was recorded"),
                value: Self.recordedFormatter.string(from: entry.date)))
        return rows
    }

    private var appIcon: NSImage? {
        IconCache.observeStyle()
        guard let bundleID = entry.bundleID,
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return nil }
        return IconCache.icon(forFile: url.path)
    }
}
