import Foundation

/// Appends a run's answer to a note: through the store when it's the open note, else on disk.
@MainActor
enum AgentNoteWriter {
    /// Nil on success; otherwise a sentence for the run's row.
    static func append(_ block: String, toNoteTitled title: String, store: NotesStore) async -> String? {
        // The open note goes through its editor's store, which stays the only writer while editing.
        if store.isLoaded, let open = store.activeID,
            store.summaries.first(where: { $0.title == title })?.id == open
        {
            store.updateSource(AgentNoteEntry.appending(block, to: store.source))
            return nil
        }
        let repository = NotesRepository(notesDirectory: store.notesDirectory)
        return await Task.detached(priority: .utility) { () -> String? in
            do throws(NotesRepository.Failure) {
                let id: NoteID
                if let existing = try repository.list().first(where: { $0.title == title })?.id {
                    id = existing
                } else {
                    id = try repository.create(title: title).id
                }
                let document = try repository.load(id)
                try repository.save(id: id, source: AgentNoteEntry.appending(block, to: document.source))
                return nil
            } catch {
                return error.errorDescription
            }
        }.value
    }
}
