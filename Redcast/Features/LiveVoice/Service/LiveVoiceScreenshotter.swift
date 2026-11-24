import AppKit
import ScreenCaptureKit

/// The display under the cursor as a small JPEG, with the geometry a pointer needs to land on it.
@MainActor
enum LiveVoiceScreenshotter {
    /// 1,280 px keeps interface text legible while the picture stays a few hundred tokens.
    static let maxEdge = 1_280
    nonisolated static let quality = 0.6

    static func capture(maxEdge: Int = LiveVoiceScreenshotter.maxEdge) async -> LiveVoiceImage? {
        guard CGPreflightScreenCaptureAccess() else { return nil }
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main,
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { return nil }
        let display = screen.frame
        let own = ProcessInfo.processInfo.processIdentifier
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let target = content.displays.first(where: { $0.displayID == number.uint32Value }) else {
                return nil
            }
            let filter = SCContentFilter(
                display: target,
                excludingWindows: content.windows.filter { $0.owningApplication?.processID == own })
            let size = LiveVoiceFrame.fitted(
                width: Int(display.width * screen.backingScaleFactor),
                height: Int(display.height * screen.backingScaleFactor), maxEdge: maxEdge)
            let configuration = SCStreamConfiguration()
            configuration.width = size.width
            configuration.height = size.height
            configuration.showsCursor = true
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: configuration)
            guard let jpeg = await encode(image) else { return nil }
            return LiveVoiceImage(
                jpeg: jpeg,
                frame: LiveVoiceFrame(pixelWidth: image.width, pixelHeight: image.height, display: display))
        } catch {
            return nil
        }
    }

    @concurrent
    private static func encode(_ image: sending CGImage) async -> Data? {
        NSBitmapImageRep(cgImage: image).representation(
            using: .jpeg, properties: [.compressionFactor: quality])
    }
}
