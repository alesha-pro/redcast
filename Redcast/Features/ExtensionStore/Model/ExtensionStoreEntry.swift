import Foundation

/// One store extension, trimmed to what the store screen shows; also the form the cache keeps.
struct ExtensionStoreEntry: Identifiable, Hashable, Sendable {
    struct Command: Hashable, Sendable {
        var title: String
        var summary: String
    }

    let id: String
    /// The manifest `name`, which is what an install is keyed by.
    let name: String
    var title: String
    var summary: String
    var author: String
    /// The owner's handle, which the store page and a lookup are addressed by, not the author's.
    var handle: String
    var lightIcon: URL?
    var darkIcon: URL?
    var commands: [Command] = []
    var categories: [String] = []
    var downloads: Int = 0
    var createdAt: Date?
    var updatedAt: Date?
    var isNew = false
    var commitSHA: String?

    /// Either side stands in for a missing other, so a one-artwork entry still draws.
    func iconURL(isDark: Bool) -> URL? {
        isDark ? (darkIcon ?? lightIcon) : (lightIcon ?? darkIcon)
    }

    /// Built from the handle and name, so a cached entry needs no URL of its own.
    var storeURL: URL? {
        guard !handle.isEmpty else { return nil }
        return URL(string: "https://www.raycast.com")?.appending(path: handle).appending(path: name)
    }
}

/// One page of any of the three store endpoints, which all list entries of the same shape.
struct ExtensionStorePage: Sendable {
    var entries: [ExtensionStoreEntry]
    /// Absent from the store listing; the catalog's first page says how many pages follow.
    var total: Int?
}

/// Someone else's undocumented endpoints: every field is optional and one bad entry skips itself.
enum ExtensionStoreWire {
    /// Throws only when the body isn't a page at all; an entry that doesn't decode is dropped.
    static func page(_ data: Data) throws -> ExtensionStorePage {
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        return ExtensionStorePage(entries: payload.data.compactMap(\.value?.entry), total: payload.total)
    }

    private struct Payload: Decodable {
        let data: [StoreLossy<WireEntry>]
        let total: Int?

        enum CodingKeys: String, CodingKey {
            case data
            case total = "total_results"
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            data = try container.decode([StoreLossy<WireEntry>].self, forKey: .data)
            total = (container.storeLossy(StoreNumber.self, .total)?.value).map { Int($0) }
        }
    }

    private struct WireEntry: Decodable {
        let entry: ExtensionStoreEntry?

        enum CodingKeys: String, CodingKey {
            case id, name, title, description, author, owner, icons, commands, categories, status
            case platforms
            case downloadCount = "download_count"
            case createdAt = "created_at"
            case updatedAt = "updated_at"
            case isNew = "is_new"
            case commitSHA = "commit_sha"
            case killListedAt = "kill_listed_at"
            case storeURL = "store_url"
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            guard let id = c.storeLossy(String.self, .id), !id.isEmpty,
                let name = c.storeLossy(String.self, .name), !name.isEmpty,
                Self.isListed(c)
            else {
                entry = nil
                return
            }
            let author = c.storeLossy(Person.self, .author)
            let owner = c.storeLossy(Person.self, .owner)
            let icons = c.storeLossy(Icons.self, .icons)
            let handle =
                owner?.handle ?? Self.handle(in: c.storeLossy(String.self, .storeURL)) ?? author?.handle ?? ""
            entry = ExtensionStoreEntry(
                id: id, name: name,
                title: Self.bounded(c.storeLossy(String.self, .title) ?? name, 200),
                summary: Self.bounded(c.storeLossy(String.self, .description) ?? "", 1_000),
                author: author?.name ?? author?.handle ?? owner?.name ?? handle,
                handle: handle,
                lightIcon: icons?.light.flatMap(Self.webURL), darkIcon: icons?.dark.flatMap(Self.webURL),
                commands: (c.storeLossy([StoreLossy<WireCommand>].self, .commands) ?? []).prefix(60)
                    .compactMap(\.value?.command),
                categories: (c.storeLossy([StoreLossy<String>].self, .categories) ?? []).compactMap(\.value)
                    .filter { !$0.isEmpty },
                downloads: max(0, Int(c.storeLossy(StoreNumber.self, .downloadCount)?.value ?? 0)),
                createdAt: Self.date(c.storeLossy(StoreNumber.self, .createdAt)),
                updatedAt: Self.date(c.storeLossy(StoreNumber.self, .updatedAt)),
                isNew: c.storeLossy(Bool.self, .isNew) ?? false,
                commitSHA: c.storeLossy(String.self, .commitSHA))
        }

        /// Only what installs on a Mac: active, not kill-listed, and macOS among its platforms.
        private static func isListed(_ c: KeyedDecodingContainer<CodingKeys>) -> Bool {
            if let status = c.storeLossy(String.self, .status), status != "active" { return false }
            if let killed = c.storeLossy(StoreNumber.self, .killListedAt)?.value, killed > 0 { return false }
            let platforms = (c.storeLossy([StoreLossy<String>].self, .platforms) ?? []).compactMap(\.value)
            // An entry listing none predates Windows support, so it is macOS-only.
            return platforms.isEmpty
                || platforms.contains { $0.caseInsensitiveCompare("macOS") == .orderedSame }
        }

        /// `https://www.raycast.com/<handle>/<name>`, the store page an entry links to.
        private static func handle(in storeURL: String?) -> String? {
            guard let url = storeURL.flatMap(URL.init(string:)), url.pathComponents.count >= 3 else {
                return nil
            }
            return url.pathComponents[1]
        }

        private static func date(_ number: StoreNumber?) -> Date? {
            guard let seconds = number?.value, seconds > 0 else { return nil }
            return Date(timeIntervalSince1970: seconds)
        }

        private static func webURL(_ text: String) -> URL? {
            guard let url = URL(string: text), url.scheme == "https" else { return nil }
            return url
        }

        static func bounded(_ text: String, _ limit: Int) -> String {
            text.count > limit ? String(text.prefix(limit)) : text
        }
    }

    private struct Person: Decodable {
        let name: String?
        let handle: String?

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = c.storeLossy(String.self, .name).flatMap { $0.isEmpty ? nil : $0 }
            handle = c.storeLossy(String.self, .handle).flatMap { $0.isEmpty ? nil : $0 }
        }

        enum CodingKeys: String, CodingKey { case name, handle }
    }

    private struct Icons: Decodable {
        let light: String?
        let dark: String?

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            light = c.storeLossy(String.self, .light)
            dark = c.storeLossy(String.self, .dark)
        }

        enum CodingKeys: String, CodingKey { case light, dark }
    }

    private struct WireCommand: Decodable {
        let command: ExtensionStoreEntry.Command?

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let title = c.storeLossy(String.self, .title) ?? c.storeLossy(String.self, .name)
            guard let title, !title.isEmpty else {
                command = nil
                return
            }
            command = ExtensionStoreEntry.Command(
                title: WireEntry.bounded(title, 120),
                summary: WireEntry.bounded(c.storeLossy(String.self, .description) ?? "", 300))
        }

        enum CodingKeys: String, CodingKey { case title, name, description }
    }
}

/// An element that fails to decode becomes nil instead of failing the whole array.
struct StoreLossy<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: any Decoder) throws {
        value = try? Value(from: decoder)
    }
}

/// A number however the endpoint spells it: an integer, a fraction or a numeric string.
struct StoreNumber: Decodable {
    let value: Double?

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Double.self) {
            value = number
        } else if let text = try? container.decode(String.self) {
            value = Double(text)
        } else {
            value = nil
        }
    }
}

extension KeyedDecodingContainer {
    /// Absent, null and the wrong type all read as nil.
    func storeLossy<Value: Decodable>(_ type: Value.Type, _ key: Key) -> Value? {
        try? decodeIfPresent(type, forKey: key)
    }
}
