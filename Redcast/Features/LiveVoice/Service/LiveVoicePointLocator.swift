import Foundation

/// Finds a described target in a screenshot with one request to an OpenAI-compatible endpoint.
struct LiveVoicePointLocator: Sendable {
    let key: String
    var model = LiveVoicePointLocator.defaultModel
    var endpoint = LiveVoicePointLocator.openRouter
    var headers: [String: String] = [:]

    /// The fastest model measured that still lands within a few points of a button.
    static let defaultModel = "google/gemini-3.1-flash-lite"
    static let openRouter =
        URL(string: "https://openrouter.ai/api/v1/chat/completions") ?? URL(fileURLWithPath: "/")
    private static let timeout: TimeInterval = 15

    func locate(_ jpeg: Data, _ target: String) async -> LiveVoicePoint? {
        var request = URLRequest(url: endpoint, timeoutInterval: Self.timeout)
        request.httpMethod = "POST"
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = LiveVoicePointRequest.body(model: model, jpeg: jpeg, target: target)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        guard let (reply, response) = try? await session.data(for: request),
            (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return LiveVoicePointRequest.point(in: reply)
    }
}
