import AppKit
import SwiftUI

extension Theme.Colors {
    /// Fork: the brand's vermilion, #F23D32, fixed in both appearances.
    static let vermilion = NSColor(srgbRed: 0xF2 / 255, green: 0x3D / 255, blue: 0x32 / 255, alpha: 1)
    /// Fork: the composer's caret and selected text.
    static let chatCaret = adaptive(dark: NSColor(srgbRed: 1, green: 0.39, blue: 0.39, alpha: 1), light: vermilion)
    static let chatTextSelection = adaptive(
        dark: vermilion.withAlphaComponent(0.40), light: vermilion.withAlphaComponent(0.22))
}

/// Fork: the composer's caret and selection in the accent.
@MainActor
enum ChatComposerInk {
    static func apply(to textView: NSTextView) {
        textView.insertionPointColor = NSColor(Theme.Colors.chatCaret)
        textView.selectedTextAttributes = [.backgroundColor: NSColor(Theme.Colors.chatTextSelection)]
    }
}
