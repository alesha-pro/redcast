import Foundation

/// Fork: a closed window keeps only its chat's id, so the transcript leaves memory with the window.
extension AIChatSurfacesState {
    /// Only an idle, saved chat with nothing staged or switched off: history gives all of it back.
    func releaseWindowTranscript(isSaved: (UUID) -> Bool) {
        let chat = window
        guard !chat.isStreaming, chat.draft.isEmpty, chat.pendingAttachments.isEmpty,
            chat.toolScope == ChatToolScope(), !chat.session.messages.isEmpty, isSaved(chat.session.id)
        else { return }
        newWindowChat()
        releasedWindowID = chat.session.id
    }

    /// Before the window's open policy, so it reopens on the chat it showed, as it always did.
    func restoreWindowTranscript(isSaved: (UUID) -> Bool) {
        guard let id = releasedWindowID else { return }
        releasedWindowID = nil
        guard window.session.messages.isEmpty, window.draft.isEmpty, window.pendingAttachments.isEmpty,
            isSaved(id)
        else { return }
        openInWindow(id: id)
    }
}
