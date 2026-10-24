import AppKit
import ImageIO

/// Fork: a sent picture's tile at the tile's pixels, one decode at a time to bound the transient.
enum ChatImageDownsampler {
    private static let queue = DispatchQueue(
        label: "com.tinycast.chat-image-tiles", qos: .userInitiated, autoreleaseFrequency: .workItem)

    /// Immutable once made, so it crosses back to the view's actor as it is.
    private struct Tile: @unchecked Sendable {
        let image: NSImage?
    }

    static func tile(_ data: Data, edge: CGFloat) async -> NSImage? {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: Tile(image: decode(data, edge: edge))) }
        }.image
    }

    private static func decode(_ data: Data, edge: CGFloat) -> NSImage? {
        let noCache = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, noCache),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0
        else { return nil }
        // The tile fills a square, so its short side is the one that must cover the edge.
        let longest = min(
            edge * CGFloat(max(width, height)) / CGFloat(min(width, height)), CGFloat(max(width, height)))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(longest.rounded(.up))
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}
