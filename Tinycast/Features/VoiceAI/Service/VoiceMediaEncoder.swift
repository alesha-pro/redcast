import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Encoding leaves the main actor: five minutes of speech is millions of samples.
enum VoiceMediaEncoder {
    @concurrent
    static func wav(_ samples: [Float]) async -> Data? {
        VoiceAudio.prepared(samples)
    }

    /// One decode at thumbnail size, one JPEG encode: a fraction of the PNG's upload.
    @concurrent
    static func jpeg(fromPNG png: Data, maxEdge: Int = 1_568, quality: Double = 0.8) async -> Data? {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
            let image = CGImageSourceCreateThumbnailAtIndex(
                source, 0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxEdge,
                    kCGImageSourceCreateThumbnailWithTransform: true
                ] as CFDictionary)
        else { return nil }
        let data = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                data, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(
            destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
