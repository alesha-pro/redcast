import AppKit
import Foundation

/// The real `ExtensionHostBridge` between JavaScriptCore and a recording AI host and context.
extension ExtensionTests {
    /// A palette or menu-bar context; `isOpenedByUser` false stands for a refresh nobody opened.
    @MainActor
    final class OriginContext: ExtensionHostContext {
        let storage: ExtensionStorage
        var isOpenedByUser: Bool
        private(set) var launches: [String] = []

        init(storage: ExtensionStorage, isOpenedByUser: Bool) {
            self.storage = storage
            self.isOpenedByUser = isOpenedByUser
        }

        var activeExtensionName: String? { "fixture" }
        var activeLaunchType: ExtensionLaunchType { isOpenedByUser ? .userInitiated : .background }
        var pasteTarget: NSRunningApplication? { nil }
        var applicationURLs: [URL] { [] }
        func closeMainWindow(clearRootSearch: Bool) {}
        func reopenPalette() {}
        func popToRoot() {}
        func clearSearchBar() {}
        func openPreferences(scope: String) {}
        func updateCommandMetadata(subtitle: String?) {}
        func present(toast: ExtensionToast) -> Int { 0 }
        func update(toast id: Int, with toast: ExtensionToast) {}
        func hide(toast id: Int) {}
        func showHUD(_ text: String) {}
        func confirmAlert(_ alert: ExtensionAlert) async -> Bool { false }
        func openWithPicker(path: String) async {}

        func launch(
            command: String, extensionName: String?, arguments: [String: String],
            fallbackText: String?, launchType: ExtensionLaunchType,
            launchContext: [String: RenderValue], openedByUser: Bool
        ) throws {
            launches.append("\(command) \(launchType.rawValue) user=\(openedByUser)")
        }

        func launch(_ link: ExtensionDeepLink, openedByUser: Bool) throws {
            launches.append("link \(link.commandName) user=\(openedByUser)")
        }
    }

    /// Answers like the gate does for the origin alone, and records who asked.
    @MainActor
    final class RecordingAI: ExtensionAIHost {
        struct Refusal: LocalizedError {
            var errorDescription: String? { "Extensions can use AI only in a command you open." }
        }

        private(set) var starts: [(openedByUser: Bool, owner: ObjectIdentifier)] = []
        private(set) var ended: [ObjectIdentifier] = []
        private var chunks: [String] = []

        func perform(
            method: String, arguments: [RenderValue], extensionName: String, openedByUser: Bool,
            owner: ObjectIdentifier
        ) async throws -> Any? {
            switch method {
            case "start":
                starts.append((openedByUser, owner))
                guard openedByUser, extensionName == "fixture" else { throw Refusal() }
                chunks = ["Hel", "lo"]
                return 1
            case "read":
                return chunks.isEmpty ? nil : chunks.removeFirst()
            default:
                return nil
            }
        }

        func canAccess(extensionName: String) -> Bool { true }
        func sessionEnded(owner: ObjectIdentifier) { ended.append(owner) }
    }

    @MainActor
    static func hostBridgeAIChecks() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "tinycast-ai-bridge-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = ExtensionStorage(directory: directory.appendingPathComponent("storage"))
        let palette = OriginContext(storage: storage, isOpenedByUser: true)
        let ai = RecordingAI()
        let bridge = ExtensionHostBridge(
            clipboardStore: ClipboardStore(directory: directory.appendingPathComponent("clipboard")))
        bridge.context = palette
        bridge.ai = ai
        let owner = ObjectIdentifier(bridge)

        let command = #"""
            const React = require("react");
            const { AI, Detail, LaunchType, launchCommand, open } = require("@raycast/api");
            module.exports.default = function Command() {
              const [result, setResult] = React.useState("");
              React.useEffect(() => {
                (async () => {
                  await launchCommand({ name: "ask", type: LaunchType.UserInitiated });
                  await open("raycast://extensions/someone/fixture/ask");
                  return AI.ask("hi");
                })().then((text) => setResult("answer " + text), (error) => setResult(error.message));
              }, []);
              return React.createElement(Detail, { markdown: result });
            };
            """#
        func run(on bridge: ExtensionHostBridge, session: String) async -> String? {
            let recorder = Recorder()
            let runtime = ExtensionRuntime(hostAPI: bridge, runtimeURL: runtimeURL())
            runtime.setDelegate(recorder)
            defer { runtime.shutdown() }
            do {
                try await runtime.boot(config: .current(supportDirectory: directory))
            } catch {
                check("the bridge runtime boots", false, error.localizedDescription)
                return nil
            }
            await runtime.start(
                session: session, code: command, file: URL(fileURLWithPath: "/tmp/\(session).js"),
                mode: .view, context: launchContext())
            await settle(until: { recorder.trees.last?.activeRoot?.string("markdown")?.isEmpty == false })
            let markdown = recorder.trees.last?.activeRoot?.string("markdown")
            await runtime.stop(session: session)
            return markdown
        }

        let opened = await run(on: bridge, session: "opened")
        check("a command the user opened gets its answer", opened == "answer Hello", opened ?? "nil")
        check(
            "the bridge names itself and the user's origin to the AI host",
            ai.starts.count == 1 && ai.starts.first?.openedByUser == true && ai.starts.first?.owner == owner)
        check(
            "its launches carry the user's origin",
            palette.launches == ["ask userInitiated user=true", "link ask user=true"],
            palette.launches.joined(separator: ", "))
        await settle(until: { ai.ended.contains(owner) })
        check(
            "leaving the command ends its answers",
            !ai.ended.isEmpty && ai.ended.allSatisfy { $0 == owner }, "\(ai.ended.count)")

        palette.isOpenedByUser = false
        let refresh = await run(on: bridge, session: "refresh")
        check(
            "a run nobody opened is refused by the AI host",
            refresh == "Extensions can use AI only in a command you open."
                && ai.starts.last?.openedByUser == false,
            refresh ?? "nil")
        check(
            "and what it launches, UserInitiated or a link, is not the user's either",
            palette.launches.suffix(2) == ["ask userInitiated user=false", "link ask user=false"],
            palette.launches.joined(separator: ", "))

        let menu = OriginContext(storage: storage, isOpenedByUser: false)
        let menuBridge = bridge.scoped(to: menu)
        let starts = ai.starts.count
        let menuResult = await run(on: menuBridge, session: "menu")
        check(
            "a menu-bar bridge has no AI host",
            menuResult == "AI in menu-bar commands and background launches is not supported in Tinycast extensions."
                && ai.starts.count == starts,
            menuResult ?? "nil")
        check(
            "a menu-bar refresh's launch of an AI command reaches it as not the user's",
            menu.launches == ["ask userInitiated user=false", "link ask user=false"],
            menu.launches.joined(separator: ", "))
        await settle(250)
        check("a menu-bar session's end reaches no AI host", !ai.ended.contains(ObjectIdentifier(menuBridge)))
    }
}

// MARK: - Stubs for what the bridge's clipboard paths reach and these checks never exercise

@MainActor
final class AppSettings {
    var clipboardDisabledApps: Set<String> = []
}

enum Permissions {
    static func ensureAccessibility() -> Bool { false }
}

final class NotificationToken {
    init(_ observer: Any, center: NotificationCenter) {}
}
