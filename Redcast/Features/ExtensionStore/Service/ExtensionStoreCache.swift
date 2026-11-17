import Foundation

/// The one copy of the catalog on disk, in Caches, so the system may purge it and nothing breaks.
struct ExtensionStoreCache: Sendable {
    let fileURL: URL

    static func standard() -> ExtensionStoreCache {
        ExtensionStoreCache(fileURL: AppPaths.caches().appending(path: "extension-store.json"))
    }

    func read() -> ExtensionStoreCatalog? {
        (try? Data(contentsOf: fileURL)).flatMap(ExtensionStoreCacheFormat.decode)
    }

    /// Only a whole catalog: a partial one would pass for fresh and hide the rest for a day.
    func write(_ catalog: ExtensionStoreCatalog) {
        guard catalog.isComplete, let data = try? ExtensionStoreCacheFormat.encode(catalog) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
