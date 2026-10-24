import AppKit

/// What a file link or chip does; each re-reads the item, since a reply may have aged on screen.
@MainActor
enum ChatFileActions {
    /// Past this many apps Open With is a list to scroll, not a choice.
    private static let openWithLimit = 12
    /// A system menu row's icon, as Finder's own Open With draws it.
    private static let appIconSide: CGFloat = 16

    /// Opens with the default app, or a folder in Finder; anything that would run is revealed.
    static func activate(_ path: String) {
        guard let item = ChatFileSystem.item(at: path) else {
            NSSound.beep()
            return
        }
        let url = fileURL(item)
        guard ChatFileOpenPolicy.opens(item, defaultApp: defaultApp(for: url)) else {
            AppLauncher.showInFinder(url)
            return
        }
        if !NSWorkspace.shared.open(url) { AppLauncher.showInFinder(url) }
    }

    /// A text view's link click; false leaves a web link to the view's own handling.
    static func clicked(_ link: Any) -> Bool {
        guard let url = link as? URL, url.isFileURL else { return false }
        activate(url.path)
        return true
    }

    /// The menu over a file link in a reply's text, or nil where the click missed every link.
    static func menu(for event: NSEvent, in view: NSTextView) -> NSMenu? {
        guard let layout = view.layoutManager, let container = view.textContainer,
            let storage = view.textStorage, storage.length > 0
        else { return nil }
        let origin = view.textContainerOrigin
        let point = view.convert(event.locationInWindow, from: nil)
        let inContainer = CGPoint(x: point.x - origin.x, y: point.y - origin.y)
        let glyph = layout.glyphIndex(for: inContainer, in: container)
        let bounds = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        guard bounds.contains(inContainer) else { return nil }
        let index = layout.characterIndexForGlyph(at: glyph)
        guard index < storage.length,
            let url = storage.attribute(.link, at: index, effectiveRange: nil) as? URL, url.isFileURL
        else { return nil }
        return menu(for: url.path, from: view.window)
    }

    /// The chip's right click, at the pointer.
    static func popUpMenu(for path: String) {
        menu(for: path, from: chatWindow)?.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    static func quickLook(_ path: String) {
        guard let item = ChatFileSystem.item(at: path) else {
            NSSound.beep()
            return
        }
        ChatQuickLookPanel.toggle(fileURL(item), over: chatWindow)
    }

    /// A chip's chat is the key window, or the one under a preview that took the keyboard.
    private static var chatWindow: NSWindow? {
        let key = NSApp.keyWindow
        return key is ChatQuickLookPanel ? key?.parent : key
    }

    static func menu(for path: String, from window: NSWindow?) -> NSMenu? {
        guard let item = ChatFileSystem.item(at: path) else { return nil }
        let url = fileURL(item)
        let menu = NSMenu()
        menu.autoenablesItems = false
        let opens = ChatFileOpenPolicy.opens(item, defaultApp: defaultApp(for: url))
        if opens {
            menu.addItem(ActionItem(String(localized: "Open"), symbol: "arrow.up.forward.square") {
                activate(item.path)
            })
        }
        if item.opens, item.kind != .folder, let apps = openWith(url) { menu.addItem(apps) }
        menu.addItem(ActionItem(String(localized: "Show in Finder"), symbol: "folder") {
            AppLauncher.showInFinder(url)
        })
        menu.addItem(ActionItem(String(localized: "Quick Look"), symbol: "eye") {
            ChatQuickLookPanel.toggle(url, over: window)
        })
        menu.addItem(.separator())
        menu.addItem(ActionItem(String(localized: "Copy Path"), symbol: "doc.on.doc") {
            Paster.copyPlainText(item.path)
        })
        return menu
    }

    private static func openWith(_ url: URL) -> NSMenuItem? {
        let apps = NSWorkspace.shared.urlsForApplications(toOpen: url).filter { app in
            Bundle(url: app)?.bundleIdentifier.map { !ChatFileOpenPolicy.runnerApps.contains($0) } ?? false
        }
        guard !apps.isEmpty else { return nil }
        let submenu = NSMenu()
        let size = IconSize(points: appIconSide, scale: NSScreen.main?.backingScaleFactor ?? 2)
        for app in apps.prefix(openWithLimit) {
            let item = ActionItem(FileManager.default.displayName(atPath: app.path), symbol: nil) {
                NSWorkspace.shared.open(
                    [url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration(),
                    completionHandler: nil)
            }
            item.image = IconCache.icon(forFile: app.path, size: size)
            submenu.addItem(item)
        }
        let parent = NSMenuItem(title: String(localized: "Open With"), action: nil, keyEquivalent: "")
        parent.image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: nil)
        parent.submenu = submenu
        return parent
    }

    private static func defaultApp(for url: URL) -> String? {
        NSWorkspace.shared.urlForApplication(toOpen: url).flatMap { Bundle(url: $0)?.bundleIdentifier }
    }

    private static func fileURL(_ item: ChatFileItem) -> URL {
        URL(fileURLWithPath: item.path, isDirectory: item.kind == .folder)
    }
}

/// A menu item that runs its closure; the menu that holds it keeps it, and so the closure, alive.
@MainActor
private final class ActionItem: NSMenuItem {
    private let run: @MainActor () -> Void

    init(_ title: String, symbol: String?, run: @escaping @MainActor () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { run() }
}
