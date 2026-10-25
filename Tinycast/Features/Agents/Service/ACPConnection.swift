import Darwin
import Foundation

/// One running ACP agent process: JSON-RPC over its stdio, the agent's questions routed out.
@MainActor
final class ACPConnection {
    struct Capabilities: Equatable, Sendable {
        var loadSession = false
        var prompt = ACPPrompt.Capabilities()
        var mcpHTTP = false
    }

    enum ConnectionError: LocalizedError, Equatable {
        case notFound(String)
        case launchFailed(String)
        case exited(String)
        case requestFailed(String)
        case timedOut

        var errorDescription: String? {
            switch self {
            case .notFound(let command):
                String(localized: "Tinycast couldn't find \(command). Install it, or give its full path in the agent's settings.")
            case .launchFailed(let reason), .exited(let reason), .requestFailed(let reason):
                reason
            case .timedOut:
                String(localized: "The agent didn't answer in time.")
            }
        }
    }

    let runtime: AgentRuntime
    let directory: String
    private(set) var capabilities = Capabilities()
    private(set) var agentTitle: String?

    /// A session's update; the session id says whose turn it belongs to.
    var onUpdate: ((String, ACPUpdate) -> Void)?
    /// Nil answers the request as cancelled.
    var onPermission: ((ACPPermissionRequest) async -> String?)?
    var onExit: ((String) -> Void)?

    private var process: Process?
    private var input: FileHandle?
    private var outputBuffer = Data()
    private var stderrBuffer = Data()
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var permissions: [ACPProtocol.RequestID: (sessionID: String, task: Task<Void, Never>)] = [:]
    /// The agent's children, read while they still hang off it; an exit orphans them to launchd.
    private var lastTree: [ProcessTree.Member] = []

    /// The first launch of an `npx` adapter downloads it, which can take a minute or more.
    private static let initializeTimeout: Duration = .seconds(240)
    private static let outputLimit = 16 * 1_048_576

    init(runtime: AgentRuntime, directory: String) {
        self.runtime = runtime
        self.directory = directory
    }

    var isRunning: Bool { process?.isRunning == true }

    func start() async throws {
        guard !isRunning else { return }
        let executable = try await resolveExecutable()
        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = executable
        process.arguments = runtime.arguments
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory),
            isDirectory.boolValue
        {
            process.currentDirectoryURL = URL(fileURLWithPath: directory)
        }
        process.environment = ExecutableLocator.environment(running: executable)
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor in self?.consumeOutput(data) }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor in self?.consumeStderr(data) }
        }
        process.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            Task { @MainActor in self?.didExit(process, status: status) }
        }
        do {
            try process.run()
        } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            throw ConnectionError.launchFailed(error.localizedDescription)
        }
        self.process = process
        // An agent that dies mid-write must fail the write, not SIGPIPE Tinycast.
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        input = stdin.fileHandleForWriting
        do {
            let result = try await request(
                "initialize",
                params: [
                    "protocolVersion": ACPProtocol.version,
                    "clientCapabilities": [
                        "fs": ["readTextFile": false, "writeTextFile": false], "terminal": false
                    ],
                    "clientInfo": [
                        "name": "tinycast", "title": "Redcast",
                        "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"]
                            as? String ?? "0"
                    ]
                ], timeout: Self.initializeTimeout)
            adopt(result)
        } catch {
            stop()
            throw error
        }
    }

    /// Nil timeout for a prompt turn, which lasts as long as the agent works.
    func request(
        _ method: String, params: [String: Any], timeout: Duration? = .seconds(60)
    ) async throws -> JSONValue {
        guard isRunning else { throw ConnectionError.exited(exitMessage) }
        let id = nextID
        nextID += 1
        let watchdog = timeout.map { timeout in
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled else { return }
                self?.finish(id, with: .failure(ConnectionError.timedOut))
            }
        }
        defer { watchdog?.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                do {
                    try send(ACPProtocol.request(id: id, method: method, params: params))
                } catch {
                    finish(id, with: .failure(error))
                }
            }
        } onCancel: { [weak self] in
            Task { @MainActor in self?.finish(id, with: .failure(CancellationError())) }
        }
    }

    /// A live session moved to one of an option's values; the answer may carry the whole new list.
    func set(_ value: String, for option: ACPConfigOption, sessionID: String) async throws -> JSONValue {
        let call = option.request(setting: value, session: sessionID)
        return try await request(call.method, params: call.params)
    }

    func notify(_ method: String, params: [String: Any]) {
        try? send(ACPProtocol.notification(method: method, params: params))
    }

    /// Stop on a turn: the agent is told, and its open questions are answered as cancelled.
    func cancel(sessionID: String) {
        notify("session/cancel", params: ["sessionId": sessionID])
        for (id, entry) in permissions where entry.sessionID == sessionID {
            entry.task.cancel()
            permissions[id] = nil
            try? send(ACPProtocol.response(id: id, result: ACPPermissionRequest.result(selecting: nil)))
        }
    }

    /// Re-read after each turn, so an agent that later exits on its own leaves nothing behind.
    func rememberTree() {
        guard let process, process.isRunning else { return }
        lastTree = ProcessTree.members(under: process.processIdentifier)
    }

    /// Closing stdin is the polite exit; then the whole tree gets SIGTERM, and SIGKILL after that.
    func stop() {
        guard let process else { return }
        let tree = ProcessTree.members(under: process.processIdentifier) + lastTree
        process.terminationHandler = nil
        cleanup(error: ConnectionError.exited(String(localized: "The agent stopped.")))
        ProcessTree.reap(tree, root: process)
    }

    // MARK: - Private

    private func resolveExecutable() async throws -> URL {
        let command = runtime.command.trimmingCharacters(in: .whitespaces)
        guard !command.isEmpty else { throw ConnectionError.notFound(runtime.kind.title) }
        if command.hasPrefix("/") || command.hasPrefix("~") {
            let url = URL(fileURLWithPath: (command as NSString).expandingTildeInPath)
            guard FileManager.default.isExecutableFile(atPath: url.path) else {
                throw ConnectionError.notFound(command)
            }
            return url
        }
        guard let url = await ExecutableLocator.locate(command) else {
            throw ConnectionError.notFound(command)
        }
        return url
    }

    private func adopt(_ result: JSONValue) {
        let object = result.objectValue ?? [:]
        let agent = object["agentCapabilities"]?.objectValue ?? [:]
        let prompt = agent["promptCapabilities"]?.objectValue ?? [:]
        capabilities = Capabilities(
            loadSession: agent["loadSession"]?.boolValue ?? false,
            prompt: ACPPrompt.Capabilities(
                image: prompt["image"]?.boolValue ?? false,
                embeddedContext: prompt["embeddedContext"]?.boolValue ?? false),
            mcpHTTP: agent["mcpCapabilities"]?.objectValue?["http"]?.boolValue ?? false)
        let info = object["agentInfo"]?.objectValue
        agentTitle = info?["title"]?.stringValue ?? info?["name"]?.stringValue
    }

    private func send(_ data: Data) throws {
        guard let input else { throw ConnectionError.exited(exitMessage) }
        try input.write(contentsOf: data)
    }

    private func consumeOutput(_ data: Data) {
        outputBuffer.append(data)
        while let newline = outputBuffer.firstIndex(of: 0x0A) {
            let line = outputBuffer[..<newline]
            outputBuffer.removeSubrange(...newline)
            guard !line.isEmpty else { continue }
            handle(ACPProtocol.parse(Data(line)))
        }
        // An unterminated flood means whatever is talking is not speaking ACP.
        guard outputBuffer.count > Self.outputLimit else { return }
        let message = String(localized: "The agent sent something that isn't ACP and was disconnected.")
        onExit?(message)
        stop()
    }

    private func handle(_ message: ACPProtocol.Message) {
        switch message {
        case .response(let id, let result):
            finish(id, with: .success(result))
        case .failure(let id, _, let message):
            finish(id, with: .failure(ConnectionError.requestFailed(message)))
        case .notification(let method, let params):
            guard method == "session/update", let (sessionID, update) = ACPUpdate.decode(params)
            else { return }
            onUpdate?(sessionID, update)
        case .request(let id, let method, let params):
            guard method == "session/request_permission",
                let request = ACPPermissionRequest(params)
            else {
                // Tinycast offers no fs or terminal of its own, so the agent uses its own tools.
                try? send(
                    ACPProtocol.errorResponse(
                        id: id, code: -32601, message: "Redcast does not implement \(method)."))
                return
            }
            let ask = onPermission
            let task = Task { [weak self] in
                let choice = await ask?(request)
                guard let self, self.permissions.removeValue(forKey: id) != nil else { return }
                try? self.send(
                    ACPProtocol.response(id: id, result: ACPPermissionRequest.result(selecting: choice)))
            }
            permissions[id] = (request.sessionID, task)
        case .invalid:
            break
        }
    }

    private func consumeStderr(_ data: Data) {
        stderrBuffer.append(data)
        if stderrBuffer.count > 8_192 { stderrBuffer.removeFirst(stderrBuffer.count - 8_192) }
    }

    private var exitMessage: String {
        let detail = (String(bytes: stderrBuffer, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let tail = detail.split(separator: "\n").suffix(6).joined(separator: "\n")
        return tail.isEmpty ? String(localized: "The agent is not running.") : tail
    }

    private func finish(_ id: Int, with result: Result<JSONValue, Error>) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        continuation.resume(with: result)
    }

    private func didExit(_ exited: Process, status: Int32) {
        guard exited === process else { return }
        let message = exitMessage
        let orphans = lastTree
        onExit?(message)
        cleanup(error: ConnectionError.exited(message))
        ProcessTree.reap(orphans, root: nil)
    }

    private func cleanup(error: Error) {
        process?.terminationHandler = nil
        (process?.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        (process?.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        try? input?.close()
        process = nil
        input = nil
        lastTree = []
        outputBuffer.removeAll(keepingCapacity: false)
        for entry in permissions.values { entry.task.cancel() }
        permissions.removeAll()
        let requests = pending
        pending.removeAll()
        for continuation in requests.values { continuation.resume(throwing: error) }
    }
}
