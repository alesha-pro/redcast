import Foundation
import Synchronization

/// Reads a document through the bundled text helper, one child per read, gone when it answers.
nonisolated struct DocumentTextService: Sendable {
    /// Model-facing, like every other tool failure.
    struct Failure: Error, Equatable, Sendable {
        let message: String
    }

    let executable: URL
    var timeout: Duration = .seconds(60)

    /// The clipboard's helper, which also answers `DocumentTextRequest`'s command.
    static let bundled = DocumentTextService(
        executable: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/ClipboardTextHelper"))

    private static let readSize = 65_536
    /// The read loop and the exit wait block, so they stay off the cooperative pool.
    private static let queue = DispatchQueue(
        label: "com.tinycast.document-text", qos: .userInitiated, attributes: .concurrent)

    func read(_ request: DocumentTextRequest) async -> Result<DocumentText, Failure> {
        let name = (request.path as NSString).lastPathComponent
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            return .failure(Failure(message: "The document reader is missing, so \(name) cannot be read."))
        }
        guard !Task.isCancelled else { return .failure(Failure(message: "The read of \(name) was stopped.")) }
        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = request.arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard let exit = try? process.runObservingExit() else {
            return .failure(Failure(message: "The document reader could not start for \(name)."))
        }
        let timedOut = Flag()
        let deadline = Task.detached { [timeout] in
            do { try await Task.sleep(for: timeout) } catch { return }
            timedOut.set()
            if process.isRunning { process.terminate() }
        }
        // JSON escapes newlines and quotes, so twice the text plus room for its frame.
        let limit = request.budget * 2 + 65_536
        let data = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                Self.queue.async {
                    continuation.resume(returning: Self.collect(process, exit: exit, output: output, limit: limit))
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
        deadline.cancel()
        if Task.isCancelled { return .failure(Failure(message: "The read of \(name) was stopped.")) }
        if timedOut.isSet {
            return .failure(Failure(message: "Reading \(name) took longer than \(timeout.components.seconds) s and was stopped."))
        }
        guard process.terminationStatus == 0, let data,
            let text = try? JSONDecoder().decode(DocumentText.self, from: data)
        else {
            return .failure(Failure(message: "\(name) could not be read as a \(Self.label(request.kind))."))
        }
        return .success(text)
    }

    static func label(_ kind: DocumentKind) -> String {
        switch kind {
        case .pdf: "PDF"
        case .image: "image"
        case .richText: "document"
        case .text, .html, .binary: "file"
        }
    }

    /// Blocking throughout, and the only place a helper is reaped; nil past the limit.
    private static func collect(_ process: Process, exit: ProcessExit, output: Pipe, limit: Int) -> Data? {
        let reader = output.fileHandleForReading
        defer {
            if process.isRunning { process.terminate() }
            exit.wait()
            try? reader.close()
        }
        var data = Data()
        do {
            while let chunk = try reader.read(upToCount: readSize), !chunk.isEmpty {
                data.append(chunk)
                if data.count > limit { return nil }
            }
        } catch {
            return nil
        }
        return data
    }
}

/// Set once from the deadline's task, read after the child is reaped.
private final class Flag: Sendable {
    private let state = Mutex(false)

    var isSet: Bool { state.withLock { $0 } }

    func set() { state.withLock { $0 = true } }
}
