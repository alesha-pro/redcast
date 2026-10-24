import Foundation

/// Fetches the store's listings; only ever asked while the store screen is open.
struct ExtensionStoreFetcher: Sendable {
    /// Cacheless, never `URLSession.shared`, so the trimmed cache stays the only copy on disk.
    private static let defaultSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    /// Enough to fetch the catalog in a few seconds without opening twenty connections at once.
    static let parallelPages = 4

    private let session: URLSession

    init(session: URLSession = ExtensionStoreFetcher.defaultSession) {
        self.session = session
    }

    /// The catalog, page by page; incomplete when a later page failed, thrown when the first did.
    func catalog() async throws -> (entries: [ExtensionStoreEntry], isComplete: Bool) {
        let first = try await page(ExtensionStoreEndpoint.catalog(page: 1))
        let remaining = ExtensionStoreEndpoint.remainingCatalogPages(total: first.total)
        guard remaining > 0 else { return (first.entries, true) }
        var pages: [Int: [ExtensionStoreEntry]] = [:]
        var failed = false
        await withTaskGroup(of: (Int, [ExtensionStoreEntry]?).self) { group in
            var next = 2
            func enqueue() {
                guard next <= remaining + 1 else { return }
                let number = next
                next += 1
                group.addTask {
                    (number, try? await page(ExtensionStoreEndpoint.catalog(page: number)).entries)
                }
            }
            for _ in 0..<Self.parallelPages { enqueue() }
            for await (number, entries) in group {
                if let entries { pages[number] = entries } else { failed = true }
                enqueue()
            }
        }
        try Task.checkCancellation()
        let rest = pages.keys.sorted().flatMap { pages[$0] ?? [] }
        return (first.entries + rest, !failed)
    }

    /// Raycast's own listing; nothing rather than an error, since the shelf is optional.
    func featured() async -> [ExtensionStoreEntry] {
        (try? await page(ExtensionStoreEndpoint.featured()).entries) ?? []
    }

    /// The first two pages by downloads, which a cold open shows before the catalog arrives.
    func popular() async -> [ExtensionStoreEntry] {
        async let first = try? page(ExtensionStoreEndpoint.popular(page: 1)).entries
        async let second = try? page(ExtensionStoreEndpoint.popular(page: 2)).entries
        return (await first ?? []) + (await second ?? [])
    }

    /// What a query finds before the catalog has loaded.
    func search(_ query: String) async throws -> [ExtensionStoreEntry] {
        try await page(ExtensionStoreEndpoint.search(query, perPage: 50)).entries
    }

    private func page(_ url: URL?) async throws -> ExtensionStorePage {
        guard let url else { throw ExtensionStoreError.malformedResponse }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("Tinycast", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ExtensionStoreError.downloadFailed("HTTP \(http.statusCode)")
        }
        do {
            return try ExtensionStoreWire.page(data)
        } catch {
            throw ExtensionStoreError.malformedResponse
        }
    }
}
