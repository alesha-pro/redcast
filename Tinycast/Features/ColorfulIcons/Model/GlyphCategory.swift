import Foundation

/// What a built-in glyph belongs to; every glyph in a family wears that family's hue.
enum GlyphCategory: CaseIterable, Sendable {
    case ai, voice, clipboard, snippets, notes, calendar, emoji, calculator, files, web, windows
    case quicklinks, scripts, system, camera
    /// Tinycast's own housekeeping: Settings, backups, updates, About, Quit.
    case app

    /// Raycast's families: AI red, clipboard orange, dictation blue, quicklinks purple.
    var hue: RaycastHue {
        switch self {
        case .ai: .red
        case .clipboard, .snippets, .calculator: .orange
        case .notes, .calendar, .emoji: .yellow
        case .system, .camera: .green
        case .files, .web, .voice: .blue
        case .windows, .quicklinks: .purple
        case .scripts, .app: .gray
        }
    }

    /// Nil for a command upstream added since; it keeps the grey glyph until it is given a family.
    static func of(_ command: CommandID) -> GlyphCategory? { commandFamilies[command] }

    private static let commandFamilies: [CommandID: GlyphCategory] = {
        let families: [GlyphCategory: [CommandID]] = [
            .ai: [
                .quickAI, .aiChat, .askAboutScreen, .runAgentTask, .searchAgentSessions, .jumpToAgent,
                .aiUsage, .fixGrammar, .rewrite, .translate, .summarize
            ],
            .voice: [.askByVoice, .editByVoice],
            .clipboard: [.clipboardHistory, .pasteSequentially],
            .snippets: [.searchSnippets, .createSnippet],
            .notes: [.showNotes, .createNote, .searchNotes],
            .calendar: [.joinNextMeeting, .mySchedule, .createEvent, .copyMeetingLink, .openInCalendar],
            .emoji: [.searchEmoji],
            .calculator: [.calculatorHistory],
            .files: [.searchFiles, .searchMenuItems, .define],
            .web: [.openInBrowser],
            .windows: [
                .switchWindows, .switchWindowsBackwards, .createWindowLayout, .captureWindowLayout,
                .switchRoom, .createRoom
            ],
            .quicklinks: [.createQuicklink, .searchQuicklinks, .importQuicklinks, .exportQuicklinks],
            .scripts: [.runShellCommand, .createCustomCommand, .searchCustomCommands],
            .camera: [.openCamera],
            .app: [
                .exportSettings, .importSettings, .importFromRaycast, .checkForUpdates, .settings, .about,
                .support, .quit
            ]
        ]
        return Dictionary(
            uniqueKeysWithValues: families.flatMap { family, commands in commands.map { ($0, family) } })
    }()

    /// A ⌘K row's glyph says what the row does, so its meaning picks the hue; nil stays neutral.
    static func menuHue(forSymbol name: String) -> RaycastHue? { menuHues[name] }

    /// No red: in a menu it stays the destructive rows' alone, and AI rows read neutral.
    private static let menuHues: [String: RaycastHue] = {
        let families: [RaycastHue: [String]] = [
            .orange: [
                "doc.on.doc", "doc.on.doc.fill", "doc.on.clipboard", "list.bullet.clipboard",
                "text.quote", "paperclip"
            ],
            .yellow: [
                "star", "star.slash", "star.fill", "pin", "pin.slash", "note.text", "calendar",
                "calendar.day.timeline.left", "clock"
            ],
            .green: [
                "list.dash.header.rectangle", "list.bullet.rectangle", "arrow.up.forward.app",
                "arrow.clockwise", "play.circle", "video.fill"
            ],
            .blue: [
                "folder", "doc", "magnifyingglass", "doc.text.magnifyingglass", "doc.text.viewfinder",
                "globe", "network", "externaldrive"
            ],
            .purple: [
                "pencil", "character.cursor.ibeam", "text.cursor", "command", "keyboard",
                "slider.horizontal.3", "macwindow", "macwindow.badge.plus", "rectangle.3.group", "link"
            ]
        ]
        return Dictionary(
            uniqueKeysWithValues: families.flatMap { hue, names in names.map { ($0, hue) } })
    }()
}
