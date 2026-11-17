import AppKit
import ScreenCaptureKit

/// A picture of one app's frontmost window, or nil whenever Screen Recording is not granted.
nonisolated enum WindowScreenshotter {
    /// Layer 0 is the normal window band; menus, the Dock and overlays sit above it.
    private static let normalLayer = 0
    /// Accessibility and the window server round a window's frame differently by a point or two.
    private static let frameTolerance: CGFloat = 4

    static func capture(pid: pid_t, frame: CGRect?) async -> Data? {
        guard CGPreflightScreenCaptureAccess(), let windowID = windowID(pid: pid, frame: frame)
        else { return nil }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true)
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                return nil
            }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let configuration = SCStreamConfiguration()
            let scale = CGFloat(filter.pointPixelScale)
            configuration.width = max(1, Int(filter.contentRect.width * scale))
            configuration.height = max(1, Int(filter.contentRect.height * scale))
            configuration.showsCursor = false
            configuration.ignoreShadowsSingleWindow = true
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: configuration)
            return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        } catch {
            return nil
        }
    }

    /// Front to back, so with no frame to match the app's topmost normal window wins.
    private static func windowID(pid: pid_t, frame: CGRect?) -> CGWindowID? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let listing = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        let candidates = listing.filter {
            $0[kCGWindowOwnerPID as String] as? pid_t == pid
                && $0[kCGWindowLayer as String] as? Int == normalLayer
        }
        func id(_ window: [String: Any]) -> CGWindowID? {
            (window[kCGWindowNumber as String] as? NSNumber).map { CGWindowID($0.uint32Value) }
        }
        if let frame,
            let match = candidates.first(where: { window in
                guard let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                    let rect = CGRect(dictionaryRepresentation: bounds)
                else { return false }
                return abs(rect.minX - frame.minX) <= frameTolerance
                    && abs(rect.minY - frame.minY) <= frameTolerance
                    && abs(rect.width - frame.width) <= frameTolerance
                    && abs(rect.height - frame.height) <= frameTolerance
            })
        {
            return id(match)
        }
        return candidates.first.flatMap(id)
    }
}

/// Screen Recording has a one-time prompt and no API to revoke it; everything else is Settings.
enum ScreenRecordingAccess {
    static var isGranted: Bool { CGPreflightScreenCaptureAccess() }

    /// Prompts only the first time; after a refusal macOS answers false without asking again.
    @discardableResult
    static func request() -> Bool { CGRequestScreenCaptureAccess() }

    @MainActor
    static func openSettings() {
        guard
            let url = URL(
                string:
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        else { return }
        NSWorkspace.shared.open(url)
    }
}
