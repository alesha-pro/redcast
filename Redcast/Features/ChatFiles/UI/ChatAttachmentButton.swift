import AppKit
import SwiftUI

/// A click or Space previews a sent attachment, a right click offers what a Files chip does.
struct ChatAttachmentButton<Label: View>: View {
    let attachment: ChatAttachmentFile
    @ViewBuilder let label: Label
    @State private var opening: Task<Void, Never>?

    var body: some View {
        Button {
            open(with: ChatFileActions.quickLook)
        } label: {
            label.contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onKeyPress(.space) {
            open(with: ChatFileActions.quickLook)
            return .handled
        }
        .onRightClick { open(with: ChatFileActions.popUpMenu) }
        .onDisappear { opening?.cancel() }
    }

    /// Its bytes never leave the message until asked for, and never decode here at all.
    private func open(with action: @escaping @MainActor (String) -> Void) {
        opening?.cancel()
        opening = Task {
            guard let file = await ChatAttachmentFiles.write(attachment) else {
                NSSound.beep()
                return
            }
            guard !Task.isCancelled else { return }
            action(file.path)
        }
    }
}
