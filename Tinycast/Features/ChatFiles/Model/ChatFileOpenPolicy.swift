import Foundation

/// What a file system says of a path that exists.
struct ChatFileStat: Hashable, Sendable {
    var isDirectory = false
    var isExecutable = false
    var isPackage = false
}

/// One existing file or folder a reply named or made.
struct ChatFileItem: Hashable, Sendable, Identifiable {
    enum Kind: String, Hashable, Sendable {
        case folder
        case image
        case document
        /// A script, binary or installer: shown in Finder, never opened.
        case executable
        /// An app, plug-in or other bundle that runs code: shown in Finder, never opened.
        case package
    }

    /// Absolute and normalised: no `~`, `.` or `..`, and no trailing slash.
    let path: String
    let kind: Kind

    var id: String { path }
    var name: String { path.split(separator: "/").last.map(String.init) ?? path }

    /// A click opens it with its default app, or a folder in Finder; anything else is revealed.
    var opens: Bool {
        switch kind {
        case .folder, .image, .document: true
        case .executable, .package: false
        }
    }
}

/// Which items a click may open, so a reply can never get an app or script run.
enum ChatFileOpenPolicy {
    static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tif", "tiff", "bmp", "avif", "ico", "icns",
        "svg"
    ]

    /// Run, install or import something when opened, so they are only ever revealed.
    static let revealExtensions: Set<String> = [
        "app", "command", "tool", "sh", "bash", "zsh", "fish", "csh", "tcsh", "ksh", "py", "pyw", "rb", "pl",
        "php", "scpt", "scptd", "applescript", "workflow", "action", "pkg", "mpkg", "dmg", "terminal", "jar",
        "exe", "msi", "bat", "cmd", "ps1", "vbs", "webloc", "inetloc", "url", "fileloc", "mobileconfig",
        "configprofile", "prefpane", "kext", "plugin", "bundle", "framework", "appex", "xpc", "saver",
        "qlgenerator", "mdimporter", "osax", "service", "wdgt", "safariextz", "shortcut", "ipa", "appimage",
        "desktop", "lnk", "run", "bin", "out", "cer", "crt", "p12", "pfx", "keychain"
    ]

    /// Opened by a document's own app whatever their mode bits, as a copied-in file often has `+x`.
    static let documentExtensions: Set<String> = imageExtensions.union([
        "pdf", "txt", "md", "markdown", "rtf", "rtfd", "html", "htm", "css", "json", "csv", "tsv", "xml",
        "yaml", "yml", "toml", "log", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "pages", "numbers", "key",
        "odt", "ods", "odp", "epub", "mp3", "m4a", "wav", "aiff", "flac", "mp4", "mov", "m4v", "webm", "mkv",
        "zip"
    ])

    /// Apps that run what they are handed; a file whose default app is one of them is revealed.
    static let runnerApps: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.mitchellh.ghostty",
        "net.kovidgoyal.kitty", "org.alacritty", "com.github.wez.wezterm", "co.zeit.hyper",
        "com.apple.installer", "com.apple.DiskImageMounter", "com.apple.systempreferences",
        "com.apple.Automator", "com.apple.shortcuts", "org.python.PythonLauncher", "com.apple.ScriptEditor2",
        "com.apple.keychainaccess"
    ]

    static func kind(of path: String, _ stat: ChatFileStat) -> ChatFileItem.Kind {
        let ext = pathExtension(path)
        if stat.isDirectory {
            return revealExtensions.contains(ext) ? .package : stat.isPackage ? .document : .folder
        }
        if revealExtensions.contains(ext) { return .executable }
        if stat.isExecutable, !documentExtensions.contains(ext) { return .executable }
        return imageExtensions.contains(ext) ? .image : .document
    }

    /// What a click does once the default app is known; no app at all leaves it to Finder too.
    static func opens(_ item: ChatFileItem, defaultApp: String?) -> Bool {
        guard item.opens else { return false }
        if item.kind == .folder { return true }
        guard let defaultApp else { return false }
        return !runnerApps.contains(defaultApp)
    }

    static func pathExtension(_ path: String) -> String {
        guard let name = path.split(separator: "/").last, let dot = name.lastIndex(of: "."),
            dot != name.startIndex
        else { return "" }
        return name[name.index(after: dot)...].lowercased()
    }
}
