import Foundation

/// One Responses request on the ChatGPT plan; the token comes from the accounts, never a key.
struct CodexPlanProvider: AIProvider {
    let model: String
    let effort: String?
    let reasons: Bool
    let replay: AIConnection.ReasoningReplay?
    /// Hands back a token, refreshed first when it is expired or was just refused.
    let token: @Sendable @MainActor (_ rejected: String?) async throws -> String
    /// The snapshot a reply's headers or events carried, kept for Settings to show.
    let record: @Sendable @MainActor (CodexPlanLimits) -> Void

    func stream(_ request: AIRequest) -> AIProviderStream {
        AIProviderStream { continuation in
            // Detached on purpose: the byte loop and JSON decoding never touch the main actor.
            let task = Task.detached {
                let session = CodexPlanHTTP.session()
                defer { session.invalidateAndCancel() }
                var secrets: [String] = []
                do {
                    let body = try JSONSerialization.data(
                        withJSONObject: CodexPlanRequestBody.make(
                            request, model: model, effort: effort, reasons: reasons, replay: replay))
                    var access = try await token(nil)
                    secrets.append(access)
                    var (bytes, response) = try await open(session, body: body, token: access)
                    if response.statusCode == 401 {
                        access = try await token(access)
                        secrets.append(access)
                        (bytes, response) = try await open(session, body: body, token: access)
                    }
                    let limits = CodexPlanLimits.parse(headers: Self.headers(of: response), now: Date())
                    if let limits { await record(limits) }
                    guard response.statusCode == 200 else {
                        let data = await Self.body(of: bytes)
                        try Task.checkCancellation()
                        throw Self.failure(
                            status: response.statusCode, body: data, limits: limits, secrets: secrets,
                            retryAfter: response.value(forHTTPHeaderField: "Retry-After"))
                    }
                    var decoder = CodexPlanStreamDecoder(model: model)
                    do {
                        try await Self.decode(bytes, with: &decoder, into: continuation)
                    } catch CodexPlanStreamDecoder.Failure.failed(let detail, let beforeAnswer) {
                        throw Self.failure(
                            CodexPlanFailure.classify(status: nil, detail: detail, limits: limits),
                            retryable: beforeAnswer)
                    }
                    if let streamed = decoder.limits { await record(streamed) }
                    guard decoder.isTerminal else {
                        throw AIProviderRecoverableError(
                            kind: .transient(retryAfter: nil),
                            message: String(localized: "The connection closed before the response completed."))
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch let error as URLError {
                    guard error.code != .cancelled, !Task.isCancelled else { return continuation.finish() }
                    continuation.finish(
                        throwing: AIProviderRecoverableError(
                            kind: .transient(retryAfter: nil),
                            message: String(localized: "The provider could not be reached.")))
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func open(
        _ session: URLSession, body: Data, token: String
    ) async throws -> (URLSession.AsyncBytes, HTTPURLResponse) {
        var request = URLRequest(url: CodexPlanCatalog.responsesEndpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw AIProviderError.responseFailed(
                String(localized: "The provider returned an invalid HTTP response."))
        }
        return (bytes, response)
    }

    /// Per line, not per chunk: a short reply must show before the stream closes.
    private static func decode(
        _ bytes: URLSession.AsyncBytes, with decoder: inout CodexPlanStreamDecoder,
        into continuation: AIProviderStream.Continuation
    ) async throws {
        var chunk = Data()
        chunk.reserveCapacity(2_048)
        for try await byte in bytes {
            try Task.checkCancellation()
            chunk.append(byte)
            guard byte == 0x0A else { continue }
            for event in try decoder.feed(chunk) { continuation.yield(event) }
            chunk.removeAll(keepingCapacity: true)
            if decoder.isTerminal { return }
        }
        if !chunk.isEmpty { for event in try decoder.feed(chunk) { continuation.yield(event) } }
        if !decoder.isTerminal { for event in try decoder.finish() { continuation.yield(event) } }
    }

    private static func failure(
        status: Int, body: Data, limits: CodexPlanLimits?, secrets: [String], retryAfter: String?
    ) -> Error {
        let detail = CodexPlanFailure.detail(in: JSONValue(data: body))
        let failure = CodexPlanFailure.classify(status: status, detail: detail, limits: limits)
        guard case .other = failure else { return Self.failure(failure, retryable: true) }
        let message = AIProviderFailure.description(
            status: status, body: body, retryAfter: retryAfter, secrets: secrets)
        if let recoverable = AIProviderFailure.recoverable(
            status: status, body: body, retryAfter: retryAfter, message: message)
        {
            return recoverable
        }
        return AIProviderError.responseFailed(message)
    }

    private static func failure(_ failure: CodexPlanFailure, retryable: Bool) -> Error {
        let message = failure.message(now: Date())
        if failure.isTransient, retryable {
            return AIProviderRecoverableError(kind: .transient(retryAfter: nil), message: message)
        }
        if case .other(let said) = failure, said.isEmpty {
            return AIProviderError.responseFailed(String(localized: "The provider stopped the response with an error."))
        }
        return AIProviderError.responseFailed(message)
    }

    private static func headers(of response: HTTPURLResponse) -> [String: String] {
        var headers: [String: String] = [:]
        for (name, value) in response.allHeaderFields {
            if let name = name as? String, let value = value as? String { headers[name] = value }
        }
        return headers
    }

    private static let bodyWait: Duration = .seconds(5)

    /// What arrived by the end, the cap or the wait; a broken-off body still leaves the status.
    private static func body(of bytes: URLSession.AsyncBytes) async -> Data {
        await withTaskGroup(of: Data?.self) { group in
            group.addTask {
                var body = Data()
                var iterator = bytes.makeAsyncIterator()
                while body.count < AIProviderFailure.bodyLimit, let byte = try? await iterator.next() {
                    body.append(byte)
                }
                return body
            }
            group.addTask {
                try? await Task.sleep(for: bodyWait)
                return nil
            }
            var body = Data()
            for await read in group {
                if let read { body = read }
                group.cancelAll()
            }
            return body
        }
    }
}
