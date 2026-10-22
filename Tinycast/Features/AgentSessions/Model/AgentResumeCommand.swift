import Foundation

enum AgentTerminal: String, CaseIterable, Sendable {
    case terminal, iTerm, ghostty, warp, zap

    var bundleIdentifiers: [String] {
        switch self {
        case .terminal: ["com.apple.Terminal"]
        case .iTerm: ["com.googlecode.iterm2"]
        case .ghostty: ["com.mitchellh.ghostty"]
        case .warp: ["dev.warp.Warp-Stable", "dev.warp.Warp-Preview"]
        case .zap: ["dev.zap.Zap"]
        }
    }

    /// Product names, never translated.
    var displayName: String {
        switch self {
        case .terminal: "Terminal"
        case .iTerm: "iTerm2"
        case .ghostty: "Ghostty"
        case .warp: "Warp"
        case .zap: "Zap"
        }
    }

    enum Launch: Equatable, Sendable { case appleScript, shellScript, folderURL(scheme: String) }

    /// Ghostty < 1.3 has no AppleScript; Warp's URI opens a tab but cannot run a command.
    func launch(version: String?) -> Launch {
        switch self {
        case .terminal, .iTerm: return .appleScript
        case .ghostty:
            guard let version, Self.isAtLeast(version, major: 1, minor: 3) else { return .folderURL(scheme: "") }
            return .appleScript
        case .warp: return .folderURL(scheme: "warp")
        case .zap: return .shellScript
        }
    }

    static func matching(bundleID: String) -> AgentTerminal? {
        allCases.first { $0.bundleIdentifiers.contains(bundleID) }
    }

    private static func isAtLeast(_ version: String, major: Int, minor: Int) -> Bool {
        let parts = version.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        let found = (parts.first ?? 0, parts.count > 1 ? parts[1] : 0)
        return found.0 != major ? found.0 > major : found.1 >= minor
    }
}

enum AgentResumeAction: Equatable, Sendable { case resume, fork, openFolder, attach(shortID: String) }

/// Every command and script the hub hands a terminal; no unvalidated text ever reaches one.
enum AgentResumeCommand {
    /// Letters, digits and `-`; OpenCode's `ses_…` ids and Gemini's own ones may also hold `_`.
    static func isSafeID(_ id: String, underscore: Bool = false) -> Bool {
        (1...64).contains(id.utf8.count)
            && id.utf8.allSatisfy { byte in
                (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
                    || byte == UInt8(ascii: "-") || (underscore && byte == UInt8(ascii: "_"))
            }
    }

    /// POSIX single quotes; an embedded quote closes, escapes and reopens.
    static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// `environment` names a moved folder; `env` sets it, so the `.command` body can still `exec`.
    static func command(
        for session: AgentSession, action: AgentResumeAction, environment: [String: String] = [:]
    ) -> String? {
        let cd = session.directory.map { "cd " + shellQuoted($0) }
        let assignments = environment.filter { isVariableName($0.key) }.sorted { $0.key < $1.key }
            .map { $0.key + "=" + shellQuoted($0.value) + " " }.joined()
        let env = assignments.isEmpty ? "" : "env " + assignments
        func inFolder(_ command: String) -> String { cd.map { $0 + " && " + env + command } ?? env + command }
        switch action {
        case .openFolder:
            return cd
        case .attach(let shortID):
            guard session.source == .claude, isSafeID(shortID) else { return nil }
            return env + "claude attach " + shortID
        case .resume, .fork:
            let underscore = session.source == .gemini || session.source == .openCode
            guard isSafeID(session.sessionID, underscore: underscore) else { return nil }
            let id = session.sessionID
            switch (session.source, action == .fork) {
            case (.claude, false): return inFolder("claude --resume " + id)
            case (.claude, true): return inFolder("claude --resume " + id + " --fork-session")
            case (.codex, false): return inFolder("codex resume " + id)
            case (.codex, true): return inFolder("codex fork " + id)
            // Gemini looks a session up only among its folder's chats, and cannot fork one.
            case (.gemini, false): return cd == nil ? nil : inFolder("gemini --resume " + id)
            case (.gemini, true): return nil
            case (.openCode, false): return inFolder("opencode --session " + id)
            case (.openCode, true): return inFolder("opencode --session " + id + " --fork")
            case (.tinycast, _): return nil
            }
        }
    }

    /// A nil `command` opens the folder alone; Ghostty is given the folder rather than a `cd`.
    static func appleScript(for terminal: AgentTerminal, command: String?, directory: String?) -> String? {
        guard let line = command ?? directory.map({ "cd " + shellQuoted($0) }) else { return nil }
        switch terminal {
        case .terminal:
            return """
                tell application id "com.apple.Terminal"
                    activate
                    do script \(appleScriptString(line))
                end tell
                """
        case .iTerm:
            return """
                tell application id "com.googlecode.iterm2"
                    activate
                    set newWindow to (create window with default profile)
                    tell current session of newWindow to write text \(appleScriptString(line))
                end tell
                """
        case .ghostty:
            var setup = ""
            if let directory {
                setup += "    set initial working directory of cfg to \(appleScriptString(directory))\n"
            }
            if let command {
                let input = appleScriptString(withoutFolder(command, directory: directory))
                setup += "    set initial input of cfg to \(input) & linefeed\n"
            }
            return """
                tell application id "com.mitchellh.ghostty"
                    activate
                    set cfg to new surface configuration
                \(setup)    new window with configuration cfg
                end tell
                """
        case .warp, .zap:
            return nil
        }
    }

    /// Brings the tab on `tty` forward; only Terminal and iTerm2 can say which tab holds a tty.
    static func focusScript(for terminal: AgentTerminal, tty: String) -> String? {
        guard isSafeTTY(tty) else { return nil }
        let device = appleScriptString("/dev/" + tty)
        switch terminal {
        case .terminal:
            return """
                tell application id "com.apple.Terminal"
                    repeat with w in windows
                        repeat with t in tabs of w
                            if tty of t is \(device) then
                                set selected of t to true
                                set index of w to 1
                            end if
                        end repeat
                    end repeat
                    activate
                end tell
                """
        case .iTerm:
            return """
                tell application id "com.googlecode.iterm2"
                    repeat with w in windows
                        repeat with t in tabs of w
                            repeat with s in sessions of t
                                if tty of s is \(device) then
                                    select t
                                    select w
                                end if
                            end repeat
                        end repeat
                    end repeat
                    activate
                end tell
                """
        case .ghostty, .warp, .zap:
            return nil
        }
    }

    /// The `.command` body: it deletes itself first, so a crash midway leaves nothing behind.
    static func script(command: String, directory: String?) -> String {
        let header = "#!/bin/sh\n/bin/rm -f -- \"$0\"\n"
        let rest = withoutFolder(command, directory: directory)
        guard let directory, rest != command else { return header + "exec " + command + "\n" }
        return header + "cd " + shellQuoted(directory) + " && exec " + rest + "\n"
    }

    /// `warp://action/new_tab?path=…`, the path encoded so no character can end the query.
    static func folderURL(scheme: String, directory: String) -> URL? {
        guard !scheme.isEmpty else { return nil }
        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~/")
        guard let path = directory.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: scheme + "://action/new_tab?path=" + path)
    }

    static func isVariableName(_ name: String) -> Bool {
        guard let first = name.utf8.first, !(0x30...0x39).contains(first) else { return false }
        return name.utf8.allSatisfy { byte in
            (0x41...0x5A).contains(byte) || (0x30...0x39).contains(byte) || byte == UInt8(ascii: "_")
        }
    }

    static func isSafeTTY(_ tty: String) -> Bool {
        tty.hasPrefix("tty") && (4...12).contains(tty.count)
            && tty.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII }
    }

    /// An AppleScript string literal: backslash and quote escaped, nothing else interpreted.
    static func appleScriptString(_ text: String) -> String {
        let escaped = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "\"" + escaped + "\""
    }

    private static func withoutFolder(_ command: String, directory: String?) -> String {
        guard let directory else { return command }
        let prefix = "cd " + shellQuoted(directory) + " && "
        return command.hasPrefix(prefix) ? String(command.dropFirst(prefix.count)) : command
    }
}

/// Automatic = the terminal this session last ran in, else Terminal.
enum AgentTerminalPolicy {
    static func choose(preferred: String, lastHostBundleID: String?, installed: Set<String>) -> AgentTerminal {
        func isInstalled(_ terminal: AgentTerminal) -> Bool {
            terminal.bundleIdentifiers.contains(where: installed.contains)
        }
        if let chosen = AgentTerminal(rawValue: preferred), isInstalled(chosen) { return chosen }
        if let host = lastHostBundleID, let terminal = AgentTerminal.matching(bundleID: host), isInstalled(terminal) {
            return terminal
        }
        return .terminal
    }
}
