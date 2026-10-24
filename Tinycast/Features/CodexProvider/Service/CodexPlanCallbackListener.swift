import Foundation
import Network

/// The one-shot loopback callback: open only from Continue with ChatGPT until it answers or stops.
@MainActor
final class CodexPlanCallbackListener {
    private var task: Task<Void, Never>?
    private var ready: CheckedContinuation<Void, Error>?
    private var reply: CheckedContinuation<CodexPlanOAuth.Callback, Error>?
    private var result: Result<CodexPlanOAuth.Callback, Error>?
    private var accepted = false

    isolated deinit { task?.cancel() }

    func start(state: String, timeout: Duration = .seconds(300)) async throws {
        guard result == nil else { throw CancellationError() }
        let listener = try NetworkListener(
            using: .parameters { TCP() }
                .localEndpoint(
                    .hostPort(host: .ipv4(.loopback), port: .init(integerLiteral: CodexPlanOAuth.callbackPort))))
        listener.newConnectionLimit = 16
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                ready = continuation
                task = Task { [weak self] in
                    do {
                        try await withThrowingTaskGroup(of: Void.self) { group in
                            group.addTask { [weak self] in try await self?.run(listener, state: state) }
                            group.addTask {
                                try await Task.sleep(for: timeout)
                                throw CodexPlanOAuth.Failure.timedOut
                            }
                            defer { group.cancelAll() }
                            _ = try await group.next()
                        }
                    } catch {
                        self?.finish(.failure(error))
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }

    func callback() async throws -> CodexPlanOAuth.Callback {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            if let result { return try result.get() }
            return try await withCheckedThrowingContinuation { reply = $0 }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }

    func cancel() { finish(.failure(CancellationError())) }

    private func finish(_ outcome: Result<CodexPlanOAuth.Callback, Error>) {
        guard result == nil else { return }
        result = outcome
        if case .failure(let error) = outcome {
            ready?.resume(throwing: error)
        } else {
            ready?.resume(throwing: CancellationError())
        }
        ready = nil
        reply?.resume(with: outcome)
        reply = nil
        task?.cancel()
        task = nil
    }

    private func run(_ listener: NetworkListener<TCP>, state: String) async throws {
        try await listener.onStateUpdate { [weak self] _, status in
            switch status {
            case .ready:
                self?.ready?.resume()
                self?.ready = nil
            case .waiting, .failed:
                self?.finish(.failure(CodexPlanOAuth.Failure.listenerUnavailable))
            default: break
            }
        }.run { [weak self] connection in
            await self?.receive(connection, state: state)
        }
    }

    private func receive(_ connection: NetworkConnection<TCP>, state: String) async {
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { [weak self] in try await self?.read(connection, state: state) }
                group.addTask { try await Task.sleep(for: .seconds(5)) }
                defer { group.cancelAll() }
                _ = try await group.next()
            }
        } catch { return }
    }

    private func read(_ connection: NetworkConnection<TCP>, state: String) async throws {
        var bytes = Data()
        while bytes.count < 8192 {
            let message = try await connection.receive(atLeast: 1, atMost: 8192 - bytes.count)
            bytes.append(message.content)
            if bytes.range(of: Data("\r\n\r\n".utf8)) != nil { break }
            if message.metadata.endOfStream { return }
        }
        guard !accepted, let request = String(bytes: bytes, encoding: .utf8),
            request.contains("\r\n\r\n")
        else { return }
        let parts = (request.components(separatedBy: "\r\n").first ?? "").split(separator: " ")
        var outcome: Result<CodexPlanOAuth.Callback, Error>?
        if parts.count == 3, parts[0] == "GET" {
            do {
                outcome = .success(try CodexPlanOAuth.callback(String(parts[1]), state: state))
            } catch CodexPlanOAuth.Failure.denied {
                outcome = .failure(CodexPlanOAuth.Failure.denied)
            } catch { outcome = nil }
        }
        let page =
            outcome == nil
            ? String(localized: "Invalid sign-in response.")
            : String(localized: "Return to Tinycast. You can close this tab.")
        let response =
            "HTTP/1.1 \(outcome == nil ? "400 Bad Request" : "200 OK")\r\n"
            + "Content-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\n"
            + "Content-Security-Policy: default-src 'none'\r\nConnection: close\r\n"
            + "Content-Length: \(page.utf8.count)\r\n\r\n\(page)"
        if outcome != nil { accepted = true }
        do {
            try await connection.send(Data(response.utf8), endOfStream: true)
        } catch {
            if let outcome { finish(outcome) }
            throw error
        }
        if let outcome { finish(outcome) }
    }
}
