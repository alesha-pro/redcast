import Foundation

/// `claude agents --json`, bounded by a 3 s watchdog and a 2 MB cap; its whole tree is reaped.
enum ClaudeLiveSessionsProbe {
    static let timeout: Duration = .seconds(3)
    static let outputCap = 2 * 1_048_576

    /// Output goes to a scratch file, so a child that keeps the descriptor never stalls the read.
    @concurrent static func run(
        executable: URL, home: URL, environment: [String: String] = [:]
    ) async
        -> [AgentLiveEntry]
    {
        let scratch = FileManager.default.temporaryDirectory
            .appending(path: "agent-sessions-\(UUID().uuidString).json", directoryHint: .notDirectory)
        guard FileManager.default.createFile(atPath: scratch.path, contents: nil),
            let output = try? FileHandle(forWritingTo: scratch)
        else { return [] }
        defer { try? FileManager.default.removeItem(at: scratch) }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["agents", "--json"]
        process.currentDirectoryURL = home
        process.environment = ExecutableLocator.environment(running: executable, adding: environment)
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardOutput = output
        let launched = try? process.runObservingExit()
        try? output.close()
        guard let exit = launched else { return [] }
        let stop = { @Sendable in
            guard process.isRunning else { return }
            ProcessTree.reap(ProcessTree.members(under: process.processIdentifier), root: process)
        }
        let watchdog = Task.detached {
            guard (try? await Task.sleep(for: timeout)) != nil else { return }
            stop()
        }
        await withTaskCancellationHandler {
            await Task.detached { exit.wait() }.value
        } onCancel: {
            stop()
        }
        watchdog.cancel()
        guard process.terminationStatus == 0, !Task.isCancelled,
            let handle = try? FileHandle(forReadingFrom: scratch)
        else { return [] }
        defer { try? handle.close() }
        return ClaudeAgentsListing.decode((try? handle.read(upToCount: outputCap)) ?? Data())
    }
}
