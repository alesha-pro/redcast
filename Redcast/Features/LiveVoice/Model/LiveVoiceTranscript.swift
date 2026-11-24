import Foundation

/// Pure transcript builder for a Live Voice session, turning wire updates into ordered turns.
struct LiveVoiceTranscript: Sendable {
    enum Role: Equatable, Sendable {
        case user
        case assistant
    }

    struct ToolRecord: Equatable, Sendable {
        let callID: String
        let origin: String
        let title: String
        var isRunning: Bool
        var isError: Bool
        let textOffset: Int
        let sequence: Int
    }

    struct Entry: Equatable, Sendable {
        let id: UUID
        let role: Role
        var text: String
        var tools: [ToolRecord]
        let sentAt: Date

        init(
            id: UUID = UUID(), role: Role, text: String, tools: [ToolRecord] = [],
            sentAt: Date = Date()
        ) {
            self.id = id
            self.role = role
            self.text = text
            self.tools = tools
            self.sentAt = sentAt
        }
    }

    private(set) var entries: [Entry] = []
    private var openUserIndex: Int?
    private var openAssistantIndex: Int?
    private var hasUserForOpenAssistant = false

    mutating func noteUserText(_ text: String, at now: Date = Date()) {
        guard !text.isEmpty else { return }
        if let assistantIndex = openAssistantIndex {
            // OpenAI delivers the input transcript after the reply starts; keep user before reply.
            if hasUserForOpenAssistant, assistantIndex > 0, entries[assistantIndex - 1].role == .user {
                entries[assistantIndex - 1].text += text
            } else {
                entries.insert(Entry(role: .user, text: text, sentAt: now), at: assistantIndex)
                openAssistantIndex = assistantIndex + 1
                hasUserForOpenAssistant = true
            }
            return
        }
        if let userIndex = openUserIndex {
            entries[userIndex].text += text
        } else {
            openUserIndex = entries.count
            entries.append(Entry(role: .user, text: text, sentAt: now))
        }
    }

    mutating func noteAssistantText(_ text: String, at now: Date = Date()) {
        guard !text.isEmpty else { return }
        let index = ensureOpenAssistant(at: now)
        entries[index].text += text
    }

    mutating func noteToolCall(_ call: AIToolCall, origin: String, at now: Date = Date()) {
        let index = ensureOpenAssistant(at: now)
        let record = ToolRecord(
            callID: call.id, origin: origin, title: call.name, isRunning: true, isError: false,
            textOffset: entries[index].text.count, sequence: entries[index].tools.count)
        entries[index].tools.append(record)
    }

    mutating func noteToolResult(_ call: AIToolCall, result: AIToolResult) {
        for entryIndex in entries.indices.reversed() where entries[entryIndex].role == .assistant {
            guard
                let toolIndex = entries[entryIndex].tools.lastIndex(where: { $0.callID == call.id })
            else { continue }
            entries[entryIndex].tools[toolIndex].isRunning = false
            entries[entryIndex].tools[toolIndex].isError = result.isError
            return
        }
    }

    mutating func finishReply() {
        if let index = openAssistantIndex {
            entries[index].text = entries[index].text.trimmingCharacters(in: .whitespacesAndNewlines)
            for toolIndex in entries[index].tools.indices where entries[index].tools[toolIndex].isRunning {
                entries[index].tools[toolIndex].isRunning = false
            }
            if entries[index].text.isEmpty && entries[index].tools.isEmpty {
                entries.remove(at: index)
            }
        }
        trimOpenUserIfNeeded()
        openAssistantIndex = nil
        openUserIndex = nil
        hasUserForOpenAssistant = false
    }

    mutating func finishAll() {
        finishReply()
        entries = entries.compactMap { entry in
            var cleaned = entry
            cleaned.text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return cleaned.text.isEmpty && cleaned.tools.isEmpty ? nil : cleaned
        }
    }

    /// Compact summary of recent turns sent as a note after reconnecting without a server token.
    func recap(maxEntries: Int = 8, maxBytes: Int = 4_000) -> String? {
        let nonEmpty = entries.compactMap { entry -> String? in
            let text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let speaker = entry.role == .user ? "User" : "Assistant"
            return "\(speaker): \(text)"
        }
        guard !nonEmpty.isEmpty else { return nil }
        var kept: [String] = []
        var bytes = 0
        for line in nonEmpty.suffix(maxEntries).reversed() {
            let cost = line.utf8.count + 1
            if bytes + cost > maxBytes, !kept.isEmpty { break }
            kept.append(line)
            bytes += cost
        }
        let body = kept.reversed().joined(separator: "\n")
        return "Reconnected after a brief drop. Earlier turns for context only (do not repeat them):\n\(body)"
    }

    private mutating func ensureOpenAssistant(at now: Date) -> Int {
        if let index = openAssistantIndex { return index }
        trimOpenUserIfNeeded()
        hasUserForOpenAssistant = openUserIndex != nil
        openUserIndex = nil
        let index = entries.count
        entries.append(Entry(role: .assistant, text: "", sentAt: now))
        openAssistantIndex = index
        return index
    }

    private mutating func trimOpenUserIfNeeded() {
        guard let index = openUserIndex, entries.indices.contains(index) else { return }
        entries[index].text = entries[index].text.trimmingCharacters(in: .whitespacesAndNewlines)
        if entries[index].text.isEmpty {
            entries.remove(at: index)
            openUserIndex = nil
        }
    }
}
