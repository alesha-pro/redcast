import Foundation

/// Passes a reply through untouched and logs the usage it reported once its stream ends.
struct UsageRecordingProvider: AIProvider {
    let base: any AIProvider
    let origin: UsageLedgerEntry.Origin
    let selection: AIModelSelection
    let ledger: URL

    /// Apple Intelligence reports nothing, and `QuickActionRunner` caps it by testing its type.
    static func wrapping(
        _ provider: any AIProvider, for selection: AIModelSelection,
        as origin: UsageLedgerEntry.Origin, ledger: URL = UsageLedger.url
    ) -> any AIProvider {
        if case .appleIntelligence = selection { return provider }
        return UsageRecordingProvider(base: provider, origin: origin, selection: selection, ledger: ledger)
    }

    func stream(_ request: AIRequest) -> AIProviderStream {
        AIProviderStream { continuation in
            let task = Task.detached {
                var reported: AIUsage?
                do {
                    for try await event in base.stream(request) {
                        if case .usage(let usage) = event { reported = usage }
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
                // A reply stopped after its usage arrived was still billed, so it is logged too.
                guard let reported else { return }
                UsageLedger.append(
                    UsageLedgerEntry(at: Date(), origin: origin, selection: selection, usage: reported),
                    to: ledger)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
