import Foundation

/// `GET /v1/models` with the plan's token: Codex's `ModelInfo` list, or the public API's `data`.
enum CodexPlanCatalog {
    static let endpoint = URL(string: "https://api.openai.com/v1/models")!
    static let responsesEndpoint = URL(string: "https://api.openai.com/v1/responses")!

    struct Model: Equatable, Sendable {
        let id: String
        let name: String
        let efforts: [String]
        let defaultEffort: String?
    }

    static func parse(_ data: Data) -> [Model]? {
        guard let json = JSONValue(data: data)?.objectValue else { return nil }
        if let listed = json["models"]?.arrayValue {
            return listed.compactMap { value -> (Model, Int)? in
                guard let raw = value.objectValue, let slug = raw["slug"]?.stringValue, !slug.isEmpty,
                    (raw["visibility"]?.stringValue ?? "list") == "list"
                else { return nil }
                let efforts = (raw["supported_reasoning_levels"]?.arrayValue ?? []).compactMap {
                    $0.objectValue?["effort"]?.stringValue ?? $0.stringValue
                }
                let model = Model(
                    id: slug, name: raw["display_name"]?.stringValue ?? slug, efforts: efforts,
                    defaultEffort: raw["default_reasoning_level"]?.stringValue)
                return (model, raw["priority"]?.intValue ?? Int.max)
            }
            .enumerated().sorted { ($0.element.1, $0.offset) < ($1.element.1, $1.offset) }
            .map(\.element.0)
        }
        guard let data = json["data"]?.arrayValue else { return nil }
        return data.compactMap { value in
            guard let id = value.objectValue?["id"]?.stringValue, !id.isEmpty else { return nil }
            return Model(id: id, name: id, efforts: [], defaultEffort: nil)
        }
    }

    /// What a connection keeps of a catalog: the ids in order, and each model's own levels.
    static func apply(_ models: [Model], to connection: inout AIConnection) {
        connection.models = models.map(\.id)
        var options: [String: AIConnection.ReasoningOptions] = [:]
        for model in models where !model.efforts.isEmpty {
            options[model.id] = AIConnection.ReasoningOptions(
                efforts: model.efforts, defaultEffort: model.defaultEffort)
        }
        connection.reasoningOptions = options.isEmpty ? nil : options
    }
}
