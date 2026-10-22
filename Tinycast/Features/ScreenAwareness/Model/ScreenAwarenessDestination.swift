import Foundation

/// Where a capture opens: AI Chat, as Raycast does, or Quick AI to keep it in the palette.
enum ScreenAwarenessDestination: String, CaseIterable, Identifiable, Sendable {
    case aiChat
    case quickAI

    var id: String { rawValue }
}
