import Foundation
import Observation
import OSLog

/// Fork: the workspace document on disk, read with the chat history and written on every change.
@MainActor
@Observable
final class ChatWorkspaceStore {
    private(set) var workspace = ChatWorkspace()
    @ObservationIgnored let fileURL: URL
    private static let log = Logger(subsystem: "com.tinycast", category: "ChatWorkspace")
    @ObservationIgnored private var isLoaded = false

    init(directory: URL) {
        fileURL = directory.appendingPathComponent("ai-chat-workspace.json")
    }

    /// A missing or unreadable file is an empty workspace; it is written only once something changes.
    func load() {
        guard !isLoaded else { return }
        isLoaded = true
        workspace = (try? Data(contentsOf: fileURL)).map(ChatWorkspace.init(data:)) ?? ChatWorkspace()
    }

    /// AI off: the document leaves memory, the file stays.
    func close() {
        isLoaded = false
        workspace = ChatWorkspace()
    }

    func change(_ edit: (inout ChatWorkspace) -> Void) {
        load()
        var next = workspace
        edit(&next)
        guard next != workspace else { return }
        workspace = next
        save()
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try workspace.data.write(to: fileURL, options: .atomic)
        } catch {
            Self.log.error("chat workspace not saved: \(error.localizedDescription, privacy: .public)")
        }
    }
}
