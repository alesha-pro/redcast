import Foundation

/// A screen's row to Quick AI on ⌘J, or to a new AI Chat chat, through their own staging.
@MainActor
enum SendToAIActions {
    enum Destination {
        case quickAI
        case chat
    }

    static func payload(for source: SendToAISource) -> SendToAIPayload? {
        SendToAIPayload.make(for: source, maxNoteBytes: AIAttachmentBudget.maxInlinedTextBytes)
    }

    /// False while AI is off or the row holds nothing to send, so the chord falls through.
    @discardableResult
    static func send(_ source: SendToAISource?, to destination: Destination, core: AppCore) -> Bool {
        guard core.settings.aiEnabled, let source, let payload = payload(for: source) else { return false }
        switch destination {
        case .quickAI: toQuickAI(payload, core: core)
        case .chat: toChat(payload, core: core)
        }
        return true
    }

    /// ⌘K's two rows, in a section of their own; none while AI is off.
    static func menuItems(for source: SendToAISource?, core: AppCore) -> [PopoverMenuItem] {
        guard core.settings.aiEnabled, let source, payload(for: source) != nil else { return [] }
        return [
            PopoverMenuItem(
                title: String(localized: "Send to AI"), systemImage: CommandID.quickAI.sfSymbol,
                startsSection: true, shortcut: "⌘J"
            ) {
                send(source, to: .quickAI, core: core)
            },
            PopoverMenuItem(
                title: String(localized: "Send to AI Chat"), systemImage: CommandID.aiChat.sfSymbol
            ) {
                send(source, to: .chat, core: core)
            }
        ]
    }

    static func send(clip item: ClipboardItem?, core: AppCore) -> Bool {
        send(item.flatMap(SendToAISource.init(clip:)), to: .quickAI, core: core)
    }

    static func send(file result: FileSearchResult, core: AppCore) -> Bool {
        send(SendToAISource(file: result), to: .quickAI, core: core)
    }

    static func menuItems(clip item: ClipboardItem, core: AppCore) -> [PopoverMenuItem] {
        menuItems(for: SendToAISource(clip: item), core: core)
    }

    static func menuItems(file result: FileSearchResult, core: AppCore) -> [PopoverMenuItem] {
        menuItems(for: SendToAISource(file: result), core: core)
    }

    /// Quick AI's open policy picks the chat, as for a Screen Awareness capture.
    private static func toQuickAI(_ payload: SendToAIPayload, core: AppCore) {
        let quickAI = core.quickAICoordinator
        if payload.files.isEmpty {
            quickAI.showStaging(staged(payload.notes))
        } else {
            _ = quickAI.attachPastedFileFromLauncher(files: payload.files.map(URL.init(fileURLWithPath:)))
        }
        // The palette's query is Quick AI's composer, and opening the screen cleared it.
        guard !payload.draft.isEmpty, core.palette.mode == .ai else { return }
        let query = core.palette.query
        core.palette.query = query.isEmpty ? payload.draft : query + " " + payload.draft
    }

    /// ⌘N's new chat, so the row never lands inside a conversation already open.
    private static func toChat(_ payload: SendToAIPayload, core: AppCore) {
        let chats = core.aiChatCoordinator
        core.paletteCoordinator.hidePalette(restoreFocus: false)
        chats.newChat()
        chats.showWindow()
        let chat = core.aiChats.window
        if !payload.files.isEmpty {
            chats.attach(files: payload.files.map(URL.init(fileURLWithPath:)), to: chat)
        }
        if !payload.notes.isEmpty { chats.stage(staged(payload.notes), into: chat) }
        guard !payload.draft.isEmpty else { return }
        chat.draft = chat.draft.isEmpty ? payload.draft : chat.draft + "\n" + payload.draft
    }

    private static func staged(_ notes: [SendToAIPayload.Note]) -> [ChatAttachmentReader.Staged] {
        notes.map { note in
            ChatAttachmentReader.Staged(
                payload: .document(
                    AIDocument(
                        data: Data(note.text.utf8),
                        mimeType: AIAttachmentPolicy.mimeType(forFileName: note.name), name: note.name)),
                name: note.name, preview: nil)
        }
    }
}

extension SendToAISource {
    /// A referenced file is looked at once, on the gesture, to tell a folder from a file.
    init?(clip item: ClipboardItem) {
        switch item.kind {
        case .text:
            guard let text = item.text else { return nil }
            self = .text(text)
        case .image:
            guard let path = item.imagePath else { return nil }
            self = .image(path: path)
        case .file:
            guard let path = item.filePath else { return nil }
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            self = .file(path: path, isDirectory: exists && isDirectory.boolValue)
        }
    }

    init(file result: FileSearchResult) {
        self = .file(path: result.url.path, isDirectory: result.isDirectory)
    }

    /// A failed dictation has no text yet; an Ask goes with the question it answered.
    init?(dictation entry: DictationHistoryEntry) {
        guard !entry.isFailed else { return nil }
        self = .dictation(text: entry.text, request: entry.kind == .ask ? entry.transcript : nil)
    }
}
