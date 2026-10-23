import SwiftUI

struct AgentSessionsList: View {
    @Environment(\.metrics) private var metrics
    let rows: [AgentSessionsScreen.Row]
    let selectedID: String?
    let scroll: ScrollIntent
    let index: AgentSessionIndex
    let query: String
    let onSelect: (AgentSessionsScreen.Row) -> Void
    let onActivate: (AgentSessionsScreen.Row) -> Void
    let onActions: (AgentSessionsScreen.Row) -> Void

    private enum Item: Identifiable {
        case header(String)
        case note(String)
        case row(AgentSessionsScreen.Row)

        var id: String {
            switch self {
            case .header(let title): "header-" + title
            case .note(let text): "note-" + text
            case .row(let row): row.id
            }
        }
    }

    /// Live, then date buckets, for the full list; a ranked or found list reads in its own order.
    private var items: [Item] {
        var items: [Item] = []
        if case .loading(let source, let done, let total) = index.phase, total > 0, done < total {
            items.append(.note(String(localized: "Reading \(source.productName) sessions… \(done) of \(total)")))
        }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if let search = index.transcriptSearch, search.query == trimmed {
            items.append(.header(String(localized: "Found in Transcripts")))
            if !search.isFinished {
                items.append(.note(String(localized: "Searching transcripts… \(search.done) of \(search.total)")))
            }
            items += rows.map(Item.row)
        } else if trimmed.isEmpty {
            var bucket: DateBucket?
            var inLive = false
            for row in rows {
                guard case .session(let session) = row else { continue }
                if index.live[session.id]?.status.isLive == true {
                    if !inLive { items.append(.header(String(localized: "Live"))) }
                    inLive = true
                } else {
                    let current = DateBucket(for: session.updatedAt)
                    if current != bucket || inLive { items.append(.header(current.title)) }
                    bucket = current
                    inLive = false
                }
                items.append(.row(row))
            }
        } else {
            items += rows.map(Item.row)
        }
        if !index.unreadable.isEmpty { items.append(.note(Self.unreadableText(index.unreadable))) }
        return items
    }

    private var firstRowSelected: Bool {
        selectedID != nil && selectedID == rows.first?.id
    }

    var body: some View {
        let items = items
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(items) { item in
                        switch item {
                        case .header(let title):
                            SectionHeader(title: title, isFirst: item.id == items.first?.id)
                        case .note(let text):
                            Text(text)
                                .font(metrics.typography.keyCap)
                                .foregroundStyle(Theme.Colors.textTertiary)
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, metrics.spacing.md)
                                .padding(.vertical, metrics.spacing.sm)
                        case .row(let row):
                            rowView(row)
                        }
                    }
                }
                .padding(.horizontal, metrics.spacing.md)
                .padding(.top, metrics.spacing.xs)
                .padding(.bottom, metrics.spacing.md)
                .hideNativeScrollers()
                .scrollOriginAnchor()
            }
            .edgeDissolve()
            .thinScrollbar()
            .scrollFollowsSelection(scroll, row: selectedID, atOrigin: firstRowSelected, proxy: proxy)
        }
    }

    private func rowView(_ row: AgentSessionsScreen.Row) -> some View {
        AgentSessionRow(
            row: row, live: liveEntry(row), selected: row.id == selectedID)
            .selectionFrame(row.id == selectedID)
            .contentShape(Rectangle())
            .onTapGesture { onSelect(row) }
            .simultaneousGesture(TapGesture(count: 2).onEnded { onActivate(row) })
            .onRightClick { onActions(row) }
    }

    private func liveEntry(_ row: AgentSessionsScreen.Row) -> AgentLiveEntry? {
        guard case .session(let session) = row else { return nil }
        return index.live[session.id]
    }

    static func unreadableText(_ sources: Set<AgentSource>) -> String {
        AgentSource.allCases.filter(sources.contains)
            .map { String(localized: "\($0.productName) history could not be read") }
            .joined(separator: " ")
    }

    static func title(of session: AgentSession) -> String {
        session.title.isEmpty ? String(localized: "Untitled session") : session.title
    }

    /// A status as one short word: the chip in a row and in the menu-bar list.
    static func chipTitle(_ status: AgentLiveStatus) -> String {
        switch status {
        case .working: String(localized: "Working")
        case .waiting: String(localized: "Needs you")
        case .finished: String(localized: "Done")
        case .failed: String(localized: "Error")
        case .idle: String(localized: "Open")
        case .ended: ""
        }
    }

    static func chipColor(_ status: AgentLiveStatus) -> Color {
        switch status {
        case .waiting: Theme.Colors.warning
        case .failed: Theme.Colors.destructive
        case .finished: Theme.Colors.success
        default: Theme.Colors.textSecondary
        }
    }
}

private struct AgentSessionRow: View {
    @Environment(\.metrics) private var metrics
    let row: AgentSessionsScreen.Row
    let live: AgentLiveEntry?
    let selected: Bool
    @State private var hovered = false

    private var fill: Color {
        if selected { return Theme.Colors.selection }
        if hovered { return Theme.Colors.rowHover }
        return .clear
    }

    var body: some View {
        IconCache.observeStyle()
        return HStack(spacing: metrics.spacing.lg) {
            Image(nsImage: IconCache.symbolIcon(named: icon, tint: tint)).resizable()
                .frame(width: metrics.size.resultRowIcon, height: metrics.size.resultRowIcon)
            VStack(alignment: .leading, spacing: metrics.spacing.xxs) {
                HStack(spacing: metrics.spacing.xs) {
                    Text(verbatim: title)
                        .font(metrics.typography.rowTitle)
                        .lineLimit(1)
                    if case .session(let session) = row, session.isAutomated {
                        SymbolImage(name: "gearshape", size: metrics.size.resultRowIcon * 0.5, monochrome: true)
                            .foregroundStyle(Theme.Colors.textTertiary)
                            .accessibilityLabel(Text("Automated run"))
                    }
                }
                if let subtitle {
                    Text(verbatim: subtitle)
                        .font(metrics.typography.keyCap)
                        .foregroundStyle(Theme.Colors.textTertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            trailing
        }
        .padding(.horizontal, metrics.spacing.md)
        .padding(.vertical, metrics.spacing.sm)
        .background(RoundedRectangle(cornerRadius: metrics.radius.row, style: .continuous).fill(fill))
        .armedHover($hovered)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private var icon: String {
        switch row {
        case .searchTranscripts: "magnifyingglass"
        case .session(let session): session.source.tileSymbol
        }
    }

    /// The source's own colour, and search's blue, while Colourful Icons is on.
    private var tint: SymbolTint? {
        guard ColorfulIcons.isEnabled else { return nil }
        switch row {
        case .searchTranscripts: return GlyphCategory.files.hue.symbolTint
        case .session(let session): return session.source.hue.symbolTint
        }
    }

    private var title: String {
        switch row {
        case .searchTranscripts(let query): String(localized: "Search inside transcripts for “\(query)”")
        case .session(let session): AgentSessionsList.title(of: session)
        }
    }

    private var subtitle: String? {
        guard case .session(let session) = row else { return nil }
        let lead = session.agentName ?? session.folderName
        guard session.agentName != nil || AgentSessionsCoordinator.folderExists(session.directory) else {
            return String(localized: "Folder no longer exists")
        }
        let parts = [lead, session.firstPrompt.isEmpty ? nil : session.firstPrompt].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    @ViewBuilder private var trailing: some View {
        if let status = live?.status, status.isLive {
            Text(AgentSessionsList.chipTitle(status))
                .font(metrics.typography.keyCap)
                .foregroundStyle(AgentSessionsList.chipColor(status))
                .padding(.horizontal, metrics.spacing.sm)
                .padding(.vertical, metrics.spacing.xxs)
                .background(Capsule().fill(Theme.Colors.controlSurface))
        } else if case .session(let session) = row {
            Text(verbatim: Self.time(session.updatedAt))
                .font(metrics.typography.keyCap)
                .foregroundStyle(Theme.Colors.textTertiary)
        }
    }

    private static func time(_ date: Date) -> String {
        Calendar.current.isDateInToday(date)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.month(.abbreviated).day())
    }
}
