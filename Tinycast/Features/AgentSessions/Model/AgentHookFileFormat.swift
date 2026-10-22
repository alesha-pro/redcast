import Foundation

enum AgentHookTarget: String, Codable, Sendable, CaseIterable {
    case claude, codex

    var agent: AgentSource { self == .claude ? .claude : .codex }
    /// The agent's own folder, which has to exist before the hub offers to touch it.
    var folder: String { self == .claude ? ".claude" : ".codex" }
    var relativePath: String { self == .claude ? ".claude/settings.json" : ".codex/hooks.json" }
}

enum AgentHookEvent: String, Sendable, CaseIterable { case working, waiting, finished, failed, ended }

/// `live-status.json`: the capability record, kept outside `AppSettings` so no backup carries it.
struct LiveStatusRecord: Codable, Equatable, Sendable {
    static let currentVersion = 1
    var version: Int
    var token: String
    var targets: [AgentHookTarget]
    var installedAt: Double

    init(token: String, targets: [AgentHookTarget], installedAt: Date) {
        version = Self.currentVersion
        self.token = token
        self.targets = targets
        self.installedAt = installedAt.timeIntervalSince1970
    }

    static func isValidToken(_ token: String) -> Bool {
        token.utf8.count == 32 && token.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }

    static func decode(_ data: Data) -> LiveStatusRecord? {
        guard let record = try? JSONDecoder().decode(LiveStatusRecord.self, from: data),
            record.version == currentVersion, isValidToken(record.token)
        else { return nil }
        return record
    }
}

/// The hooks the hub adds to an agent's JSON, found again by a marker inside their command.
enum AgentHookFileFormat {
    static let templateVersion = 1

    /// The tool paths the command calls; the harness swaps in recording shims.
    struct Tools: Sendable {
        var head = "/usr/bin/head", cat = "/bin/cat", sed = "/usr/bin/sed"
        var lsappinfo = "/usr/bin/lsappinfo", open = "/usr/bin/open"
        static let system = Tools()
    }

    struct Registration: Equatable, Sendable {
        let hookEvent: String
        let matcher: String?
        let event: AgentHookEvent
    }

    /// `idle_prompt` is left out: it fires a minute after a `Stop` already reported.
    static func registrations(for target: AgentHookTarget) -> [Registration] {
        switch target {
        case .claude:
            [
                Registration(hookEvent: "UserPromptSubmit", matcher: nil, event: .working),
                Registration(
                    hookEvent: "Notification",
                    matcher: "permission_prompt|elicitation_dialog|elicitation_url_dialog|agent_needs_input",
                    event: .waiting),
                Registration(hookEvent: "Stop", matcher: nil, event: .finished),
                Registration(hookEvent: "StopFailure", matcher: nil, event: .failed),
                Registration(hookEvent: "SessionEnd", matcher: nil, event: .ended)
            ]
        case .codex:
            [
                Registration(hookEvent: "UserPromptSubmit", matcher: nil, event: .working),
                Registration(hookEvent: "PermissionRequest", matcher: nil, event: .waiting),
                Registration(hookEvent: "Stop", matcher: nil, event: .finished),
                Registration(hookEvent: "SessionEnd", matcher: nil, event: .ended)
            ]
        }
    }

    static func isSafeBundleID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 128
            && id.utf8.allSatisfy { byte in
                (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
                    || byte == UInt8(ascii: ".") || byte == UInt8(ascii: "-")
            }
    }

    static func command(
        target: AgentHookTarget, event: AgentHookEvent, bundleID: String, token: String,
        tools: Tools = .system
    ) -> String {
        let url =
            "tinycast://agent-sessions/event?v=1&k=\(token)&agent=\(target.rawValue)"
            + "&event=\(event.rawValue)&session=$s&kind=$n&pid=$PPID"
        let session = #"s/.*"session_id" *: *"\([0-9A-Za-z-]\{1,64\}\)".*/\1/p"#
        let kind = #"s/.*"notification_type" *: *"\([a-z_]\{1,40\}\)".*/\1/p"#
        return [
            "p=$(\(tools.head) -c 65536)",
            "\(tools.cat) >/dev/null",
            "[ -n \"$(\(tools.lsappinfo) find bundleid=\(bundleID))\" ] || exit 0",
            "s=$(printf '%s' \"$p\" | \(tools.sed) -n '\(session)' | \(tools.head) -n 1)",
            "n=$(printf '%s' \"$p\" | \(tools.sed) -n '\(kind)' | \(tools.head) -n 1)",
            "\(tools.open) -g -b \(bundleID) \"\(url)\"",
            "exit 0"
        ].joined(separator: "; ")
    }

    /// Unique to one channel, so a Dev build and the fork find and remove only their own hooks.
    static func marker(bundleID: String) -> String {
        "-b \(bundleID) \"tinycast://agent-sessions/event"
    }

    enum State: Equatable, Sendable { case absent, installed, outdated, unreadable(String) }

    static func state(of text: String?, target: AgentHookTarget, bundleID: String, token: String?) -> State {
        guard let text else { return .absent }
        guard let object = validObject(text) else { return .unreadable("not a JSON object") }
        guard object["hooks"] != nil else { return .absent }
        let bytes = Array(text.utf8)
        guard let span = JSONMemberSplice.topLevelMember("hooks", in: bytes),
            case .object(let events)? = OrderedJSON.parse(bytes[span.valueStart..<span.valueEnd])
        else { return .unreadable("hooks is not an object") }
        let marker = marker(bundleID: bundleID)
        let found = ours(in: events, marker: marker)
        guard !found.isEmpty else { return .absent }
        guard let token else { return .outdated }
        let expected = registrations(for: target).map { registration in
            Handler(
                hookEvent: registration.hookEvent, matcher: registration.matcher,
                command: command(target: target, event: registration.event, bundleID: bundleID, token: token))
        }
        // Order-free: an install appends to whatever events another tool already listed.
        return found.sorted(by: Handler.precedes) == expected.sorted(by: Handler.precedes) ? .installed : .outdated
    }

    struct Change: Equatable, Sendable {
        let target: AgentHookTarget
        /// Nil: the file will be created.
        let before: String?
        /// Nil: the file will be deleted, because it held only these hooks.
        let after: String?
        let removedLines: [String]
        let addedLines: [String]
        let firstChangedLine: Int

        var isEmpty: Bool { before == after }
    }

    enum Failure: Error, Equatable { case notJSON, notObject, hooksNotObject, allHooksDisabled }

    static func install(into text: String?, target: AgentHookTarget, bundleID: String, token: String)
        throws(Failure) -> Change
    {
        let groups = registrations(for: target).map { registration in
            (
                registration.hookEvent,
                group(
                    matcher: registration.matcher,
                    command: command(
                        target: target, event: registration.event, bundleID: bundleID, token: token))
            )
        }
        guard let text else {
            let rendered = OrderedJSON.object(try appending(groups, to: [])).rendered(indent: "  ", unit: "  ")
            return change(target, before: nil, after: "{\n  \"hooks\": " + rendered + "\n}\n")
        }
        let object = try parsedObject(text)
        if target == .claude, object["disableAllHooks"] as? Bool == true { throw .allHooksDisabled }
        let bytes = Array(text.utf8)
        guard let layout = JSONMemberSplice.layout(of: bytes) else { throw .notJSON }
        let style = Style(text: text)
        if let span = layout.members.first(where: { $0.key == "hooks" })?.span {
            guard case .object(let events)? = OrderedJSON.parse(bytes[span.valueStart..<span.valueEnd]) else {
                throw .hooksNotObject
            }
            let updated = try appending(groups, to: removing(marker(bundleID: bundleID), from: events))
            let indent = JSONMemberSplice.lineIndent(before: span.keyStart, in: bytes)
            let rendered = OrderedJSON.object(updated).rendered(indent: indent, unit: style.unit, newline: style.newline)
            return change(target, before: text, after: splice(bytes, span.valueStart..<span.valueEnd, rendered))
        }
        let rendered = OrderedJSON.object(try appending(groups, to: []))
            .rendered(indent: style.unit, unit: style.unit, newline: style.newline)
        let member = style.unit + "\"hooks\": " + rendered
        guard let last = layout.members.last else {
            let body = "{" + style.newline + member + style.newline + "}"
            return change(target, before: text, after: splice(bytes, layout.open..<(layout.close + 1), body))
        }
        let end = last.span.valueEnd
        return change(target, before: text, after: splice(bytes, end..<end, "," + style.newline + member))
    }

    /// Nil when nothing of this channel's is in the file.
    static func remove(from text: String, target: AgentHookTarget, bundleID: String) throws(Failure) -> Change? {
        _ = try parsedObject(text)
        let bytes = Array(text.utf8)
        guard let layout = JSONMemberSplice.layout(of: bytes),
            let index = layout.members.firstIndex(where: { $0.key == "hooks" })
        else { return nil }
        let span = layout.members[index].span
        guard case .object(let events)? = OrderedJSON.parse(bytes[span.valueStart..<span.valueEnd]) else {
            throw .hooksNotObject
        }
        let cleaned = removing(marker(bundleID: bundleID), from: events)
        guard cleaned != events else { return nil }
        guard cleaned.isEmpty else {
            let indent = JSONMemberSplice.lineIndent(before: span.keyStart, in: bytes)
            let style = Style(text: text)
            let rendered = OrderedJSON.object(cleaned).rendered(indent: indent, unit: style.unit, newline: style.newline)
            return change(target, before: text, after: splice(bytes, span.valueStart..<span.valueEnd, rendered))
        }
        guard layout.members.count > 1 else {
            if target == .codex { return change(target, before: text, after: nil) }
            return change(target, before: text, after: splice(bytes, layout.open..<(layout.close + 1), "{}"))
        }
        // The member goes with the comma that joined it, so an install undone is the original file.
        let range =
            index > 0
            ? layout.members[index - 1].span.valueEnd..<span.valueEnd
            : span.keyStart..<layout.members[index + 1].span.keyStart
        return change(target, before: text, after: splice(bytes, range, ""))
    }

    // MARK: - Hooks value

    private struct Handler: Equatable {
        let hookEvent: String
        let matcher: String?
        let command: String

        static func precedes(_ lhs: Handler, _ rhs: Handler) -> Bool {
            (lhs.hookEvent, lhs.matcher ?? "", lhs.command) < (rhs.hookEvent, rhs.matcher ?? "", rhs.command)
        }
    }

    private static func group(matcher: String?, command: String) -> OrderedJSON {
        var members: [OrderedJSON.Member] = []
        if let matcher { members.append(.init(key: "matcher", value: .string(matcher))) }
        let handler = OrderedJSON.object([
            .init(key: "type", value: .string("command")),
            .init(key: "command", value: .string(command)),
            .init(key: "async", value: .bool(true))
        ])
        members.append(.init(key: "hooks", value: .array([handler])))
        return .object(members)
    }

    private static func ours(in events: [OrderedJSON.Member], marker: String) -> [Handler] {
        events.flatMap { event -> [Handler] in
            guard case .array(let groups) = event.value else { return [] }
            return groups.flatMap { group -> [Handler] in
                guard case .object(let members) = group else { return [] }
                let matcher = members.first { $0.key == "matcher" }?.value.stringValue
                return handlers(in: members).compactMap { command in
                    command.contains(marker)
                        ? Handler(hookEvent: event.key, matcher: matcher, command: command) : nil
                }
            }
        }
    }

    private static func handlers(in group: [OrderedJSON.Member]) -> [String] {
        guard case .array(let handlers)? = group.first(where: { $0.key == "hooks" })?.value else { return [] }
        return handlers.compactMap { handler in
            guard case .object(let fields) = handler else { return nil }
            return fields.first { $0.key == "command" }?.value.stringValue
        }
    }

    /// Drops this channel's handlers, then any group or event they alone made non-empty.
    private static func removing(_ marker: String, from events: [OrderedJSON.Member]) -> [OrderedJSON.Member] {
        events.compactMap { event in
            guard case .array(let groups) = event.value else { return event }
            var changed = false
            let kept = groups.compactMap { group -> OrderedJSON? in
                guard case .object(var members) = group,
                    let index = members.firstIndex(where: { $0.key == "hooks" }),
                    case .array(let handlers) = members[index].value
                else { return group }
                let remaining = handlers.filter { handler in
                    guard case .object(let fields) = handler,
                        let command = fields.first(where: { $0.key == "command" })?.value.stringValue
                    else { return true }
                    return !command.contains(marker)
                }
                guard remaining.count != handlers.count else { return group }
                changed = true
                guard !remaining.isEmpty else { return nil }
                members[index].value = .array(remaining)
                return .object(members)
            }
            guard changed else { return event }
            return kept.isEmpty ? nil : OrderedJSON.Member(key: event.key, value: .array(kept))
        }
    }

    private static func appending(_ groups: [(String, OrderedJSON)], to events: [OrderedJSON.Member])
        throws(Failure) -> [OrderedJSON.Member]
    {
        var events = events
        for (name, group) in groups {
            guard let index = events.firstIndex(where: { $0.key == name }) else {
                events.append(.init(key: name, value: .array([group])))
                continue
            }
            guard case .array(let existing) = events[index].value else { throw .hooksNotObject }
            events[index].value = .array(existing + [group])
        }
        return events
    }

    // MARK: - Text

    private struct Style {
        let unit: String
        let newline: String

        init(text: String) {
            let unit = JSONMemberSplice.indentUnit(of: text)
            self.unit = unit.isEmpty ? "  " : unit
            newline = text.contains("\r\n") ? "\r\n" : "\n"
        }
    }

    private static func validObject(_ text: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }

    private static func parsedObject(_ text: String) throws(Failure) -> [String: Any] {
        guard let value = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
        else { throw .notJSON }
        guard let object = value as? [String: Any] else { throw .notObject }
        return object
    }

    private static func splice(_ bytes: [UInt8], _ range: Range<Int>, _ replacement: String) -> String {
        (String(bytes: bytes[..<range.lowerBound], encoding: .utf8) ?? "") + replacement
            + (String(bytes: bytes[range.upperBound...], encoding: .utf8) ?? "")
    }

    /// A line diff of the whole file, so lines that only moved never read as changed.
    static func change(_ target: AgentHookTarget, before: String?, after: String?) -> Change {
        let old = before.map(lines(of:)) ?? []
        let new = after.map(lines(of:)) ?? []
        var removed: [(Int, String)] = []
        var added: [(Int, String)] = []
        for step in new.difference(from: old) {
            switch step {
            case .remove(let offset, let line, _): removed.append((offset, line))
            case .insert(let offset, let line, _): added.append((offset, line))
            }
        }
        removed.sort { $0.0 < $1.0 }
        added.sort { $0.0 < $1.0 }
        let first = min(removed.first?.0 ?? .max, added.first?.0 ?? .max)
        return Change(
            target: target, before: before, after: after, removedLines: removed.map(\.1),
            addedLines: added.map(\.1), firstChangedLine: first == .max ? 1 : first + 1)
    }

    private static func lines(of text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
    }
}

/// A JSON value that keeps its keys in file order, so a re-rendered region reads as written.
enum OrderedJSON: Equatable, Sendable {
    struct Member: Equatable, Sendable {
        var key: String
        var value: OrderedJSON
    }

    case object([Member])
    case array([OrderedJSON])
    case string(String)
    /// Kept as written, so `1.0` never comes back as `1`.
    case number(String)
    case bool(Bool)
    case null

    var stringValue: String? {
        guard case .string(let text) = self else { return nil }
        return text
    }

    static func parse(_ bytes: ArraySlice<UInt8>) -> OrderedJSON? {
        var scanner = JSONScanner(bytes: Array(bytes))
        guard let value = scanner.value(depth: 0) else { return nil }
        scanner.skipWhitespace()
        return scanner.isAtEnd ? value : nil
    }

    /// Two-space style by default, the way `JSON.stringify(value, null, 2)` writes it.
    func rendered(indent: String = "", unit: String = "  ", newline: String = "\n") -> String {
        switch self {
        case .object(let members):
            guard !members.isEmpty else { return "{}" }
            let inner = indent + unit
            let body = members.map { member in
                inner + Self.quoted(member.key) + ": "
                    + member.value.rendered(indent: inner, unit: unit, newline: newline)
            }
            return "{" + newline + body.joined(separator: "," + newline) + newline + indent + "}"
        case .array(let values):
            guard !values.isEmpty else { return "[]" }
            let inner = indent + unit
            let body = values.map { inner + $0.rendered(indent: inner, unit: unit, newline: newline) }
            return "[" + newline + body.joined(separator: "," + newline) + newline + indent + "]"
        case .string(let text): return Self.quoted(text)
        case .number(let literal): return literal
        case .bool(let flag): return flag ? "true" : "false"
        case .null: return "null"
        }
    }

    /// RFC 8259 escaping with `/` and non-ASCII left as they are.
    static func quoted(_ text: String) -> String {
        var result = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            case "\u{08}": result += "\\b"
            case "\u{0C}": result += "\\f"
            case _ where scalar.value < 0x20:
                result += String(format: "\\u%04x", scalar.value)
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }
}

/// Locates top-level members in JSON text without reformatting the rest of the file.
enum JSONMemberSplice {
    /// Byte offsets into the UTF-8 text.
    struct Span: Equatable, Sendable { let keyStart: Int; let valueStart: Int; let valueEnd: Int }

    struct Member: Equatable, Sendable {
        let key: String
        let span: Span
    }

    /// `open` and `close` are the root object's braces.
    struct Layout: Equatable, Sendable {
        let open: Int
        let close: Int
        let members: [Member]
    }

    static func topLevelMember(_ key: String, in text: String) -> Span? {
        topLevelMember(key, in: Array(text.utf8))
    }

    static func topLevelMember(_ key: String, in bytes: [UInt8]) -> Span? {
        layout(of: bytes)?.members.first { $0.key == key }?.span
    }

    static func layout(of bytes: [UInt8]) -> Layout? {
        var scanner = JSONScanner(bytes: bytes)
        scanner.skipWhitespace()
        guard scanner.peek == UInt8(ascii: "{") else { return nil }
        let open = scanner.position
        scanner.position += 1
        var members: [Member] = []
        while true {
            scanner.skipWhitespace()
            if scanner.peek == UInt8(ascii: "}"), members.isEmpty { break }
            let keyStart = scanner.position
            guard let key = scanner.string() else { return nil }
            scanner.skipWhitespace()
            guard scanner.peek == UInt8(ascii: ":") else { return nil }
            scanner.position += 1
            scanner.skipWhitespace()
            let valueStart = scanner.position
            guard scanner.skipValue(depth: 0) else { return nil }
            members.append(
                Member(key: key, span: Span(keyStart: keyStart, valueStart: valueStart, valueEnd: scanner.position)))
            scanner.skipWhitespace()
            if scanner.peek == UInt8(ascii: ",") {
                scanner.position += 1
                continue
            }
            guard scanner.peek == UInt8(ascii: "}") else { return nil }
            break
        }
        return Layout(open: open, close: scanner.position, members: members)
    }

    /// The first member's leading whitespace: the file's own indent unit.
    static func indentUnit(of text: String) -> String {
        let bytes = Array(text.utf8)
        guard let first = layout(of: bytes)?.members.first else { return "" }
        return lineIndent(before: first.span.keyStart, in: bytes)
    }

    static func lastMemberEnd(in text: String) -> Int? {
        layout(of: Array(text.utf8))?.members.last?.span.valueEnd
    }

    /// Spaces and tabs between the line's start and `offset`; empty when other text precedes it.
    static func lineIndent(before offset: Int, in bytes: [UInt8]) -> String {
        var start = offset
        while start > 0, bytes[start - 1] == UInt8(ascii: " ") || bytes[start - 1] == UInt8(ascii: "\t") {
            start -= 1
        }
        guard start == 0 || bytes[start - 1] == 0x0A || bytes[start - 1] == 0x0D else { return "" }
        return String(bytes: bytes[start..<offset], encoding: .utf8) ?? ""
    }
}

/// A byte cursor over JSON text; deep nesting is refused rather than recursed into.
private struct JSONScanner {
    let bytes: [UInt8]
    var position = 0
    static let maxDepth = 64

    var isAtEnd: Bool { position >= bytes.count }
    var peek: UInt8? { position < bytes.count ? bytes[position] : nil }

    mutating func skipWhitespace() {
        while let byte = peek, byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D { position += 1 }
    }

    mutating func value(depth: Int) -> OrderedJSON? {
        guard depth < Self.maxDepth else { return nil }
        skipWhitespace()
        switch peek {
        case UInt8(ascii: "{"):
            position += 1
            var members: [OrderedJSON.Member] = []
            skipWhitespace()
            if peek == UInt8(ascii: "}") {
                position += 1
                return .object([])
            }
            while true {
                skipWhitespace()
                guard let key = string() else { return nil }
                skipWhitespace()
                guard peek == UInt8(ascii: ":") else { return nil }
                position += 1
                guard let value = value(depth: depth + 1) else { return nil }
                members.append(.init(key: key, value: value))
                skipWhitespace()
                guard let separator = peek else { return nil }
                position += 1
                if separator == UInt8(ascii: "}") { return .object(members) }
                guard separator == UInt8(ascii: ",") else { return nil }
            }
        case UInt8(ascii: "["):
            position += 1
            var values: [OrderedJSON] = []
            skipWhitespace()
            if peek == UInt8(ascii: "]") {
                position += 1
                return .array([])
            }
            while true {
                guard let value = value(depth: depth + 1) else { return nil }
                values.append(value)
                skipWhitespace()
                guard let separator = peek else { return nil }
                position += 1
                if separator == UInt8(ascii: "]") { return .array(values) }
                guard separator == UInt8(ascii: ",") else { return nil }
            }
        case UInt8(ascii: "\""):
            return string().map(OrderedJSON.string)
        default:
            let start = position
            while let byte = peek, !Self.terminators.contains(byte) { position += 1 }
            let literal = String(bytes: bytes[start..<position], encoding: .utf8) ?? ""
            switch literal {
            case "true": return .bool(true)
            case "false": return .bool(false)
            case "null": return .null
            default:
                guard !literal.isEmpty, Double(literal) != nil else { return nil }
                return .number(literal)
            }
        }
    }

    /// Skips one value, honouring strings, so a brace inside a command never closes an object.
    mutating func skipValue(depth: Int) -> Bool {
        let start = position
        guard value(depth: depth) != nil else {
            position = start
            return false
        }
        return true
    }

    mutating func string() -> String? {
        guard peek == UInt8(ascii: "\"") else { return nil }
        position += 1
        var scalars = String.UnicodeScalarView()
        var run = position
        func flush(_ end: Int) -> Bool {
            guard let text = String(bytes: bytes[run..<end], encoding: .utf8) else { return false }
            scalars.append(contentsOf: text.unicodeScalars)
            return true
        }
        while let byte = peek {
            switch byte {
            case UInt8(ascii: "\""):
                guard flush(position) else { return nil }
                position += 1
                return String(scalars)
            case UInt8(ascii: "\\"):
                guard flush(position) else { return nil }
                position += 1
                guard let scalar = escape() else { return nil }
                scalars.append(scalar)
                run = position
            default:
                guard byte >= 0x20 else { return nil }
                position += 1
            }
        }
        return nil
    }

    private static let terminators: Set<UInt8> = [
        UInt8(ascii: ","), UInt8(ascii: "}"), UInt8(ascii: "]"), 0x20, 0x09, 0x0A, 0x0D
    ]

    /// The scalar an escape stands for, or nil when it is malformed.
    private mutating func escape() -> Unicode.Scalar? {
        guard let byte = peek else { return nil }
        position += 1
        switch byte {
        case UInt8(ascii: "\""): return "\""
        case UInt8(ascii: "\\"): return "\\"
        case UInt8(ascii: "/"): return "/"
        case UInt8(ascii: "b"): return "\u{08}"
        case UInt8(ascii: "f"): return "\u{0C}"
        case UInt8(ascii: "n"): return "\n"
        case UInt8(ascii: "r"): return "\r"
        case UInt8(ascii: "t"): return "\t"
        case UInt8(ascii: "u"):
            guard let high = hex4() else { return nil }
            guard (0xD800...0xDBFF).contains(high) else { return Unicode.Scalar(high) }
            guard peek == UInt8(ascii: "\\"), position + 1 < bytes.count, bytes[position + 1] == UInt8(ascii: "u")
            else { return nil }
            position += 2
            guard let low = hex4(), (0xDC00...0xDFFF).contains(low) else { return nil }
            return Unicode.Scalar(0x10000 + ((high - 0xD800) << 10) + (low - 0xDC00))
        default:
            return nil
        }
    }

    private mutating func hex4() -> UInt32? {
        guard position + 4 <= bytes.count,
            let digits = String(bytes: bytes[position..<(position + 4)], encoding: .utf8),
            let value = UInt32(digits, radix: 16)
        else { return nil }
        position += 4
        return value
    }
}
