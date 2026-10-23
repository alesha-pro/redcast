import SwiftUI

/// Over Quick AI's empty chat: the agent that will answer, where the transcript's header goes.
struct QuickAIAgentHeader: View {
    @Environment(\.metrics) private var metrics
    @Environment(\.agentChatBadge) private var badge

    var body: some View {
        if let badge {
            AgentChatHeader(badge: badge)
                .padding(.top, metrics.spacing.xl)
                .padding(.horizontal, metrics.spacing.xxl)
        }
    }
}
