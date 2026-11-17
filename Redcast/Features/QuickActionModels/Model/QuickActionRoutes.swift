import Foundation

/// Fork: the per-action routes, read entry by entry and with what a repair took away remembered.
enum QuickActionRoutes {
    /// One entry this build can't read costs only itself, never every action's route.
    static func decode(_ data: Data?) -> [String: AIModelSelection] {
        guard let data, let entries = try? JSONDecoder().decode([String: Entry].self, from: data) else {
            return [:]
        }
        return entries.compactMapValues(\.selection)
    }

    /// The overrides a repair dropped, keyed like `quickActionModelOverrides`.
    static func lapsed(
        from before: [String: AIModelSelection], to after: [String: AIModelSelection]
    ) -> [String: AIModelSelection] {
        before.filter { after[$0.key] == nil }
    }

    private struct Entry: Decodable {
        let selection: AIModelSelection?

        init(from decoder: Decoder) throws {
            selection = try? AIModelSelection(from: decoder)
        }
    }
}
