import AppKit
import Foundation

/// The real `ExtensionHostBridge` between JavaScriptCore and a recording AI host and context.
extension ExtensionTests {
    /// A palette or menu-bar context; `isOpenedByUser` false stands for a refresh nobody opened.
    @MainActor
    final class OriginContext: ExtensionHostContext {
        let storage: ExtensionStorage
        var isOpenedByUser: Bool
        /// Set the way the menu-bar host is: true only while one of its items' actions runs.
        var acting: Bool?
        private(set) var launches: [String] = []

        init(storage: ExtensionStorage, isOpenedByUser: Bool) {
            self.storage = storage
            self.isOpenedByUser = isOpenedByUser
        }

        var activeExtensionName: String? { "fixture" }
        var activeLaunchType: ExtensionLaunchType { isOpenedByUser ? .userInitiated : .background }
        var isActingForUser: Bool { acting ?? isOpenedByUser }
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
            var errorDescription: String? {
                "Extensions can use AI only in a command you open or from a menu-bar item you click."
            }
        }

        private(set) var starts: [(actingForUser: Bool, owner: ObjectIdentifier)] = []
        private(set) var ended: [ObjectIdentifier] = []
        private var chunks: [String] = []

        func perform(
            method: String, arguments: [RenderValue], extensionName: String, actingForUser: Bool,
            owner: ObjectIdentifier
        ) async throws -> Any? {
            switch method {
            case "start":
                starts.append((actingForUser, owner))
                guard actingForUser, extensionName == "fixture" else { throw Refusal() }
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
            ai.starts.count == 1 && ai.starts.first?.actingForUser == true && ai.starts.first?.owner == owner)
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
            refresh == RecordingAI.Refusal().errorDescription && ai.starts.last?.actingForUser == false,
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
            "a scoped bridge carries no AI host of its own",
            menuResult == "AI is not supported in Tinycast extensions." && ai.starts.count == starts,
            menuResult ?? "nil")
        check(
            "a menu-bar refresh's launch of an AI command reaches it as not the user's",
            menu.launches == ["ask userInitiated user=false", "link ask user=false"],
            menu.launches.joined(separator: ", "))
        await settle(250)
        check("a menu-bar session's end reaches no AI host", !ai.ended.contains(ObjectIdentifier(menuBridge)))
    }

    /// The menu-bar lane with the AI host its manager hands it: only a click's action may ask.
    @MainActor
    static func menuBarAIChecks() async {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "tinycast-menu-ai-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = ExtensionStorage(directory: directory.appendingPathComponent("storage"))
        let path = directory.appendingPathComponent("fixture")
        try? FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        try? #"""
            const React = require("react");
            const { AI, LocalStorage, MenuBarExtra, environment } = require("@raycast/api");
            module.exports.default = function Command() {
              React.useEffect(() => {
                AI.ask("render").then(
                  (text) => LocalStorage.setItem("render", text),
                  (error) => LocalStorage.setItem("render", error.message));
              }, []);
              return React.createElement(MenuBarExtra, { title: String(environment.canAccess(AI)), icon: "star-16" },
                React.createElement(MenuBarExtra.Item, { title: "Ask", onAction: async () => {
                  await LocalStorage.setItem("action", await AI.ask("action"));
                } }));
            };
            """#.write(to: path.appendingPathComponent("bar.js"), atomically: true, encoding: .utf8)
        guard
            let manifest = ExtensionManifest(json: [
                "name": "fixture",
                "commands": [["name": "bar", "title": "Bar", "mode": "menu-bar", "disabledByDefault": true]]
            ])
        else {
            check("the menu-bar AI fixture's manifest parses", false)
            return
        }
        let owner = InstalledExtension(manifest: manifest, directory: path)
        let reference = ExtensionCommandRef(extensionName: "fixture", commandName: "bar")
        let ai = RecordingAI()
        let root = ExtensionHostBridge(
            clipboardStore: ClipboardStore(directory: directory.appendingPathComponent("clipboard")))
        var contexts: [OriginContext] = []
        var bridges: [ObjectIdentifier] = []
        let metadata = ExtensionCommandMetadataStore(fileURL: directory.appendingPathComponent("commands.json"))
        let manager = ExtensionMenuBarManager(
            storage: storage, commandMetadata: metadata,
            supportDirectory: directory.appendingPathComponent("support"), executionTimeout: .seconds(5),
            showsStatusItems: false,
            makeExecution: { _, _, type in
                let context = OriginContext(storage: storage, isOpenedByUser: type == .userInitiated)
                context.acting = false
                contexts.append(context)
                let bridge = root.scoped(to: context)
                bridge.ai = ai
                bridges.append(ObjectIdentifier(bridge))
                return .init(
                    runtime: ExtensionRuntime(hostAPI: bridge, runtimeURL: runtimeURL()),
                    stop: { bridge.context = nil }, setActing: { context.acting = $0 },
                    aiAccess: type == .userInitiated)
            }, onError: { _, _, _ in })
        defer { manager.stop() }
        manager.synchronize([owner])
        func stored(_ key: String) -> ExtensionStorage.StoredValue? {
            storage.localStorageValue(extension: "fixture", key: key)
        }
        func title() -> String? {
            metadata.metadata(extension: "fixture", command: "bar").menuBarSnapshot?.title
        }

        manager.run(owner, command: owner.manifest.commands[0])
        await settle(until: { stored("render") != nil && title() != nil && !manager.isRunning })
        check(
            "a menu the user opened reports canAccess(AI)",
            title() == "true", title() ?? "nil")
        check(
            "but its render may not ask, even then",
            stored("render") == .string(RecordingAI.Refusal().errorDescription ?? "")
                && ai.starts.allSatisfy { !$0.actingForUser },
            "\(String(describing: stored("render")))")

        let controller = manager.controller(for: reference, owner: owner)
        controller.menuWillOpen(controller.menu)
        await settle(until: {
            manager.isRunning && controller.menu.items.first { $0.title == "Ask" }?.representedObject != nil
        })
        guard let index = controller.menu.items.firstIndex(where: { $0.title == "Ask" }) else {
            check("the menu-bar AI fixture shows its item", false)
            return
        }
        controller.menuDidClose(controller.menu)
        controller.menu.performActionForItem(at: index)
        await settle(until: { stored("action") != nil && !manager.isRunning })
        check(
            "a click's action asks for the user and gets its answer",
            stored("action") == .string("Hello") && ai.starts.last?.actingForUser == true
                && ai.starts.last?.owner == bridges.last,
            "\(String(describing: stored("action")))")
        check("the gesture ends with the action", contexts.last?.acting == false)
        await settle(until: { bridges.last.map(ai.ended.contains) == true })
        check("leaving the menu ends its answers", bridges.last.map(ai.ended.contains) == true)

        manager.run(owner, command: owner.manifest.commands[0], type: .background)
        await settle(until: { title() == "false" && !manager.isRunning })
        check("a refresh reports no access", title() == "false", title() ?? "nil")
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
