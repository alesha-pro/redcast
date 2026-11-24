import Foundation

/// One WebSocket to a live voice provider, on a private session that keeps nothing on disk.
final class LiveVoiceConnection: Sendable {
    private let session: URLSession
    private let task: URLSessionWebSocketTask
    private let outbox: AsyncStream<String>.Continuation
    private let pump: Task<Void, Never>

    /// A screenshot is a single frame of a megabyte or more once it is base64.
    private static let maximumMessageSize = 32 * 1024 * 1024

    init(_ request: URLRequest) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = Self.maximumMessageSize
        let (stream, continuation) = AsyncStream<String>.makeStream()
        self.session = session
        self.task = task
        outbox = continuation
        // One sender keeps audio chunks in the order the microphone produced them.
        pump = Task.detached {
            for await text in stream {
                guard (try? await task.send(.string(text))) != nil else { return }
            }
        }
        task.resume()
    }

    /// Never blocks, so the audio thread can call it.
    func send(_ text: String) {
        outbox.yield(text)
    }

    func send(_ texts: [String]) {
        texts.forEach(send)
    }

    /// Every message until the socket closes; the stream then ends, throwing what closed it.
    func messages() -> AsyncThrowingStream<Data, Error> {
        let task = task
        return AsyncThrowingStream { continuation in
            let reader = Task.detached {
                do {
                    while !Task.isCancelled {
                        switch try await task.receive() {
                        case .data(let data): continuation.yield(data)
                        case .string(let text): continuation.yield(Data(text.utf8))
                        @unknown default: break
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in reader.cancel() }
        }
    }

    func close() {
        outbox.finish()
        pump.cancel()
        task.cancel(with: .normalClosure, reason: nil)
        session.invalidateAndCancel()
    }
}
