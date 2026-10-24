import Foundation

/// Fork: a custom Quick Action's own model — persisted per entry, and the default once it is gone.
@main
@MainActor
struct QuickActionModelTests {
    static var failures = 0
    static var passes = 0

    static func main() {
        aCustomActionKeepsItsModelAndEffort()
        anUnreadableEntryCostsOnlyItself()
        aRemovedConnectionFallsBackWithANote()
        aNewChoiceClearsTheNote()

        print("\(passes)/\(passes + failures) passed")
        if failures > 0 { exit(1) }
    }

    static func aCustomActionKeepsItsModelAndEffort() {
        withDefaults("QuickActionModelTests.persist") { defaults in
            let custom = QuickAction.custom(CustomQuickAction(name: "Tone", instructions: "Soften."))
            let other = QuickAction.custom(CustomQuickAction(name: "Plain", instructions: "Plain."))
            let store = QuickActionSettingsStore(defaults: defaults)
            store.select(.appleIntelligence)
            expect(store.model(for: custom) == .appleIntelligence, "no choice is the default model")
            store.setModelOverride(.claude(model: "opus", effort: "high"), for: custom)

            let reopened = QuickActionSettingsStore(defaults: defaults)
            expect(
                reopened.model(for: custom) == .claude(model: "opus", effort: "high"),
                "the action's model and reasoning effort survive a relaunch")
            expect(reopened.model(for: other) == .appleIntelligence, "another action keeps the default")
            reopened.setModelOverride(nil, for: custom)
            expect(
                QuickActionSettingsStore(defaults: defaults).modelOverride(for: custom) == nil,
                "Same as Quick Actions removes the stored route")
        }
    }

    static func anUnreadableEntryCostsOnlyItself() {
        withDefaults("QuickActionModelTests.tolerant") { defaults in
            let id = UUID()
            let stored = """
                {"quick-action:a":{"claude":{"model":"opus","effort":"high"}},
                 "quick-action:b":{"someFutureRoute":{"model":"x"}},
                 "quick-action:c":{"api":{"connection":"\(id.uuidString)","model":"m"}},
                 "quick-action:d":"not a route"}
                """
            defaults.set(Data(stored.utf8), forKey: AppSettingsKey.quickActionModelOverrides.rawValue)
            let routes = QuickActionRoutes.decode(Data(stored.utf8))
            expect(
                routes == [
                    "quick-action:a": .claude(model: "opus", effort: "high"),
                    "quick-action:c": .api(connection: id, model: "m", effort: nil)
                ],
                "entries this build reads survive one it doesn't")
            let store = QuickActionSettingsStore(defaults: defaults)
            expect(store.modelOverrides.count == 2, "the store loads the readable routes")
            expect(QuickActionRoutes.decode(Data("[]".utf8)).isEmpty, "a value of the wrong shape is no routes")
            expect(QuickActionRoutes.decode(nil).isEmpty, "nothing stored is no routes")
        }
    }

    static func aRemovedConnectionFallsBackWithANote() {
        withDefaults("QuickActionModelTests.lapse") { defaults in
            let kept = AIConnection(provider: .anthropic, models: ["claude"])
            let gone = UUID()
            let custom = QuickAction.custom(CustomQuickAction(name: "Tone", instructions: "Soften."))
            let alive = QuickAction.custom(CustomQuickAction(name: "Alive", instructions: "Stay."))
            let lost = AIModelSelection.api(connection: gone, model: "gpt-x", effort: "low")
            let store = QuickActionSettingsStore(defaults: defaults)
            store.select(.appleIntelligence)
            store.setModelOverride(lost, for: custom)
            store.setModelOverride(.api(connection: kept.id, model: "claude", effort: nil), for: alive)

            store.repairModel(against: [kept], fallback: nil)
            expect(store.model(for: custom) == .appleIntelligence, "the action falls back to the default")
            expect(store.modelOverride(for: alive) != nil, "a route whose connection is still there stays")
            expect(store.lapsedOverrides[custom.id] == lost, "the dropped route is remembered for the note")
            expect(store.lapsedOverrides[alive.id] == nil, "nothing is noted for a route that still works")

            store.repairModel(against: [kept], fallback: nil)
            expect(store.lapsedOverrides[custom.id] == lost, "a later repair keeps the note until it is shown")
            expect(store.takeLapsedOverride(for: custom) == lost, "the run takes the note")
            expect(store.takeLapsedOverride(for: custom) == nil, "and shows it only once")
            expect(
                QuickActionSettingsStore(defaults: defaults).modelOverride(for: custom) == nil,
                "the fallback is stored, so a relaunch keeps the default")
        }
    }

    static func aNewChoiceClearsTheNote() {
        withDefaults("QuickActionModelTests.clear") { defaults in
            let custom = QuickAction.custom(CustomQuickAction(name: "Tone", instructions: "Soften."))
            let store = QuickActionSettingsStore(defaults: defaults)
            store.setModelOverride(.api(connection: UUID(), model: "m", effort: nil), for: custom)
            store.repairModel(against: [], fallback: nil)
            expect(store.lapsedOverrides[custom.id] != nil, "a removed connection leaves a note")
            store.setModelOverride(nil, for: custom)
            expect(store.lapsedOverrides[custom.id] == nil, "saving the action, even on the default, clears it")
        }
    }

    // MARK: - Helpers

    /// A suite of its own, removed with its plist, so nothing touches the app's preferences.
    static func withDefaults(_ name: String, _ body: (UserDefaults) -> Void) {
        guard let defaults = UserDefaults(suiteName: name) else { return fail("no suite \(name)") }
        defaults.removePersistentDomain(forName: name)
        defer {
            defaults.removePersistentDomain(forName: name)
            CFPreferencesAppSynchronize(name as CFString)
            try? FileManager.default.removeItem(
                at: URL(fileURLWithPath: NSHomeDirectory())
                    .appendingPathComponent("Library/Preferences/\(name).plist"))
        }
        body(defaults)
    }

    static func expect(_ condition: Bool, _ label: String) {
        if condition {
            passes += 1
        } else {
            fail(label)
        }
    }

    static func fail(_ label: String) {
        print("FAIL: \(label)")
        failures += 1
    }
}
