import AppKit

/// Opens a session in a terminal, or a folder; one effectful operation per call.
enum AgentTerminalRunner {
    enum Failure: Error { case automationDenied(AgentTerminal), scriptFailed(String), notInstalled }

    /// What the reader still has to do: nothing, or paste the copied command.
    enum Outcome: Equatable, Sendable { case running, pasteToResume }

    /// Leftover scripts older than this go the next time one is written; no timer.
    private static let scriptLifetime: TimeInterval = 86_400

    @MainActor static func installed() -> Set<String> {
        Set(
            AgentTerminal.allCases.flatMap(\.bundleIdentifiers).filter {
                NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil
            })
    }

    @MainActor static func appURL(for terminal: AgentTerminal) -> URL? {
        terminal.bundleIdentifiers.lazy.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
            .first
    }

    /// A nil `command` opens `directory` alone.
    @MainActor static func run(_ command: String?, in directory: String?, terminal: AgentTerminal)
        async throws(Failure) -> Outcome
    {
        guard let appURL = appURL(for: terminal) else { throw .notInstalled }
        let version = Bundle(url: appURL)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        switch terminal.launch(version: version) {
        case .appleScript:
            guard let source = AgentResumeCommand.appleScript(for: terminal, command: command, directory: directory)
            else { throw .scriptFailed("") }
            try await runAppleScript(source, terminal: terminal)
            return .running
        case .shellScript:
            guard let command else { return try await openFolder(directory, with: appURL) }
            let script = try await writeScript(AgentResumeCommand.script(command: command, directory: directory))
            return try await open([script], with: appURL)
        case .folderURL(let scheme):
            guard let directory else { throw .scriptFailed("") }
            if let url = AgentResumeCommand.folderURL(scheme: scheme, directory: directory),
                (try? await NSWorkspace.shared.open(url, configuration: NSWorkspace.OpenConfiguration())) != nil
            {
                return command == nil ? .running : .pasteToResume
            }
            _ = try await openFolder(directory, with: appURL)
            return command == nil ? .running : .pasteToResume
        }
    }

    /// Activates the host, then the tab that holds `tty` where the terminal can say which one.
    @MainActor static func focus(bundleID: String, tty: String?) async -> Bool {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
            let appURL = app.bundleURL
        else { return false }
        if let tty, let terminal = AgentTerminal.matching(bundleID: bundleID),
            let source = AgentResumeCommand.focusScript(for: terminal, tty: tty),
            (try? await runAppleScript(source, terminal: terminal)) != nil
        {
            return true
        }
        return (try? await NSWorkspace.shared.openApplication(at: appURL, configuration: .init())) != nil
    }

    /// Detached: a cold terminal answers Apple events in seconds, never on the main actor.
    private static func runAppleScript(_ source: String, terminal: AgentTerminal) async throws(Failure) {
        let failure: (number: Int?, message: String)? = await Task.detached(priority: .userInitiated) {
            guard let script = NSAppleScript(source: source) else { return (nil, "") }
            var errorInfo: NSDictionary?
            script.executeAndReturnError(&errorInfo)
            guard let errorInfo else { return nil }
            return (
                errorInfo[NSAppleScript.errorNumber] as? Int,
                errorInfo[NSAppleScript.errorMessage] as? String ?? ""
            )
        }.value
        guard let failure else { return }
        if failure.number == -1743 { throw .automationDenied(terminal) }
        throw .scriptFailed(failure.message)
    }

    private static func openFolder(_ directory: String?, with appURL: URL) async throws(Failure) -> Outcome {
        guard let directory else { throw .scriptFailed("") }
        return try await open([URL(filePath: directory, directoryHint: .isDirectory)], with: appURL)
    }

    @MainActor private static func open(_ urls: [URL], with appURL: URL) async throws(Failure) -> Outcome {
        do {
            _ = try await NSWorkspace.shared.open(urls, withApplicationAt: appURL, configuration: .init())
            return .running
        } catch {
            throw .scriptFailed(error.localizedDescription)
        }
    }

    /// Mode 0700 and self-deleting; written off-main with the stale ones swept first.
    @concurrent private static func writeScript(_ body: String) async throws(Failure) -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "agent-sessions", directoryHint: .isDirectory)
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let cutoff = Date().addingTimeInterval(-scriptLifetime)
        let leftovers = (try? fileManager.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in leftovers where file.pathExtension == "command" {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < cutoff { try? fileManager.removeItem(at: file) }
        }
        let url = folder.appending(path: "resume-\(UUID().uuidString).command", directoryHint: .notDirectory)
        do {
            try Data(body.utf8).write(to: url, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        } catch {
            throw .scriptFailed(error.localizedDescription)
        }
        return url
    }
}
