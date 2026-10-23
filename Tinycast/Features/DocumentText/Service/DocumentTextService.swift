import Darwin
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
    /// A helper past this footprint is ended, so no document built to inflate presses the whole Mac.
    var memoryLimit: UInt64 = 1 << 30

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
        // Foundation raises rather than throws on a NUL, which would end the app, not the read.
        guard !request.arguments.contains(where: { $0.utf8.contains(0) }) else {
            return .failure(Failure(message: "\(name) cannot be read: its path holds a NUL character."))
        }
        if request.kind == .richText, ["docx", "odt"].contains((request.path as NSString).pathExtension.lowercased()),
            Self.archive(at: request.path) == .tooLarge
        {
            return .failure(Failure(message: "\(name) unpacks to more than a read can hold, so it was not opened."))
        }
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
        let swollen = Flag()
        // Lives only as long as this read; it watches the child's memory as well as its time.
        let deadline = Task.detached { [timeout, memoryLimit] in
            let end = ContinuousClock.now + timeout
            while ContinuousClock.now < end {
                do { try await Task.sleep(for: min(.milliseconds(250), end - ContinuousClock.now)) } catch { return }
                guard Self.footprint(of: process.processIdentifier) > memoryLimit else { continue }
                swollen.set()
                if process.isRunning { process.terminate() }
                return
            }
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
        if swollen.isSet {
            return .failure(Failure(message: "Reading \(name) needed more than \(memoryLimit >> 20) MB and was stopped."))
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

    /// A ZIP by its last bytes and its directory; nothing else of it is read.
    static func archive(at path: String) -> DocumentArchive.Verdict {
        guard let handle = FileHandle(forReadingAtPath: path) else { return .notArchive }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return .notArchive }
        let tailStart = end > DocumentArchive.tailBytes ? end - DocumentArchive.tailBytes : 0
        guard (try? handle.seek(toOffset: tailStart)) != nil,
            let tail = try? handle.read(upToCount: Int(end - tailStart))
        else { return .notArchive }
        return DocumentArchive.verdict(tail: tail, fileSize: end) { offset, size in
            guard (try? handle.seek(toOffset: offset)) != nil else { return nil }
            return try? handle.read(upToCount: size)
        }
    }

    /// The child's physical footprint, as Activity Monitor counts it; 0 once it is gone.
    private static func footprint(of pid: pid_t) -> UInt64 {
        var info = rusage_info_v2()
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
        }
        return status == 0 ? info.ri_phys_footprint : 0
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
