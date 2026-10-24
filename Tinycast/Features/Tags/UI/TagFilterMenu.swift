import SwiftUI

/// Fork: the ⌘P tag filter on the Snippets and Quicklinks screens, in the palette's header menu.
@MainActor
enum TagFilterMenu {
    /// The library's tags on a screen that filters by them; nil when there is no button to show.
    static func tags(for mode: PaletteMode, core: AppCore) -> [String]? {
        let lists: [[String]]
        switch mode {
        case .snippets: lists = core.snippetsStore.snippets.filter(\.snippet.isEnabled).map(\.snippet.tags)
        case .quicklinks: lists = core.quicklinks.enabled.map(\.tags)
        default: return nil
        }
        let tags = TagList.library(lists)
        return tags.isEmpty && core.palette.tagFilter == nil ? nil : tags
    }

    static func content(tags: [String], select: @escaping (String?) -> Void) -> PopoverMenuContent {
        let all = PopoverMenuItem(title: String(localized: "All Tags"), systemImage: "tag") { select(nil) }
        let rows = tags.enumerated().map { index, tag in
            var item = PopoverMenuItem(title: tag, icon: .blank, startsSection: index == 0) { select(tag) }
            let hue = RaycastHue.tag(tag).color
            item.trailingAccessory = { AnyView(Circle().fill(hue).frame(width: 8, height: 8)) }
            return item
        }
        return PopoverMenuContent(items: [all] + rows)
    }

    /// The row the menu opens on: the active tag's, or All Tags.
    static func highlight(tags: [String], selection: String?) -> Int {
        guard let selection else { return 0 }
        return tags.firstIndex { TagList.key($0) == TagList.key(selection) }.map { $0 + 1 } ?? 0
    }
}

struct TagFilterButton: View {
    let selection: String?
    let isOpen: Bool
    let action: () -> Void

    var body: some View {
        HeaderMenuButton(
            title: selection ?? String(localized: "All Tags"), systemImage: selection == nil ? "tag" : "tag.fill",
            isOpen: isOpen, help: String(localized: "Filter by tag  ⌘P"), action: action)
    }
}
