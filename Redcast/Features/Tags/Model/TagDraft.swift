import Foundation

/// Fork: a tag field's state: the chips already made and the text still being typed.
struct TagDraft: Equatable, Sendable {
    private(set) var tags: [String]
    var text = "" {
        didSet { absorbSeparators() }
    }

    init(_ tags: [String] = []) {
        self.tags = TagList.normalized(tags)
    }

    /// What a save writes: an unfinished tag still counts, so nothing typed is lost.
    var committed: [String] { TagList.normalized(tags + [text]) }

    /// ↵ turns the typed text into a chip; false when there was nothing to turn.
    @discardableResult
    mutating func commitText() -> Bool {
        guard TagList.cleaned(text) != nil else { return false }
        tags = committed
        text = ""
        return true
    }

    mutating func add(_ tag: String) {
        tags = TagList.normalized(tags + [tag])
        text = ""
    }

    mutating func remove(_ tag: String) {
        tags.removeAll { TagList.key($0) == TagList.key(tag) }
    }

    /// ⌫ in an empty field takes the last chip back; false when there was none.
    @discardableResult
    mutating func removeLast() -> Bool {
        guard text.isEmpty, !tags.isEmpty else { return false }
        tags.removeLast()
        return true
    }

    /// A typed or pasted comma ends a tag, as Raycast's field does.
    private mutating func absorbSeparators() {
        guard text.contains(",") else { return }
        var parts = text.components(separatedBy: ",")
        let rest = parts.removeLast()
        tags = TagList.normalized(tags + parts)
        text = rest.trimmingCharacters(in: .whitespaces).isEmpty ? "" : rest
    }
}
