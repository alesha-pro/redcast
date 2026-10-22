import SwiftUI

/// A voice route's connection and model; the catalog is fetched only when Choose… is clicked.
struct VoiceModelRow: View {
    let use: VoiceUse
    @Binding var selection: AIModelSelection?

    @Environment(AISettingsStore.self) private var aiSettings
    @State private var draft = ""
    @State private var catalog: [AIModelDiscovery.Model] = []
    @State private var isChoosing = false
    @State private var isLoading = false
    @State private var failure: String?

    private let discovery = AIModelDiscoveryService()

    var body: some View {
        let offered = VoiceRoutePolicy.choices(aiSettings.connections, use: use, isEnabled: isEnabled)
        let current = resolved
        Picker(selection: connectionBinding(offered)) {
            ForEach(offered) { connection in
                Text(verbatim: connection.title).tag(Optional(connection.id))
            }
        } label: {
            Text("Connection")
        }
        LabeledContent {
            HStack(spacing: Theme.Spacing.sm) {
                TextField("Model", text: $draft)
                    .labelsHidden()
                    .frame(minWidth: 200)
                if isLoading { ProgressView().controlSize(.small) }
                Button("Choose…", action: loadCatalog)
                    .disabled(current == nil || isLoading)
                    .popover(isPresented: $isChoosing, arrowEdge: .bottom) { catalogList }
            }
        } label: {
            Text("Model")
            if let failure {
                Text(failure).foregroundStyle(.orange)
            }
        }
        .onAppear { draft = current?.model ?? "" }
        .onChange(of: current?.model) { _, model in draft = model ?? "" }
        .onChange(of: draft) { commitDraft() }
        .onChange(of: isChoosing) { _, choosing in if !choosing { catalog = [] } }
    }

    private var resolved: AIModelSelection? {
        VoiceRoutePolicy.resolve(
            selection, use: use, connections: aiSettings.connections, isEnabled: isEnabled)
    }

    private var resolvedConnection: AIConnection? {
        guard case .api(let id, _, _) = resolved else { return nil }
        return aiSettings.connection(id: id)
    }

    private func isEnabled(_ id: UUID) -> Bool { aiSettings.isRouteEnabled(.api(id)) }

    private func connectionBinding(_ offered: [AIConnection]) -> Binding<UUID?> {
        Binding(
            get: { resolvedConnection?.id },
            set: { id in
                guard let connection = offered.first(where: { $0.id == id }) else { return }
                selection = VoiceRoutePolicy.initial(on: connection, use: use)
            })
    }

    /// An emptied field keeps the last model rather than saving a route that names none.
    private func commitDraft() {
        let model = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let connection = resolvedConnection, !model.isEmpty, model != resolved?.model else { return }
        selection = .api(
            connection: connection.id, model: model,
            effort: VoiceRoutePolicy.effort(forTyped: model, use: use, provider: connection.provider))
    }

    private var catalogList: some View {
        let models = VoiceRoutePolicy.audioModels(catalog)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if models.isEmpty {
                    Text("No model on this connection takes audio.")
                        .foregroundStyle(.secondary)
                        .padding(Theme.Spacing.lg)
                }
                ForEach(models) { model in
                    Button { choose(model) } label: {
                        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                            Text(verbatim: model.name)
                            Text(verbatim: model.id)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, Theme.Spacing.lg)
                    .padding(.vertical, Theme.Spacing.sm)
                }
            }
        }
        .frame(width: 340, height: 360)
    }

    private func choose(_ model: AIModelDiscovery.Model) {
        guard let connection = resolvedConnection else { return }
        isChoosing = false
        selection = .api(
            connection: connection.id, model: model.id,
            effort: VoiceRoutePolicy.fastestEffort(model.reasoningOptions?.efforts))
    }

    private func loadCatalog() {
        guard let connection = resolvedConnection else { return }
        failure = nil
        isLoading = true
        Task {
            defer { isLoading = false }
            do {
                let baseURL = try AIEndpointPolicy.validate(connection.baseURL)
                let key = try KeychainSecretStore.aiAPIKeys.secret(for: connection.id) ?? ""
                let headers = try KeychainSecretStore.aiRequestHeaders.values(for: connection.id)
                catalog = try await discovery.models(
                    provider: connection.provider, baseURL: baseURL, apiKey: key, headers: headers)
                isChoosing = true
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}
