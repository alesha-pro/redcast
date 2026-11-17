import Foundation

/// The installed app updates from Redcast's releases; any other build never updates itself.
enum ReleaseChannel: Sendable {
    case stable
    /// A local build. It has no release stream, and never updates itself.
    case development

    init(bundleID: String?) {
        self = bundleID == "io.redcast.app" ? .stable : .development
    }

    var updatesItself: Bool { self != .development }

    /// Stable never takes a GitHub prerelease.
    func accepts(prerelease: Bool) -> Bool {
        self == .stable && !prerelease
    }
}
