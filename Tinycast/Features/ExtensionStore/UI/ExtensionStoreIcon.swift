import SwiftUI

/// A store entry's artwork through the extensions' own remote icon cache, fetched only when drawn.
struct ExtensionStoreIcon: View {
    let entry: ExtensionStoreEntry
    let side: CGFloat
    @Environment(\.colorScheme) private var colorScheme
    @State private var image: NSImage?

    private var url: URL? { entry.iconURL(isDark: colorScheme == .dark) }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                Image(systemName: "puzzlepiece.extension")
                    .resizable()
                    .scaledToFit()
                    .padding(side * 0.15)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: side, height: side)
        .task(id: url) {
            image = nil
            guard let url else { return }
            let loaded = await ExtensionIconCache.loadRemoteAsync(url)
            guard !Task.isCancelled else { return }
            image = loaded
        }
        .accessibilityHidden(true)
    }
}
