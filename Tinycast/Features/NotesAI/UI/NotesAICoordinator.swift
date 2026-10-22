import Foundation
import Observation

/// Notes for AI Chat: the composer's note picker, attaching a note, and the agents' Notes tools.
@MainActor
@Observable
final class NotesAICoordinator {
    /// The chat whose composer shows the picker; one at a time.
    private(set) var pickerChatID: UUID?
    /// Opened by a typed `@note `, which Esc puts back so a literal is never lost.
    @ObservationIgnored private(set) var restoresMention = false

    private let store: NotesStore
    private let settings: AppSettings
    private unowned let core: AppCore

    init(store: NotesStore, settings: AppSettings, core: AppCore) {
        self.store = store
        self.settings = settings
        self.core = core
    }

    var isAvailable: Bool { settings.notesEnabled }

    func presentPicker(for chat: AIChatState, fromMention: Bool = false) {
        guard isAvailable else { return }
        restoresMention = fromMention
        pickerChatID = chat.session.id
    }

    func dismissPicker() {
        pickerChatID = nil
        restoresMention = false
    }

    /// Its own repository value, so the picker never touches the Notes switcher's search state.
    func makePickerModel() -> NotePickerModel {
        NotePickerModel(repository: NotesRepository(notesDirectory: store.notesDirectory))
    }

    /// A just-typed note reaches the disk before the picker lists the folder.
    func flush() async {
        _ = await store.flush()
    }

    /// The pick rides the next message like a text file: same chip, limits and history.
    func attach(_ summary: NoteSummary, to chat: AIChatState, via chats: AIChatCoordinator) {
        let generation = chat.stagingGeneration
        let repository = NotesRepository(notesDirectory: store.notesDirectory)
        let open = store.activeID == summary.id ? store.source : nil
        Task { [weak self, weak chat] in
            let source = await Task.detached(priority: .userInitiated) {
                () -> Result<String, NotesRepository.Failure> in
                if let open { return .success(open) }
                do throws(NotesRepository.Failure) {
                    return .success(try repository.load(summary.id).source)
                } catch {
                    return .failure(error)
                }
            }.value
            guard let self, let chat else { return }
            guard generation == chat.stagingGeneration else {
                core.showMessage(
                    String(localized: "That file was still loading and did not make it into the chat."),
                    tone: .neutral)
                return
            }
            switch source {
            case .failure(.unreadable):
                core.showMessage(ChatAttachmentRefusal.undecodable.message, tone: .neutral)
            case .failure:
                core.showMessage(ChatAttachmentRefusal.unreadable.message, tone: .neutral)
            case .success(let text):
                switch NoteAttachmentPolicy.document(title: summary.displayTitle, source: text) {
                case .document(let document):
                    chats.stage(
                        [ChatAttachmentReader.Staged(
                            payload: .document(document), name: document.name, preview: nil)],
                        into: chat)
                case .tooLong:
                    core.showMessage(ChatAttachmentRefusal.textTooLong.message, tone: .neutral)
                }
            }
        }
    }

    /// Built per agent turn, so nothing of it stays resident between turns.
    var agentTools: NoteAgentTools {
        NoteAgentTools(
            repository: NotesRepository(notesDirectory: store.notesDirectory), timeZone: .current,
            isEnabled: { @MainActor [weak settings] in settings?.notesEnabled ?? false },
            writer: .through(store))
    }
}
