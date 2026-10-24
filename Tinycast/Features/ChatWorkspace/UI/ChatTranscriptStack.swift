import SwiftUI

/// Fork: the window's transcript builds only the messages near its viewport; Quick AI's is eager.
struct ChatTranscriptStack<Content: View>: View {
    let isLazy: Bool
    let spacing: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        if isLazy {
            LazyVStack(spacing: spacing) { content }
        } else {
            VStack(spacing: spacing) { content }
        }
    }
}

/// Fork: find scrolls to the match's message first, so its text exists before its anchor is asked.
@MainActor
enum ChatTranscriptReveal {
    static func message(_ id: UUID?, in proxy: ScrollViewProxy, if isLazy: Bool) async {
        guard isLazy, let id else { return }
        proxy.scrollTo(id, anchor: .center)
        try? await Task.sleep(for: .milliseconds(60))
    }
}
