import Foundation

/// What a built-in glyph belongs to; every glyph in a family wears that family's hue.
enum GlyphCategory: CaseIterable, Sendable {
    case ai, voice, clipboard, snippets, notes, calendar, emoji, calculator, files, web, windows
    case quicklinks, scripts, system, camera
    /// Tinycast's own housekeeping: Settings, backups, updates, About, Quit.
    case app

    /// Raycast's families where it has one: AI red, clipboard orange, dictation blue.
    var hue: RaycastHue {
        switch self {
        case .ai: .red
        case .clipboard, .snippets, .calculator: .orange
        case .notes, .calendar, .emoji: .yellow
        case .system, .camera: .green
        case .files, .web, .voice: .blue
        case .windows: .purple
        case .quicklinks: .magenta
        case .scripts, .app: .gray
        }
    }

    /// Exhaustive, so a command upstream adds fails to build until it is given a family.
    init(_ command: CommandID) {
        switch command {
        case .quickAI, .aiChat, .askAboutScreen, .runAgentTask, .searchAgentSessions, .jumpToAgent,
            .aiUsage, .fixGrammar, .rewrite, .translate, .summarize:
            self = .ai
        case .askByVoice, .editByVoice: self = .voice
        case .clipboardHistory, .pasteSequentially: self = .clipboard
        case .searchSnippets, .createSnippet: self = .snippets
        case .showNotes, .createNote, .searchNotes: self = .notes
        case .joinNextMeeting, .mySchedule, .createEvent, .copyMeetingLink, .openInCalendar:
            self = .calendar
        case .searchEmoji: self = .emoji
        case .calculatorHistory: self = .calculator
        case .searchFiles, .searchMenuItems, .define: self = .files
        case .openInBrowser: self = .web
        case .switchWindows, .switchWindowsBackwards, .createWindowLayout, .captureWindowLayout,
            .switchRoom, .createRoom:
            self = .windows
        case .createQuicklink, .searchQuicklinks, .importQuicklinks, .exportQuicklinks:
            self = .quicklinks
        case .runShellCommand, .createCustomCommand, .searchCustomCommands: self = .scripts
        case .openCamera: self = .camera
        case .exportSettings, .importSettings, .importFromRaycast, .checkForUpdates, .settings, .about,
            .support, .quit:
            self = .app
        }
    }

    /// A ⌘K row's glyph says what the row does, so its meaning picks the hue; nil stays neutral.
    static func menuHue(forSymbol name: String) -> RaycastHue? { menuHues[name] }

    private static let menuHues: [String: RaycastHue] = {
        let families: [RaycastHue: [String]] = [
            .red: [
                "sparkles", "wand.and.sparkles", "wand.and.stars", "brain", "bubble.left",
                "bubble.left.and.bubble.right", "plus.bubble", "person.crop.circle",
                "person.crop.circle.badge.clock"
            ],
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
                "slider.horizontal.3", "macwindow", "macwindow.badge.plus", "rectangle.3.group"
            ],
            .magenta: ["link"]
        ]
        return Dictionary(
            uniqueKeysWithValues: families.flatMap { hue, names in names.map { ($0, hue) } })
    }()
}
