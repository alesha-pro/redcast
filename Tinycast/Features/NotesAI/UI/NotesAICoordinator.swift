import Foundation
import Observation

/// Notes for AI: the agents' Notes tools.
@MainActor
@Observable
final class NotesAICoordinator {
    private let store: NotesStore
    private let settings: AppSettings
    private unowned let core: AppCore

    init(store: NotesStore, settings: AppSettings, core: AppCore) {
        self.store = store
        self.settings = settings
        self.core = core
    }

    /// Built per agent turn, so nothing of it stays resident between turns.
    var agentTools: NoteAgentTools {
        NoteAgentTools(
            repository: NotesRepository(notesDirectory: store.notesDirectory), timeZone: .current,
            isEnabled: { @MainActor [weak settings] in settings?.notesEnabled ?? false },
            writer: .through(store))
    }
}
