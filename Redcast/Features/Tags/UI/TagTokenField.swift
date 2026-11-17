import SwiftUI

/// Fork: the editors' token field: chips, a text field that makes new ones, and library suggestions.
struct TagTokenField: View {
    @Binding var draft: TagDraft
    @Binding var focused: Bool
    /// Every tag the library already uses, which the field offers as the reader types.
    let library: [String]
    let label: String
    let moveFocus: (Bool) -> Void

    @Environment(\.metrics) private var metrics

    private var suggestions: [String] {
        TagList.suggestions(for: draft.text, from: library, excluding: draft.tags)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.spacing.sm) {
            VStack(alignment: .leading, spacing: 0) {
                if !draft.tags.isEmpty {
                    TagFlow(spacing: metrics.spacing.xs) {
                        ForEach(draft.tags, id: \.self) { tag in
                            TagChip(tag: tag) { draft.remove(tag) }
                        }
                    }
                    .padding(.horizontal, metrics.spacing.xl)
                    .padding(.top, metrics.spacing.md)
                }
                FormTextInput(
                    text: $draft.text, focused: $focused,
                    placeholder: String(localized: "Add tags…"), label: label,
                    moveFocus: moveFocus, onCommand: handle
                )
                .frame(height: metrics.size.dialogButtonHeight)
            }
            .formFieldChrome(focused: focused)
            if focused, !suggestions.isEmpty {
                TagFlow(spacing: metrics.spacing.xs) {
                    ForEach(suggestions, id: \.self) { tag in
                        Button {
                            draft.add(tag)
                        } label: {
                            TagChip(tag: tag)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text("Add tag \(tag)"))
                    }
                }
            }
        }
    }

    /// ↵ makes a chip, ⌫ on an empty field takes one back, ⇥ completes the first suggestion.
    private func handle(_ selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            return draft.commitText()
        case #selector(NSResponder.deleteBackward(_:)):
            return draft.removeLast()
        case #selector(NSResponder.insertTab(_:)):
            guard TagList.cleaned(draft.text) != nil, let first = suggestions.first else { return false }
            draft.add(first)
            return true
        default:
            return false
        }
    }
}
