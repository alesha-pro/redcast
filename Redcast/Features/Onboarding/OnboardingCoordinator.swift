import SwiftUI

@MainActor
final class OnboardingCoordinator {
    private let window: AppWindowController
    /// Environment injection only — never for state this type owns.
    private unowned let core: AppCore

    init(core: AppCore) {
        self.core = core
        window = AppWindowController(
            title: String(localized: "Welcome to Redcast"), contentSize: OnboardingView.initialSize,
            activation: nil)
    }

    /// The window takes the height the current step measured, so no step is clipped or padded out.
    func fit(height: CGFloat, animation duration: TimeInterval?) {
        window.fitContent(width: OnboardingView.width, height: height, animation: duration)
    }

    func showOnboarding() {
        window.show {
            OnboardingView()
                .environment(self.core)
                .environment(self.core.settings)
                .environment(self.core.hotKeys)
        }
    }

    func finishOnboarding() {
        window.close()
        core.paletteCoordinator.showPalette(mode: .launcher)
    }

    func focusExisting() -> Bool {
        window.focus()
    }
}
