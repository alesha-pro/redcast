import Foundation

/// The built-in families as one provider; each call gets an executor bound to its turn.
struct AgentBuiltInTools: AgentToolProvider {
    func specs(for turn: AgentTurn) -> [AgentToolSpec] {
        AgentToolbox.tools(for: turn.profile, hasSkills: !turn.skills.isEmpty)
            .map { AgentToolbox.spec(for: $0) }
    }

    func run(_ call: AIToolCall, in context: AgentToolContext) async -> AIToolResult {
        await AgentToolExecutor(
            profile: context.turn.profile, skills: context.turn.skills,
            memoryURL: context.turn.memoryURL, consent: context.consent
        ).run(call)
    }
}

/// Runs one built-in call off-main; a refusal or failure comes back as text the model can read.
nonisolated struct AgentToolExecutor: Sendable {
    let profile: AgentProfile
    let skills: [AgentSkill]
    let memoryURL: URL
    let consent: @Sendable (AgentConsentRequest) async -> Bool
    var documents: DocumentTextService = .bundled

    /// Under the loop's own 32 KB cap per result, so a cut here can still say where to continue.
    private static let maxOutputBytes = 28 * 1_024
    /// A PDF's pages per read, so their headings and the way on still fit `maxOutputBytes`.
    private static let pdfBudget = 24 * 1_024
    /// Text the helper hands back from a document, paged here by line like a text file.
    private static let documentTextBytes = 1_048_576
    private static let maxLines = 2_000
    private static let pageLabel = "HTML as Markdown; raw: true reads its source"
    private static let maxListed = 1_000
    private static let defaultTimeout = 120
    private static let maxTimeout = 600
    private static let maxMemoryBytes = 64 * 1_024

    private var home: String { AgentContextLoader.home }

    func run(_ call: AIToolCall) async -> AIToolResult {
        let arguments =
            JSONValue(data: Data(call.arguments.utf8))?.objectValue ?? [:]
        let outcome: Result<String, AgentToolFailure>
        switch call.name {
        case AgentToolbox.listDirectory: outcome = listDirectory(arguments)
        case AgentToolbox.readFile: outcome = await readFile(arguments)
        case AgentToolbox.searchFiles: outcome = await searchFiles(arguments)
        case AgentToolbox.writeFile: outcome = await writeFile(arguments)
        case AgentToolbox.editFile: outcome = await editFile(arguments)
        case AgentToolbox.runCommand: outcome = await runCommand(arguments)
        case AgentToolbox.webFetch: outcome = await webFetch(arguments)
        case AgentToolbox.readMemory: outcome = readMemory()
        case AgentToolbox.writeMemory: outcome = writeMemory(arguments)
        case AgentToolbox.loadSkill: outcome = loadSkill(arguments)
        default: outcome = .failure(.init("There is no tool called \(call.name)."))
        }
        switch outcome {
        case .success(let text): return AIToolResult(callID: call.id, content: text, isError: false)
        case .failure(let failure): return .failure(call.id, failure.message)
        }
    }

    // MARK: - Files

    private func listDirectory(_ arguments: [String: JSONValue]) -> Result<String, AgentToolFailure> {
        let path: String
        switch readablePath(arguments["path"]?.stringValue ?? ".") {
        case .success(let resolved): path = resolved
        case .failure(let failure): return .failure(failure)
        }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: path) else {
            return .failure(.init("\(path) is not a folder that can be listed."))
        }
        let entries = names.sorted().prefix(Self.maxListed).map { name -> String in
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(
                atPath: (path as NSString).appendingPathComponent(name), isDirectory: &isDirectory)
            return isDirectory.boolValue ? name + "/" : name
        }
        let more = names.count > Self.maxListed ? "\n… \(names.count - Self.maxListed) more" : ""
        return .success(entries.isEmpty ? "(empty)" : entries.joined(separator: "\n") + more)
    }

    private func readFile(_ arguments: [String: JSONValue]) async -> Result<String, AgentToolFailure> {
        guard let raw = arguments["path"]?.stringValue else { return .failure(.missing("path")) }
        let path: String
        switch readablePath(raw) {
        case .success(let resolved): path = resolved
        case .failure(let failure): return .failure(failure)
        }
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isFolder) else {
            return .failure(.init("\(path) does not exist."))
        }
        guard !isFolder.boolValue else { return .failure(.init("\(path) is a folder; list it with list_dir.")) }
        let head = FileHandle(forReadingAtPath: path).flatMap { handle in
            defer { try? handle.close() }
            return try? handle.read(upToCount: 8_192)
        } ?? Data()
        let kind = DocumentKind.of(path: path, head: head)
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
        guard size <= kind.maxFileBytes else {
            return .failure(.init("\(path) is \(size) bytes, too large to read here."))
        }
        let outcome: Result<String, AgentToolFailure>
        switch kind {
        case .binary:
            outcome = .failure(.init(
                "\(path) is a binary file. read_file reads text, PDFs, images, Word, RTF, ODT and HTML."))
        case .text, .html:
            guard let data = FileManager.default.contents(atPath: path) else {
                return .failure(.init("\(path) could not be read."))
            }
            guard let text = String(data: data, encoding: .utf8) else {
                return .failure(.init("\(path) is not a UTF-8 text file."))
            }
            let asPage = kind == .html && arguments["raw"]?.boolValue != true
            outcome =
                asPage
                ? Self.numbered(Self.markdown(text, of: path), path: path, arguments, as: Self.pageLabel)
                : Self.numbered(text, path: path, arguments)
        case .pdf: outcome = await readPDF(path, arguments)
        case .image, .richText: outcome = await readDocument(path, kind: kind, arguments)
        }
        return outcome
    }

    private func readPDF(_ path: String, _ arguments: [String: JSONValue]) async -> Result<String, AgentToolFailure> {
        let range: DocumentPageRange
        switch WebPageTool.position(in: arguments).pages {
        case nil: range = .all
        case let pages?:
            guard let parsed = DocumentPageRange(pages) else {
                return .failure(.init("pages takes a page, a range or an open range: \"3\", \"3-5\", \"8-\"."))
            }
            range = parsed
        }
        let request = DocumentTextRequest(path: path, kind: .pdf, pages: range, budget: Self.pdfBudget)
        switch await documents.read(request) {
        case .success(let text): return .success(text.pdfAnswer(for: path, asked: range))
        case .failure(let failure): return .failure(.init(failure.message))
        }
    }

    /// An image's OCR text or a document's text, paged by line like a text file.
    private func readDocument(
        _ path: String, kind: DocumentKind, _ arguments: [String: JSONValue]
    ) async -> Result<String, AgentToolFailure> {
        let request = DocumentTextRequest(path: path, kind: kind, budget: Self.documentTextBytes)
        switch await documents.read(request) {
        case .success(let text):
            let body = text.pages.map(\.text).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else {
                return .success(kind == .image ? "No text was recognized in \(path)." : "\(path) holds no text.")
            }
            let label = kind == .image ? "image, its text recognized by OCR" : "document, as plain text"
            let read = Self.numbered(body, path: path, arguments, as: label)
            guard text.cut, case .success(let shown) = read, !shown.contains("continue with offset") else { return read }
            return .success(shown + "\n[The text goes on past the \(Self.documentTextBytes / 1_048_576) MB read here.]")
        case .failure(let failure): return .failure(.init(failure.message))
        }
    }

    private func searchFiles(_ arguments: [String: JSONValue]) async -> Result<String, AgentToolFailure> {
        guard let pattern = arguments["pattern"]?.stringValue, !pattern.isEmpty else {
            return .failure(.missing("pattern"))
        }
        let path: String
        switch readablePath(arguments["path"]?.stringValue ?? ".") {
        case .success(let resolved): path = resolved
        case .failure(let failure): return .failure(failure)
        }
        let ripgrep = ["/opt/homebrew/bin/rg", "/usr/local/bin/rg"].first {
            FileManager.default.isExecutableFile(atPath: $0)
        }
        let executable = ripgrep ?? "/usr/bin/grep"
        let arguments =
            ripgrep != nil
            ? ["-n", "--no-heading", "--color", "never", "-S", "--max-columns", "300", "-m", "50",
               "--", pattern, path]
            : ["-rnIE", "--", pattern, path]
        let result = await AgentProcess.run(executable, arguments: arguments, timeout: 20)
        let text = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .success("No matches.") }
        return .success(Self.tail(text, keepingHead: true))
    }

    private func writeFile(_ arguments: [String: JSONValue]) async -> Result<String, AgentToolFailure> {
        guard let raw = arguments["path"]?.stringValue else { return .failure(.missing("path")) }
        guard let content = arguments["content"]?.stringValue else {
            return .failure(.missing("content"))
        }
        let path: String
        switch writablePath(raw) {
        case .success(let resolved): path = resolved
        case .failure(let failure): return .failure(failure)
        }
        let exists = FileManager.default.fileExists(atPath: path)
        let request = AgentConsentRequest(
            summary: (exists ? "Overwrite " : "Create ") + path,
            detail: Self.preview(content) + "\n\n(\(content.utf8.count) bytes)")
        guard await consent(request) else { return .failure(.declined) }
        do {
            try FileManager.default.createDirectory(
                atPath: (path as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true)
            try Data(content.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            return .failure(.init("Writing \(path) failed: \(error.localizedDescription)"))
        }
        return .success("Wrote \(content.utf8.count) bytes to \(path).")
    }

    private func editFile(_ arguments: [String: JSONValue]) async -> Result<String, AgentToolFailure> {
        guard let raw = arguments["path"]?.stringValue else { return .failure(.missing("path")) }
        guard let old = arguments["old_text"]?.stringValue, !old.isEmpty else {
            return .failure(.missing("old_text"))
        }
        let new = arguments["new_text"]?.stringValue ?? ""
        let path: String
        switch writablePath(raw) {
        case .success(let resolved): path = resolved
        case .failure(let failure): return .failure(failure)
        }
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            return .failure(.init("\(path) is not a readable UTF-8 text file."))
        }
        let count = text.components(separatedBy: old).count - 1
        guard count == 1 else {
            return .failure(
                .init(
                    count == 0
                        ? "old_text was not found in \(path)."
                        : "old_text occurs \(count) times in \(path); include more context."))
        }
        let request = AgentConsentRequest(
            summary: "Edit " + path,
            detail: "− " + Self.preview(old) + "\n\n+ " + Self.preview(new))
        guard await consent(request) else { return .failure(.declined) }
        do {
            try Data(text.replacingOccurrences(of: old, with: new).utf8)
                .write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            return .failure(.init("Writing \(path) failed: \(error.localizedDescription)"))
        }
        return .success("Edited \(path).")
    }

    // MARK: - Terminal

    private func runCommand(_ arguments: [String: JSONValue]) async -> Result<String, AgentToolFailure> {
        guard profile.access.writes else {
            return .failure(.init("This agent is read-only and cannot run commands."))
        }
        guard let command = arguments["command"]?.stringValue,
            !command.trimmingCharacters(in: .whitespaces).isEmpty
        else { return .failure(.missing("command")) }
        let timeout = min(
            Self.maxTimeout, max(1, arguments["timeout_seconds"]?.intValue ?? Self.defaultTimeout))
        let request = AgentConsentRequest(summary: command, detail: "in \(profile.directory)")
        guard await consent(request) else { return .failure(.declined) }
        let session = ShellCommandRunner.stream(
            command, loadingShellEnvironment: true, workingDirectory: profile.directory)
        // Abandoning the events leaves the command running, so Stop has to stop it.
        return await withTaskCancellationHandler {
            await collect(session, timeout: timeout)
        } onCancel: {
            session.stop()
        }
    }

    private func collect(
        _ session: ShellCommandSession, timeout: Int
    ) async -> Result<String, AgentToolFailure> {
        let watchdog = Task {
            try await Task.sleep(for: .seconds(timeout))
            session.stop()
        }
        defer { watchdog.cancel() }
        var output = ""
        var status = "finished"
        for await event in session.events {
            switch event {
            case .output(let text):
                output += text
                // Only the tail survives, so a flood never grows without bound.
                if output.utf8.count > Self.maxOutputBytes * 4 {
                    output = String(output.suffix(Self.maxOutputBytes * 2))
                }
            case .finished(let result):
                switch result.termination {
                case .exited(let code): status = "exit status \(code)"
                case .launchFailed(let reason): return .failure(.init(reason))
                case .stopped: status = "stopped after \(timeout) s"
                }
            }
        }
        let clean = Self.withoutEscapes(output).trimmingCharacters(in: .whitespacesAndNewlines)
        return .success(status + (clean.isEmpty ? "" : "\n\n" + Self.tail(clean, keepingHead: false)))
    }

    // MARK: - Web

    private func webFetch(_ arguments: [String: JSONValue]) async -> Result<String, AgentToolFailure> {
        guard let raw = arguments["url"]?.stringValue,
            let asked = URL(string: raw.trimmingCharacters(in: CharacterSet(charactersIn: " \n\t<>"))),
            WebPageScope.key(for: asked) != nil
        else { return .failure(.init("web_fetch takes an http or https URL with no user name or password.")) }
        let url = WebPageScope.secured(asked)
        guard await consent(AgentConsentRequest(summary: "Fetch " + url.absoluteString, detail: "")) else {
            return .failure(.declined)
        }
        let position = WebPageTool.position(in: arguments)
        let read = await WebPageReader.read(
            url, part: position.part, pages: position.pages, tool: AgentToolbox.webFetch, documents: documents)
        switch read {
        case .success(let page): return .success(WebPageTool.answer(page.text, from: url))
        case .failure(let failure): return .failure(.init(failure.message))
        }
    }

    // MARK: - Memory and skills

    private func readMemory() -> Result<String, AgentToolFailure> {
        let text = (try? String(contentsOf: memoryURL, encoding: .utf8)) ?? ""
        return .success(text.isEmpty ? "(no notes yet)" : text)
    }

    private func writeMemory(_ arguments: [String: JSONValue]) -> Result<String, AgentToolFailure> {
        guard let text = arguments["text"]?.stringValue, !text.isEmpty else {
            return .failure(.missing("text"))
        }
        let replace = arguments["replace"]?.boolValue ?? false
        let existing = replace ? "" : ((try? String(contentsOf: memoryURL, encoding: .utf8)) ?? "")
        let updated = existing.isEmpty ? text : existing + "\n\n" + text
        guard updated.utf8.count <= Self.maxMemoryBytes else {
            return .failure(.init("Notes would pass 64 KB; rewrite them shorter with replace."))
        }
        do {
            try FileManager.default.createDirectory(
                at: memoryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(updated.utf8).write(to: memoryURL, options: .atomic)
        } catch {
            return .failure(.init("Saving notes failed: \(error.localizedDescription)"))
        }
        return .success(replace ? "Notes replaced." : "Noted.")
    }

    private func loadSkill(_ arguments: [String: JSONValue]) -> Result<String, AgentToolFailure> {
        guard let name = arguments["name"]?.stringValue else { return .failure(.missing("name")) }
        guard let skill = skills.first(where: { $0.name == name }) else {
            return .failure(
                .init("No skill is called \(name). Available: "
                      + skills.map(\.name).joined(separator: ", ")))
        }
        guard let text = try? String(contentsOfFile: skill.manifestPath, encoding: .utf8) else {
            return .failure(.init("\(skill.manifestPath) could not be read."))
        }
        let files = (FileManager.default.enumerator(atPath: skill.directory)?.allObjects as? [String] ?? [])
            .filter { !$0.hasPrefix(".") && !$0.contains("/.") }.sorted().prefix(200)
        let listing = files.joined(separator: "\n")
        return .success(
            Self.tail(
                "Skill folder: \(skill.directory)\nRead its files with read_file.\n\n\(text)"
                    + "\n\nFiles:\n\(listing)", keepingHead: true))
    }

    // MARK: - Paths

    private func readablePath(_ raw: String) -> Result<String, AgentToolFailure> {
        let path = Self.resolvingLinks(
            AgentPathPolicy.resolve(raw, in: profile.directory, home: home))
        var profile = profile
        profile.directory = Self.resolvingLinks(profile.directory)
        switch AgentPathPolicy.readable(
            path, profile: profile, extraRoots: skills.map(\.directory).map(Self.resolvingLinks))
        {
        case .allowed(let allowed): return .success(allowed)
        case .refused(let reason): return .failure(.init(reason))
        }
    }

    private func writablePath(_ raw: String) -> Result<String, AgentToolFailure> {
        let resolved = AgentPathPolicy.resolve(raw, in: profile.directory, home: home)
        // A file not yet there has no link to follow; its folder does.
        let folder = Self.resolvingLinks((resolved as NSString).deletingLastPathComponent)
        let path = (folder as NSString).appendingPathComponent((resolved as NSString).lastPathComponent)
        var profile = profile
        profile.directory = Self.resolvingLinks(profile.directory)
        switch AgentPathPolicy.writable(path, profile: profile) {
        case .allowed(let allowed): return .success(allowed)
        case .refused(let reason): return .failure(.init(reason))
        }
    }

    private static func resolvingLinks(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    // MARK: - Text

    private static func tail(_ text: String, keepingHead: Bool) -> String {
        guard text.utf8.count > maxOutputBytes else { return text }
        if keepingHead {
            return AgentContext.capped(text, to: maxOutputBytes)
        }
        var kept = String.UnicodeScalarView()
        var used = 0
        for scalar in text.unicodeScalars.reversed() {
            used += String(scalar).utf8.count
            guard used <= maxOutputBytes - 64 else { break }
            kept.append(scalar)
        }
        return "[Earlier output cut.]\n" + String(String.UnicodeScalarView(kept.reversed()))
    }

    /// Lines with their numbers from `offset`, within the output cap, and where to continue.
    private static func numbered(
        _ text: String, path: String, _ arguments: [String: JSONValue], as label: String? = nil
    ) -> Result<String, AgentToolFailure> {
        let lines = text.components(separatedBy: "\n")
        let offset = max(1, integer(arguments["offset"]) ?? 1)
        let limit = min(maxLines, max(1, integer(arguments["limit"]) ?? maxLines))
        guard offset <= lines.count else {
            return .failure(.init("\(path) has \(lines.count) lines; offset \(offset) is past the end."))
        }
        var output = label.map { "\(path) (\($0)):\n" } ?? ""
        var line = offset
        while line < min(lines.count + 1, offset + limit) {
            let next = String(format: "%6d\t", line) + lines[line - 1] + "\n"
            guard output.utf8.count + next.utf8.count <= maxOutputBytes - 128 else { break }
            output += next
            line += 1
        }
        if line <= lines.count {
            output += "… \(lines.count - line + 1) more lines; continue with offset \(line)."
        }
        return .success(output)
    }

    /// A whole number however the model wrote it; anything else, or out of range, is nil.
    private static func integer(_ value: JSONValue?) -> Int? {
        switch value {
        case .number(let number)?: number.isFinite && abs(number) < 1e9 ? Int(number) : nil
        case .string(let text)?: Int(text.trimmingCharacters(in: .whitespaces))
        default: nil
        }
    }

    /// A saved page as the web tools read one, its links resolved against the file.
    private static func markdown(_ html: String, of path: String) -> String {
        let page = WebPageMarkdown.page(from: html, base: URL(fileURLWithPath: path))
        let body = WebPageParts(page, partBytes: .max / 4).part(1)?.text ?? ""
        return page.title.isEmpty ? body : "# " + page.title + "\n\n" + body
    }

    private static func preview(_ text: String) -> String {
        text.count <= 600 ? text : String(text.prefix(600)) + "…"
    }

    private static func withoutEscapes(_ text: String) -> String {
        text.replacingOccurrences(
            of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]|\u{1B}\\][^\u{07}]*\u{07}|\r", with: "",
            options: .regularExpression)
    }
}

struct AgentToolFailure: Error, Sendable {
    let message: String

    init(_ message: String) { self.message = message }

    static func missing(_ argument: String) -> Self { .init("The \(argument) argument is required.") }
    static let declined = Self("The user declined this. Ask what they would like instead.")
}

/// A short child process for read-only helpers; no shell, so a pattern is never interpreted.
nonisolated enum AgentProcess {
    struct Result: Sendable {
        let status: Int32
        let output: String
    }

    static func run(_ executable: String, arguments: [String], timeout: Int) async -> Result {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.standardInput = FileHandle.nullDevice
            let exit: ProcessExit
            do {
                exit = try process.runObservingExit()
            } catch {
                continuation.resume(returning: Result(status: -1, output: error.localizedDescription))
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(timeout)) {
                if process.isRunning { process.terminate() }
            }
            DispatchQueue.global().async {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                exit.wait()
                continuation.resume(
                    returning: Result(
                        status: process.terminationStatus,
                        output: String(bytes: data, encoding: .utf8) ?? ""))
            }
        }
    }
}
