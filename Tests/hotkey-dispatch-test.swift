import AppKit
import Carbon.HIToolbox

@main
@MainActor
struct HotKeyDispatchTest {
    static var failures = 0
    static var checks = 0

    static func check(_ name: String, _ value: Bool) {
        checks += 1
        if !value { failures += 1; print("FAIL \(name)") }
    }

    static func main() {
        for includesShift in [false, true] {
            dispatch(includesShift: includesShift)
            commandRelease(includesShift: includesShift)
        }
        agentChords()
        commandHold()
        print("\(checks) dispatch checks; \(failures) failures")
        if failures > 0 { exit(1) }
    }

    static func dispatch(includesShift: Bool) {
        let domain = "tinycast.hotkey-dispatch-test.\(UUID())"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let manager = HotKeyManager(defaults: defaults)
        let center = HotKeyCenter.current!
        var presses = 0
        var releases = 0
        var cancellations = 0
        var palette = 0
        manager.onDictationPressed = { presses += 1 }
        manager.onDictationReleased = { releases += 1 }
        manager.onDictationCancelled = { cancellations += 1 }
        manager.onTogglePalette = { palette += 1 }
        manager.dictationEnabled = true
        manager.dictationHoldToTalk = true
        let chord = KeyShortcut.hyperChord(includesShift: includesShift)
        let hyper = KeyShortcut(
            carbonKeyCode: kVK_ANSI_G, carbonModifiers: KeyShortcut.carbonModifiers(from: chord))
        let control = KeyShortcut(carbonKeyCode: kVK_ANSI_G, carbonModifiers: controlKey)
        manager.setBinding(.combo(hyper), for: .dictation)
        let normal = center.entries[HotKeyAction.dictation.defaultsKey]!
        normal.onKeyDown(0)
        normal.onKeyUp?()
        check("normal dictation has both callbacks", presses == 1 && releases == 1)
        manager.setSecureInputEquivalents(includesShift: includesShift)
        let id = "secureInputEquivalent." + HotKeyAction.dictation.defaultsKey
        let secure = center.entries[id]!
        secure.onKeyDown(CGEventFlags.maskControl.rawValue | 1)
        secure.onKeyUp?()
        check("Left Control cannot invoke Hyper", presses == 1 && releases == 1)
        secure.onKeyDown(CGEventFlags.maskControl.rawValue)
        secure.onKeyUp?()
        check("missing side identity cannot invoke Hyper", presses == 1)
        secure.onKeyDown(CGEventFlags.maskControl.rawValue | 0x2000)
        secure.onKeyUp?()
        check("Right Control dispatches Hyper and release", presses == 2 && releases == 2)
        secure.onKeyDown(CGEventFlags.maskControl.rawValue | 0x2001)
        secure.onKeyUp?()
        check("both Controls keep the reserved Right Control route", presses == 3 && releases == 3)
        manager.setBinding(.combo(control), for: .togglePalette)
        check(
            "shared Control combination has one registration",
            center.entries.values.filter { $0.shortcut == control }.count == 1)
        let shared = center.entries[id]!
        shared.onKeyDown(CGEventFlags.maskControl.rawValue | 1)
        shared.onKeyUp?()
        check(
            "Left Control retains its ordinary Tinycast binding",
            palette == 1 && presses == 3 && releases == 3)
        shared.onKeyDown(CGEventFlags.maskControl.rawValue | 0x2000)
        shared.onKeyUp?()
        check(
            "Right Control selects Hyper rather than ordinary binding",
            palette == 1 && presses == 4 && releases == 4)
        shared.onKeyDown(CGEventFlags.maskControl.rawValue | 0x2000)
        manager.recordingAction = .togglePalette
        manager.recordingAction = nil
        let resumed = center.entries[id]!
        let beforeResume = presses
        resumed.onKeyDown(CGEventFlags.maskControl.rawValue | 1)
        resumed.onKeyUp?()
        check("recording clears the previous Hyper press route", presses == beforeResume && palette == 2)
        let beforeCancellation = cancellations
        resumed.onKeyDown(CGEventFlags.maskControl.rawValue | 0x2000)
        manager.setSecureInputEquivalents(includesShift: nil)
        check("leaving Secure Input cancels an active hold", cancellations == beforeCancellation + 1)
        check("leaving Secure Input removes equivalent", center.entries[id] == nil)
        check(
            "leaving Secure Input restores ordinary registration",
            center.entries[HotKeyAction.togglePalette.defaultsKey]?.shortcut == control)
        manager.setSecureInputEquivalents(includesShift: includesShift)
        manager.setBinding(nil, for: .dictation)
        check("unbinding removes equivalent", center.entries[id] == nil)
        check(
            "unbinding preserves ordinary Control registration",
            center.entries[HotKeyAction.togglePalette.defaultsKey]?.shortcut == control)
        manager.setBinding(.combo(hyper), for: .dictation)
        manager.setBinding(nil, for: .togglePalette)
        check(
            "deleting ordinary binding preserves Hyper equivalent",
            center.entries[id]?.shortcut == control
                && center.entries[HotKeyAction.togglePalette.defaultsKey] == nil)
        manager.setSecureInputEquivalents(includesShift: nil)
        manager.setBinding(.combo(control), for: .dictation)
        manager.setBinding(.combo(hyper), for: .togglePalette)
        manager.setSecureInputEquivalents(includesShift: includesShift)
        let swappedID = "secureInputEquivalent." + HotKeyAction.togglePalette.defaultsKey
        let swapped = center.entries[swappedID]!
        let beforePress = presses
        let beforeRelease = releases
        swapped.onKeyDown(CGEventFlags.maskControl.rawValue | 1)
        swapped.onKeyUp?()
        check(
            "ordinary Control dictation still releases through a shared registration",
            presses == beforePress + 1 && releases == beforeRelease + 1)
        swapped.onKeyDown(CGEventFlags.maskControl.rawValue | 0x2000)
        swapped.onKeyUp?()
        check(
            "Hyper selects the other action in a shared registration",
            palette == 3 && presses == beforePress + 1)
    }

    static func commandRelease(includesShift: Bool) {
        let domain = "tinycast.hotkey-dispatch-test.\(UUID())"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let manager = HotKeyManager(defaults: defaults)
        let center = HotKeyCenter.current!
        var ran: [CommandID] = []
        var released: [CommandID] = []
        var dictationReleases = 0
        manager.onRunCommand = { ran.append($0) }
        manager.onCommandReleased = { released.append($0) }
        manager.onDictationReleased = { dictationReleases += 1 }
        manager.dictationEnabled = true
        manager.dictationHoldToTalk = true
        manager.releasedCommands = [.sample]
        func combo(_ key: Int) -> HotKeyBinding {
            .combo(KeyShortcut(carbonKeyCode: key, carbonModifiers: controlKey | optionKey))
        }
        manager.setBinding(combo(kVK_ANSI_H), for: .command(.sample))
        manager.setBinding(combo(kVK_ANSI_J), for: .command(.other))
        manager.setBinding(combo(kVK_ANSI_K), for: .dictation)
        let held = center.entries[HotKeyAction.command(.sample).defaultsKey]!
        held.onKeyDown(0)
        check("a released command runs on its press", ran == [.sample] && released.isEmpty)
        held.onKeyUp?()
        check("and hears its own release", released == [.sample])
        let other = center.entries[HotKeyAction.command(.other).defaultsKey]!
        check("any other command registers no key-up", other.onKeyUp == nil)
        other.onKeyDown(0)
        check("and still runs on its press", ran == [.sample, .other] && released == [.sample])
        center.entries[HotKeyAction.dictation.defaultsKey]?.onKeyUp?()
        check("dictation's release is its own", dictationReleases == 1 && released == [.sample])

        let chord = KeyShortcut.hyperChord(includesShift: includesShift)
        let hyper = KeyShortcut(carbonKeyCode: kVK_ANSI_L, carbonModifiers: KeyShortcut.carbonModifiers(from: chord))
        manager.setBinding(.combo(hyper), for: .command(.sample))
        manager.setSecureInputEquivalents(includesShift: includesShift)
        let secure = center.entries["secureInputEquivalent." + HotKeyAction.command(.sample).defaultsKey]!
        secure.onKeyDown(CGEventFlags.maskControl.rawValue | 0x2000)
        secure.onKeyUp?()
        check(
            "under Secure Input a Hyper command still hears its release",
            ran.last == .sample && released == [.sample, .sample])
        manager.setSecureInputEquivalents(includesShift: nil)
    }

    static func commandHold() {
        let domain = "tinycast.hotkey-dispatch-test.\(UUID())"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let manager = HotKeyManager(defaults: defaults)
        let monitor = manager.modifierTapMonitor
        var ran: [CommandID] = []
        var released: [CommandID] = []
        var cancelled: [CommandID] = []
        var dictation = (presses: 0, releases: 0, cancels: 0)
        manager.onRunCommand = { ran.append($0) }
        manager.onCommandReleased = { released.append($0) }
        manager.onCommandCancelled = { cancelled.append($0) }
        manager.onDictationPressed = { dictation.presses += 1 }
        manager.onDictationReleased = { dictation.releases += 1 }
        manager.onDictationCancelled = { dictation.cancels += 1 }
        manager.releasedCommands = [.sample]
        manager.start(
            customCommandIDs: [], quicklinkIDs: [], windowLayoutIDs: [], windowRoomIDs: [],
            customWindowSizeIDs: [], quickActionIDs: [])
        let rightOption = HotKeyBinding.modifier(.rightOption)
        manager.setBinding(rightOption, for: .command(.sample))
        check("a single modifier taps until its command is held", monitor.holdKeys.isEmpty)
        check("and the tap watches it", monitor.bound == [rightOption])
        manager.heldCommands = [.sample]
        check("a held command holds its modifier", monitor.holdKeys == [.rightOption])
        monitor.onHoldPressed?(.rightOption)
        check("holding runs the command", ran == [.sample] && released.isEmpty)
        monitor.onHoldReleased?(.rightOption)
        check("and letting go is its release", released == [.sample])
        monitor.onHoldPressed?(.rightOption)
        monitor.onHoldCancelled?(.rightOption)
        check("another key cancels the command's hold", cancelled == [.sample] && dictation.cancels == 0)
        monitor.onHoldPressed?(.leftOption)
        check("a key nothing holds runs nothing", ran == [.sample, .sample])

        manager.dictationEnabled = true
        manager.dictationHoldToTalk = true
        let globe = HotKeyBinding.globe
        manager.setBinding(globe, for: .dictation)
        check(
            "Dictation and a held command hold their own keys",
            monitor.holdKeys == [.rightOption, .globe] && monitor.bound == [rightOption, globe])
        monitor.onHoldPressed?(.globe)
        monitor.onHoldReleased?(.globe)
        check(
            "Dictation's hold is still its own",
            dictation.presses == 1 && dictation.releases == 1 && released == [.sample])

        manager.setBinding(.doubleModifier(.rightOption), for: .command(.other))
        check(
            "a double tap of a held modifier is refused",
            manager.conflictOwner(of: .doubleModifier(.rightOption), excluding: .command(.other)) == "sample")
        manager.heldCommands = []
        check(
            "a command out of hold mode releases its modifier",
            monitor.holdKeys == [.globe]
                && manager.conflictOwner(of: .doubleModifier(.rightOption), excluding: .command(.other)) == nil)
        manager.heldCommands = [.sample]
        check(
            "and a conflict keeps a command from holding at all",
            monitor.holdKeys == [.globe] && !monitor.bound.contains(rightOption))
        manager.setBinding(nil, for: .command(.other))
        manager.setBinding(.doubleModifier(.leftOption), for: .command(.sample))
        check(
            "a held command bound to a double tap taps as a toggle",
            monitor.holdKeys == [.globe] && monitor.bound.contains(.doubleModifier(.leftOption)))
        manager.setBinding(nil, for: .command(.sample))
        manager.setBinding(nil, for: .dictation)
        check("with nothing bound the tap watches nothing", monitor.bound.isEmpty && monitor.holdKeys.isEmpty)
    }
}

extension HotKeyDispatchTest {
    /// An agent registers a chord only once bound, keeps its index, and summons that agent.
    static func agentChords() {
        let domain = "tinycast.hotkey-dispatch-test.\(UUID())"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let manager = HotKeyManager(defaults: defaults)
        let center = HotKeyCenter.current!
        var summoned: [UUID] = []
        manager.onSummonAgent = { summoned.append($0) }
        let rig = UUID()
        let action = HotKeyAction.agent(id: rig)
        check("an agent without a chord registers nothing", center.entries[action.defaultsKey] == nil)
        let chord = HotKeyBinding.combo(KeyShortcut(carbonKeyCode: kVK_ANSI_R, carbonModifiers: controlKey | optionKey))
        manager.setBinding(chord, for: action)
        check("a bound agent is indexed for the next launch", manager.boundAgentIDs == [rig])
        center.entries[action.defaultsKey]?.onKeyDown(0)
        check("its chord summons that agent", summoned == [rig])
        check(
            "and another action can't take the chord", manager.conflictOwner(of: chord, excluding: .dictation) != nil)
        manager.setBinding(nil, for: action)
        check(
            "clearing it unregisters and unindexes it",
            center.entries[action.defaultsKey] == nil && manager.boundAgentIDs.isEmpty)
    }
}
