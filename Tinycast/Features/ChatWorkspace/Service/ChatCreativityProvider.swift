import Foundation

/// Fork: a chat's Creativity on every request its route sends, tool rounds included.
struct ChatCreativityProvider: AIProvider {
    let base: any AIProvider
    let temperature: Double

    /// Nil leaves the route exactly as it was.
    static func wrapping(_ base: any AIProvider, temperature: Double?) -> any AIProvider {
        guard let temperature else { return base }
        return ChatCreativityProvider(base: base, temperature: temperature)
    }

    /// A model that refuses a temperature says so before it says anything else; it is asked again.
    func stream(_ request: AIRequest) -> AIProviderStream {
        let base = base
        let warmed = request.withTemperature(temperature)
        return AIProviderStream { continuation in
            let task = Task {
                var answered = false
                do {
                    for try await event in base.stream(warmed) {
                        answered = true
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    guard !answered, !Task.isCancelled,
                        error.localizedDescription.localizedCaseInsensitiveContains("temperature")
                    else {
                        continuation.finish(throwing: error)
                        return
                    }
                    do {
                        for try await event in base.stream(request) { continuation.yield(event) }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
