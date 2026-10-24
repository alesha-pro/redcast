import Foundation

/// The store's three unofficial listings; each answers pages of the same entry shape.
enum ExtensionStoreEndpoint {
    /// The most `per_page` the search endpoint was seen to honour; the others ignore it.
    static let catalogPageSize = 200
    /// A ceiling on the pages one fetch follows, at twice the catalog's size today.
    static let maxCatalogPages = 40

    /// The search endpoint with no query is the whole macOS catalog, in no particular order.
    static func catalog(page: Int) -> URL? {
        search("", page: page, perPage: catalogPageSize)
    }

    static func search(_ query: String, page: Int = 1, perPage: Int? = nil) -> URL? {
        guard let url = ExtensionStoreResponse.searchURL(query: query, page: page) else { return nil }
        guard let perPage else { return url }
        return url.appending(queryItems: [URLQueryItem(name: "per_page", value: String(perPage))])
    }

    /// Every platform's extensions by downloads, ten a page; the first pages are a cold open's shelf.
    static func popular(page: Int) -> URL? {
        var components = URLComponents(string: "https://www.raycast.com/frontend_api/extensions")
        components?.queryItems = [URLQueryItem(name: "page", value: String(page))]
        return components?.url
    }

    /// Raycast's own store listing, in the order it curates: the Featured shelf.
    static func featured(page: Int = 1) -> URL? {
        var components = URLComponents(string: "https://backend.raycast.com/api/v1/store_listings")
        components?.queryItems = [
            URLQueryItem(name: "per_page", value: "100"), URLQueryItem(name: "page", value: String(page))
        ]
        return components?.url
    }

    /// How many catalog pages follow the first, from the total it reported.
    static func remainingCatalogPages(total: Int?) -> Int {
        guard let total, total > catalogPageSize else { return 0 }
        let pages = (total + catalogPageSize - 1) / catalogPageSize
        return min(pages, maxCatalogPages) - 1
    }
}
