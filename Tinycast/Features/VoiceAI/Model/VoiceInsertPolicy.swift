import Foundation

/// When an INSERT reply may be typed straight into the app it was asked from.
enum VoiceInsertPolicy {
    static let maxAutoInsertLength = 4_000
    /// A paste here can run a command, so a reply is shown for ↵ first.
    static let reviewFirstBundleIDs: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty",
        "dev.warp.Warp-Stable", "net.kovidgoyal.kitty", "org.alacritty", "com.github.wez.wezterm"
    ]

    static func autoInserts(_ text: String, bundleID: String?, hadFocusedField: Bool) -> Bool {
        guard hadFocusedField, !text.isEmpty, text.count <= maxAutoInsertLength else { return false }
        return bundleID.map { !reviewFirstBundleIDs.contains($0) } ?? true
    }
}
