import AppKit
import SwiftUI

/// The whole entry: its text, what was said when that differs, and where and how it was made.
struct DictationHistoryPreview: View {
    @Environment(\.metrics) private var metrics
    let entry: DictationHistoryEntry?
    /// Whether a failed entry's recording is still on disk to retry.
    var recorded = false
    var retrying = false

    var body: some View {
        if let entry {
            VStack(alignment: .leading, spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: metrics.spacing.xl) {
                        if let failure = entry.failure {
                            failed(failure)
                        } else {
                            Text(verbatim: entry.text)
                                .font(metrics.typography.menuRow)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                        }
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

    /// Why it failed, and whether ↵ can still retry it.
    private func failed(_ failure: String) -> some View {
        VStack(alignment: .leading, spacing: metrics.spacing.sm) {
            Label("Dictation failed", systemImage: "exclamationmark.triangle")
                .font(metrics.typography.sectionHeader)
                .foregroundStyle(Theme.Colors.warning)
            Text(verbatim: failure)
                .font(metrics.typography.menuRow)
                .textSelection(.enabled)
            Group {
                if retrying {
                    HStack(spacing: metrics.spacing.sm) {
                        ProgressView().controlSize(.small)
                        Text("Retrying…")
                    }
                } else if recorded {
                    Text("The recording is kept: ↵ retries it, ⌘K chooses another model.")
                } else {
                    Text("The recording is no longer kept, so it can't be retried.")
                }
            }
            .font(metrics.typography.rowTrailing)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
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

    /// Relative day plus exact time; shared, `DateFormatter` being expensive to build.
    @MainActor private static let recordedFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    var body: some View {
        PreviewInfoSection(rows: rows)
            .padding(.top, metrics.spacing.xl)
            .padding(.bottom, metrics.spacing.md)
    }

    private var rows: [PreviewInfoRow] {
        let type = DictationHistoryList.kindName(entry.kind)
        var rows = [PreviewInfoRow(String(localized: "Type"), type)]
        if let mode = entry.mode { rows.append(PreviewInfoRow(String(localized: "Mode"), mode)) }
        if let name = entry.appName {
            rows.append(PreviewInfoRow(String(localized: "Application"), name, icon: appIcon))
        }
        if let engine = entry.engine {
            let value =
                engine == .cloud
                ? String(localized: "Cloud", comment: "Where a dictation was transcribed, beside On this Mac")
                : String(localized: "On this Mac", comment: "Where a dictation was transcribed, beside Cloud")
            rows.append(PreviewInfoRow(String(localized: "Engine"), value))
        }
        if let model = entry.model { rows.append(PreviewInfoRow(String(localized: "Model"), model)) }
        if let duration = entry.duration {
            let value = Duration.seconds(duration).formatted(
                .units(allowed: [.hours, .minutes, .seconds], width: .abbreviated))
            rows.append(PreviewInfoRow(String(localized: "Duration"), value))
        }
        rows.append(
            PreviewInfoRow(
                String(localized: "Recorded", comment: "Labels when a dictation was recorded"),
                Self.recordedFormatter.string(from: entry.date)))
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
