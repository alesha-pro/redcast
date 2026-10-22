import Foundation

/// The seam `ExtensionHostBridge` routes `ai.*` through; the fork's coordinator is the one host.
@MainActor
protocol ExtensionAIHost: AnyObject {
    /// `owner` is the calling bridge, so one command's streams never answer another's reads.
    func perform(
        method: String, arguments: [RenderValue], extensionName: String, openedByUser: Bool,
        owner: ObjectIdentifier
    ) async throws -> Any?
    func canAccess(extensionName: String) -> Bool
    func sessionEnded(owner: ObjectIdentifier)
}
