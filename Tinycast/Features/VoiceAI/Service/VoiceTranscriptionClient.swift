import Foundation

/// One POST to `/audio/transcriptions` on a private ephemeral session, torn down after it.
struct VoiceTranscriptionClient: Sendable {
    let baseURL: URL
    let apiKey: String
    let headers: [String: String]
    /// What the usage ledger names, as for a chat route.
    let selection: AIModelSelection

    /// The transcript, or nil when nothing intelligible was heard.
    @concurrent
    func transcribe(_ request: VoiceTranscriptionRequest) async throws -> String? {
        var urlRequest = URLRequest(url: baseURL.appending(path: "audio/transcriptions"))
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 90
        urlRequest.setValue(request.contentType, forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty { urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        for (name, value) in headers { urlRequest.setValue(value, forHTTPHeaderField: name) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.upload(for: urlRequest, from: request.body())
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw AIProviderError.responseFailed(HTTPAIProvider.networkMessage(error.code))
        }
        guard let response = response as? HTTPURLResponse else {
            throw AIProviderError.responseFailed(
                String(localized: "The provider returned an invalid HTTP response."))
        }
        guard response.statusCode == 200 else {
            throw AIProviderError.responseFailed(
                AIProviderFailure.description(
                    status: response.statusCode, body: data.prefix(AIProviderFailure.bodyLimit),
                    retryAfter: response.value(forHTTPHeaderField: "Retry-After"),
                    secrets: [apiKey] + headers.values))
        }
        let decoded = try VoiceTranscriptionRequest.response(data)
        if let usage = decoded.usage {
            UsageLedger.append(UsageLedgerEntry(at: Date(), origin: .voice, selection: selection, usage: usage))
        }
        return decoded.text
    }
}
