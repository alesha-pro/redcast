import AppKit
import Foundation

/// Extension AI's app side: the gate's wiring, its consent dialog and the Settings actions.
@MainActor
final class ExtensionAICoordinator {
    private unowned let core: AppCore
    private(set) lazy var gate = ExtensionAIGate(
        aiSettings: core.aiSettings,
        aiEnabled: { [unowned core] in core.settings.aiEnabled },
        ask: { [unowned self] name in await askConsent(for: name) },
        makeProvider: { [unowned core] selection in
            UsageRecordingProvider.wrapping(
                try AIProviderFactory.make(
                    selection: selection, settings: core.aiSettings,
                    subscription: core.chatGPTSubscription, installedAI: core.installedAI),
                for: selection, as: .extensionAI)
        })

    var settings: ExtensionAISettingsStore { gate.settings }

    init(core: AppCore) {
        self.core = core
    }

    // MARK: - Settings

    func setEnabled(_ enabled: Bool) {
        gate.setEnabled(enabled)
    }

    func repairModel() {
        guard let model = settings.model,
            ExtensionAIPolicy.isDangling(model, connections: core.aiSettings.connections)
        else { return }
        settings.select(nil)
    }

    func forget(entryIDs: [String]) {
        settings.forget(Set(entryIDs.compactMap { ExtensionCommandRef(entryID: $0)?.extensionName }))
    }

    func modelTitle() -> String {
        let chat = core.aiChatCoordinator
        return chat.modelTitle(of: gate.selection(), among: chat.modelOptions)
    }

    // MARK: - Asking

    /// Behind another dialog it would resolve unseen as a cancel, so it is not shown at all.
    private func askConsent(for name: String) async -> Bool? {
        guard !core.isShowingDialog else { return nil }
        let title = core.extensions.installed.first { $0.manifest.name == name }?.title ?? name
        NSApp.activate(ignoringOtherApps: true)
        let answer = await core.choose(
            title: String(localized: "Allow \u{201C}\(title)\u{201D} to use AI?"),
            message: String(
                localized: """
                    Its prompts go to \(modelTitle()) and can include text the extension reads, such \
                    as your selection or clipboard. You can change this in Settings \u{2192} Extensions.
                    """),
            symbol: "sparkles",
            options: [
                DialogAction(title: String(localized: "Allow")),
                DialogAction(title: String(localized: "Don't Allow")),
                DialogAction(title: String(localized: "Not Now"), role: .cancel)
            ], defaultIndex: 0)
        return switch answer {
        case 0: true
        case 1: false
        default: nil
        }
    }
}
