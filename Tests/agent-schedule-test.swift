import Foundation
import Observation

@main
@MainActor
struct AgentScheduleTests {
    static var failures = 0
    static var passes = 0

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if condition() {
            passes += 1
        } else {
            failures += 1
            print("FAIL: \(message)")
        }
    }

    static func main() async {
        handlesAreStableAndUnique()
        addressesParse()
        dailyOccurrences()
        weekdaysSkipTheWeekend()
        everyNHoursRepeatsDaily()
        daylightSavingIsSane()
        verdicts()
        aWeekAwayRunsOnce()
        ledgerIndicator()
        runTitles()
        consentModes()
        await anUnattendedRefusalIsReported()
        noteBlocks()
        schedulesPersist()
        profilesWithoutBackgroundDecode()
        nothingIsResidentWithoutASchedule()
        theSchedulerFiresWhatIsDue()
        await consentQueuesBehindADialog()

        print("\(passes) passed, \(failures) failed")
        if failures > 0 { exit(1) }
    }

    // MARK: - Fixtures

    static func calendar(_ zone: String = "UTC", locale: String = "en_US_POSIX") -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        calendar.locale = Locale(identifier: locale)
        return calendar
    }

    /// An ISO 8601 moment with its own offset, so a test reads as the wall clock it means.
    static func at(_ text: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)!
    }

    static func agent(_ name: String, created: TimeInterval = 0) -> AgentProfile {
        AgentProfile(name: name, directory: "/tmp", createdAt: Date(timeIntervalSinceReferenceDate: created))
    }

    static func scratch() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("AgentScheduleTests-\(UUID().uuidString)")
    }

    static let daily8 = AgentScheduleRule(kind: .daily, minuteOfDay: 8 * 60)

    // MARK: - Addresses

    static func handlesAreStableAndUnique() {
        expect(AgentTaskAddress.handle(for: "Rig") == "rig", "a name lower-cases to its handle")
        expect(AgentTaskAddress.handle(for: "Project Bot") == "project-bot", "a space becomes a hyphen")
        expect(AgentTaskAddress.handle(for: "Риг!") == "риг", "any script's letters stay; punctuation goes")
        expect(AgentTaskAddress.handle(for: "  a -- b  ") == "a-b", "a run of anything else is one hyphen")
        expect(AgentTaskAddress.handle(for: "🤖") == "agent", "a name with no letters still has a handle")
        let first = agent("Rig", created: 1)
        let second = agent("rig", created: 2)
        let handles = AgentTaskAddress.handles(for: [second, first])
        expect(
            handles.map(\.handle) == ["rig", "rig-2"] && handles.map(\.id) == [first.id, second.id],
            "a clash takes -2 in creation order, whatever order the list came in")
    }

    static func addressesParse() {
        let rig = agent("Rig", created: 1)
        let bot = agent("Project Bot", created: 2)
        let handles = AgentTaskAddress.handles(for: [rig, bot])
        func parse(_ query: String) -> AgentTaskAddress? { AgentTaskAddress.parse(query, handles: handles) }
        expect(parse("@") == .completing([rig.id, bot.id]), "a bare @ lists every agent")
        expect(parse("@ri") == .completing([rig.id]), "a prefix lists the agents it starts")
        expect(parse("@rig") == .completing([rig.id]), "a whole handle still completes before the space")
        expect(parse("@rig ") == .task(agent: rig.id, text: ""), "a space ends the handle: an empty task")
        expect(
            parse("  @RIG check temps ") == .task(agent: rig.id, text: "check temps"),
            "leading spaces and case don't matter, and the task is trimmed")
        expect(parse("@project-bot\tgo") == .task(agent: bot.id, text: "go"), "any whitespace ends a handle")
        expect(parse("@ri x") == nil, "a task needs a whole handle")
        expect(parse("@nobody x") == nil, "an unknown handle is ordinary search")
        expect(parse("@zz") == nil, "so is a prefix of no handle")
        expect(parse("hello @rig") == nil, "@ must open the query")
        expect(parse("mail@x") == nil, "an address is not an agent")
        expect(AgentTaskAddress.parse("@", handles: []) == nil, "with no agents nothing is claimed")
    }

    // MARK: - Occurrences

    static func dailyOccurrences() {
        let utc = calendar()
        expect(
            AgentSchedulePolicy.occurrence(after: at("2026-10-22T07:59:00Z"), rule: daily8, calendar: utc)
                == at("2026-10-22T08:00:00Z"), "08:00 after 07:59 is the same day")
        expect(
            AgentSchedulePolicy.occurrence(after: at("2026-10-22T08:00:00Z"), rule: daily8, calendar: utc)
                == at("2026-10-23T08:00:00Z"), "strictly after: 08:00 itself moves to tomorrow")
        let invalid = AgentScheduleRule(kind: .daily, minuteOfDay: 1_440)
        expect(!invalid.isValid, "a minute past the day is invalid")
        expect(
            AgentSchedulePolicy.occurrence(after: Date(), rule: invalid, calendar: utc) == nil,
            "and has no occurrence")
    }

    static func weekdaysSkipTheWeekend() {
        let rule = AgentScheduleRule(kind: .weekdays, minuteOfDay: 8 * 60)
        // 2026-10-23 is a Friday.
        expect(
            AgentSchedulePolicy.occurrence(after: at("2026-10-23T09:00:00Z"), rule: rule, calendar: calendar())
                == at("2026-10-26T08:00:00Z"), "Friday after 08:00 goes to Monday")
        let israel = calendar(locale: "he_IL")
        expect(
            AgentSchedulePolicy.occurrence(after: at("2026-10-22T09:00:00Z"), rule: rule, calendar: israel)
                == at("2026-10-25T08:00:00Z"), "a Friday–Saturday weekend goes from Thursday to Sunday")
    }

    static func everyNHoursRepeatsDaily() {
        let rule = AgentScheduleRule(kind: .everyHours, minuteOfDay: 90, hours: 6)
        expect(rule.minutesOfDay == [90, 450, 810, 1_170], "every six hours from 01:30, the same each day")
        expect(
            AgentSchedulePolicy.occurrence(after: at("2026-10-22T05:00:00Z"), rule: rule, calendar: calendar())
                == at("2026-10-22T07:30:00Z"), "after 05:00 the next is 07:30")
        let late = AgentScheduleRule(kind: .everyHours, minuteOfDay: 23 * 60, hours: 6)
        expect(late.minutesOfDay == [300, 660, 1_020, 1_380], "the anchor folds into the first block")
        expect(!AgentScheduleRule(kind: .everyHours, minuteOfDay: 0, hours: 5).isValid, "5 doesn't divide 24")
        expect(
            AgentScheduleRule(kind: .daily, minuteOfDay: 0, hours: 5).isValid,
            "hours matter only to every N hours")
    }

    static func daylightSavingIsSane() {
        let berlin = calendar("Europe/Berlin")
        let rule = AgentScheduleRule(kind: .daily, minuteOfDay: 150)
        let spring = AgentSchedulePolicy.occurrence(
            after: at("2026-03-29T00:00:00+01:00"), rule: rule, calendar: berlin)
        expect(spring == at("2026-03-29T03:00:00+02:00"), "02:30 that never happens fires at 03:00")
        expect(
            spring.flatMap { AgentSchedulePolicy.occurrence(after: $0, rule: rule, calendar: berlin) }
                == at("2026-03-30T02:30:00+02:00"), "and only once that day")
        let hourly = AgentScheduleRule(kind: .everyHours, minuteOfDay: 30, hours: 1)
        let first = AgentSchedulePolicy.occurrence(
            after: at("2026-10-25T02:00:00+02:00"), rule: hourly, calendar: berlin)
        expect(first == at("2026-10-25T02:30:00+02:00"), "the repeated hour fires at its first 02:30")
        expect(
            first.flatMap { AgentSchedulePolicy.occurrence(after: $0, rule: hourly, calendar: berlin) }
                == at("2026-10-25T03:30:00+01:00"), "and not again at the second")
    }

    // MARK: - Verdicts

    static func verdicts() {
        let utc = calendar()
        let baseline = at("2026-10-22T07:00:00Z")
        func verdict(
            _ now: String, _ catchUp: AgentScheduleCatchUp = .once, notBefore: Date? = nil,
            baseline: Date = baseline
        ) -> AgentSchedulePolicy.Verdict {
            AgentSchedulePolicy.verdict(
                rule: daily8, catchUp: catchUp, baseline: baseline, now: at(now), notBefore: notBefore,
                calendar: utc)
        }
        expect(verdict("2026-10-22T07:30:00Z") == .wait(until: at("2026-10-22T08:00:00Z")), "not yet: wait")
        expect(verdict("2026-10-22T08:05:00Z", .skip) == .run, "five minutes late is on time")
        expect(verdict("2026-10-22T08:06:00Z", .skip) == .skip, "six minutes late is missed under skip")
        expect(verdict("2026-10-22T08:06:00Z", .once) == .run, "and run once under once")
        let settle = at("2026-10-22T08:07:00Z")
        expect(
            verdict("2026-10-22T08:06:00Z", notBefore: settle) == .wait(until: settle),
            "a due run waits out the settle after wake")
        expect(
            verdict("2026-10-22T08:06:00Z", notBefore: at("2026-10-22T08:00:00Z")) == .run,
            "a settle already past holds nothing")
        expect(
            verdict("2026-10-22T08:03:00Z", baseline: at("2026-10-25T00:00:00Z"))
                == .wait(until: at("2026-10-23T08:00:00Z")),
            "a baseline ahead of the clock is read as now, so a clock set back can't postpone days")
        let broken = AgentSchedulePolicy.verdict(
            rule: AgentScheduleRule(kind: .everyHours, minuteOfDay: 0, hours: 7), catchUp: .once,
            baseline: baseline, now: at("2026-10-22T08:00:00Z"), notBefore: nil, calendar: utc)
        expect(broken == .wait(until: .distantFuture), "an invalid rule never fires")
    }

    static func aWeekAwayRunsOnce() {
        let utc = calendar()
        let now = at("2026-10-22T12:00:00Z")
        let weekAgo = now.addingTimeInterval(-7 * 24 * 60 * 60)
        expect(
            AgentSchedulePolicy.verdict(
                rule: daily8, catchUp: .once, baseline: weekAgo, now: now, notBefore: nil, calendar: utc)
                == .run, "seven missed mornings are one run")
        expect(
            AgentSchedulePolicy.verdict(
                rule: daily8, catchUp: .once, baseline: now, now: now, notBefore: nil, calendar: utc)
                == .wait(until: at("2026-10-23T08:00:00Z")), "and once it ran, the next is tomorrow's")
        expect(
            AgentSchedulePolicy.verdict(
                rule: daily8, catchUp: .skip, baseline: weekAgo, now: now, notBefore: nil, calendar: utc)
                == .skip, "under skip a week away runs nothing")
    }

    // MARK: - Runs

    static func run(
        _ agentID: UUID = UUID(), state: AgentRun.State = .running, origin: AgentRun.Origin = .launcher
    ) -> AgentRun {
        AgentRun(
            id: UUID(), agentID: agentID, agentName: "Rig", symbol: "cpu", title: "t", origin: origin,
            startedAt: Date(), state: state)
    }

    static func ledgerIndicator() {
        var ledger = AgentRunLedger()
        expect(ledger.indicator == .hidden, "nothing ran: nothing to show")
        let rig = UUID()
        let first = run(rig)
        let second = run()
        ledger.begin(first)
        ledger.begin(second)
        expect(ledger.runs.first?.id == second.id, "newest first")
        expect(ledger.indicator == .running(2), "two in flight")
        expect(ledger.isBusy(agent: rig) && !ledger.isBusy(agent: UUID()), "busy is per agent")
        ledger.update(second.id) { $0.state = .waiting }
        expect(ledger.indicator == .waiting, "a run waiting for an answer beats running")
        ledger.update(second.id) { $0.state = .done }
        expect(ledger.indicator == .running(1), "running beats a finished run")
        ledger.update(first.id) { $0.state = .failed("No model") }
        expect(ledger.indicator == .failed, "an unseen failure beats an unseen success")
        expect(!ledger.isBusy(agent: rig), "a finished agent is free")
        ledger.markFinishedSeen()
        expect(ledger.indicator == .hidden, "once seen and idle, the item goes")

        var kept = AgentRunLedger()
        let active = run()
        kept.begin(active)
        for _ in 0..<11 {
            let finished = run()
            kept.begin(finished)
            kept.update(finished.id) { $0.state = .done }
        }
        expect(kept.runs.count(where: { !$0.isActive }) == AgentRunLedger.keptFinished, "ten finished are kept")
        expect(kept.run(active.id) != nil, "an active run is never dropped, however old")
        let scheduled = UUID()
        kept.begin(run(origin: .schedule(scheduled, manual: false)))
        expect(kept.isRunning(schedule: scheduled), "a schedule's run is found by its schedule")
        expect(!AgentRun.Origin.schedule(scheduled, manual: false).announces, "a schedule's own run is quiet")
        expect(AgentRun.Origin.schedule(scheduled, manual: true).announces, "Run Now is announced")
    }

    static func runTitles() {
        expect(AgentRun.title(for: "  check temps \nand more") == "check temps", "the first line names it")
        let long = AgentRun.title(for: String(repeating: "a", count: 200))
        expect(long.count == AgentRun.maxTitleLength && long.hasSuffix("…"), "a long task is cut to 80")
        let schedule = AgentSchedule(agentID: UUID(), name: "Morning digest", prompt: "p")
        let title = schedule.runTitle(
            at: at("2026-10-22T08:00:00Z"), locale: Locale(identifier: "en_US_POSIX"),
            timeZone: TimeZone(identifier: "UTC")!)
        expect(
            title.hasPrefix("Morning digest · ") && title.contains("2026"),
            "a scheduled chat is its name and date, got \(title)")
    }

    // MARK: - Consent

    static func consentModes() {
        expect(
            AgentConsentMode.decide(isUnattended: false, consent: .decline, idleSeconds: 9_999) == .foreground,
            "a chat someone started asks as it always has")
        expect(
            AgentConsentMode.decide(isUnattended: true, consent: .ask, idleSeconds: 30) == .ask,
            "an unattended ask reaches someone who touched the Mac in the last two minutes")
        expect(
            AgentConsentMode.decide(isUnattended: true, consent: .ask, idleSeconds: 121) == .decline,
            "nobody there: declined, not left on screen")
        expect(
            AgentConsentMode.decide(isUnattended: true, consent: .decline, idleSeconds: 0) == .decline,
            "decline declines even with someone at the keyboard")
        let chat = UUID()
        expect(
            AgentRunMode.turn(in: chat, isUnattended: true, consent: .decline) == .unattended(chat),
            "a run set to decline runs the native loop unattended")
        expect(
            AgentRunMode.turn(in: chat, isUnattended: true, consent: .ask) == .chat(chat),
            "a run that may ask keeps the chat's mode and asks through the gate")
        expect(
            AgentRunMode.turn(in: chat, isUnattended: false, consent: .decline) == .chat(chat),
            "and a chat is a chat")
    }

    /// What a run nobody watched refused is counted, and nothing was asked or done.
    static func anUnattendedRefusalIsReported() async {
        struct Writer: AgentToolProvider {
            func specs(for turn: AgentTurn) -> [AgentToolSpec] {
                [
                    AgentToolSpec(
                        tool: AITool(name: "write_it", description: "", parameters: .object([:]), origin: "T"),
                        family: .files, risk: .change, concurrent: false)
                ]
            }
            func run(_ call: AIToolCall, in context: AgentToolContext) async -> AIToolResult {
                await context.consent(AgentConsentRequest(summary: "s", detail: ""))
                    ? AIToolResult(callID: call.id, content: "wrote", isError: false)
                    : .failure(call.id, "declined")
            }
        }
        let refusals = Counter()
        let asks = Counter()
        let profile = AgentProfile(name: "T", directory: "/tmp")
        let toolset = AgentToolset(
            turn: AgentTurn(
                profile: profile, skills: [], memoryURL: URL(fileURLWithPath: "/tmp/m.md"),
                mode: .unattended(UUID())),
            providers: [Writer()], mcpTools: [], mcp: { .failure($0.id, "mcp") },
            refused: { _ in refusals.add() }, ask: { _, _ in asks.add(); return true })
        let result = await toolset.run(
            AIToolCall(id: "1", name: "write_it", arguments: "{}"), signal: { _ in })
        expect(result.isError, "a change with nobody to ask is refused")
        expect(refusals.value == 1 && asks.value == 0, "and reported as refused, without asking anyone")
    }

    // MARK: - Notes

    static func noteBlocks() {
        let block = AgentNoteEntry.block(
            heading: "Morning digest", at: at("2026-10-22T08:00:00Z"), answer: "\nAll green.\n",
            locale: Locale(identifier: "en_US_POSIX"), timeZone: TimeZone(identifier: "UTC")!)
        expect(block.hasPrefix("## Morning digest — "), "a dated second-level heading")
        expect(block.hasSuffix("\n\nAll green."), "then a blank line and the trimmed answer")
        expect(
            AgentNoteEntry.appending("## B", to: "Notes\n\n\n") == "Notes\n\n## B\n",
            "exactly one blank line after what was there")
        expect(AgentNoteEntry.appending("## B", to: "Notes") == "Notes\n\n## B\n", "with or without a newline")
        expect(AgentNoteEntry.appending("## B", to: "") == "## B\n", "an empty note is just the section")
        let huge = AgentNoteEntry.block(
            heading: "H", at: Date(), answer: String(repeating: "é", count: 40_000), locale: .current,
            timeZone: .current)
        let body = huge.components(separatedBy: "\n\n").dropFirst().joined(separator: "\n\n")
        expect(body.utf8.count <= AgentNoteEntry.maxAnswerBytes, "an answer is capped at 64 KB")
        expect(huge.hasSuffix("… The full answer is in AI Chat."), "and the cut says where the rest is")
    }

    // MARK: - Persistence

    static func schedulesPersist() {
        let directory = scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AgentStore(directory: directory)
        guard let rig = try? store.add(AgentProfile(name: "Rig", directory: "/tmp")),
            let other = try? store.add(AgentProfile(name: "Other", directory: "/tmp"))
        else { return expect(false, "agents save") }
        let t0 = at("2026-10-01T00:00:00Z")
        func error(_ draft: AgentSchedule) -> AgentScheduleError? {
            do {
                try store.saveSchedule(draft, now: t0)
                return nil
            } catch {
                return error
            }
        }
        expect(error(AgentSchedule(agentID: rig.id, name: " ", prompt: "p")) == .emptyName, "a name is required")
        expect(error(AgentSchedule(agentID: rig.id, name: "n", prompt: "\n")) == .emptyPrompt, "so is a prompt")
        expect(
            error(
                AgentSchedule(
                    agentID: rig.id, name: "n", prompt: "p",
                    rule: AgentScheduleRule(kind: .everyHours, minuteOfDay: 0, hours: 5))) == .invalidRule,
            "and a rule that can fire")
        expect(store.schedules.isEmpty, "a refused schedule is not kept")

        let draft = AgentSchedule(
            agentID: rig.id, name: " Morning digest ", prompt: "Summarize {date}.", noteTitle: "  ",
            createdAt: t0)
        guard let saved = try? store.saveSchedule(draft, now: t0) else { return expect(false, "it saves") }
        expect(saved.name == "Morning digest" && saved.noteTitle == nil, "trimmed, and a blank note is none")
        expect(store.baseline(for: saved) == t0, "a new schedule counts from now")
        _ = try? store.saveSchedule(AgentSchedule(agentID: other.id, name: "x", prompt: "y"), now: t0)

        let reloaded = AgentStore(directory: directory)
        reloaded.load()
        expect(reloaded.schedules(forAgent: rig.id) == [saved], "schedules survive a relaunch")
        expect(reloaded.scheduleBaselines[saved.id] == t0, "and so do their baselines")

        var edited = saved
        edited.prompt = "Something else"
        _ = try? store.saveSchedule(edited, now: t0.addingTimeInterval(60))
        expect(store.baseline(for: edited) == t0, "a new prompt keeps the schedule's place")
        edited.rule.minuteOfDay = 10 * 60
        let retimed = t0.addingTimeInterval(120)
        _ = try? store.saveSchedule(edited, now: retimed)
        expect(store.baseline(for: edited) == retimed, "a new time starts counting again")
        edited.isEnabled = false
        _ = try? store.saveSchedule(edited, now: t0.addingTimeInterval(180))
        expect(store.baseline(for: edited) == retimed, "switching off moves nothing")
        edited.isEnabled = true
        let back = t0.addingTimeInterval(240)
        _ = try? store.saveSchedule(edited, now: back)
        expect(store.baseline(for: edited) == back, "switching back on never catches up")
        store.setBaseline(t0, forSchedule: UUID())
        expect(store.scheduleBaselines.count == 2, "a baseline for no schedule is not kept")

        try? store.remove(id: rig.id)
        expect(store.schedules(forAgent: rig.id).isEmpty, "removing an agent drops its schedules")
        expect(store.scheduleBaselines[saved.id] == nil, "and their baselines")
        let afterRemoval = AgentStore(directory: directory)
        afterRemoval.load()
        expect(
            afterRemoval.schedules.map(\.agentID) == [other.id] && afterRemoval.scheduleBaselines.count == 1,
            "on disk too")
        if let survivor = afterRemoval.schedules.first {
            try? afterRemoval.removeSchedule(id: survivor.id)
            expect(afterRemoval.schedules.isEmpty && afterRemoval.scheduleBaselines.isEmpty, "removed whole")
        }

        let orphanDirectory = scratch()
        defer { try? FileManager.default.removeItem(at: orphanDirectory) }
        let orphans = AgentStore(directory: orphanDirectory)
        guard let known = try? orphans.add(AgentProfile(name: "K", directory: "/tmp")) else { return }
        let stray = [
            AgentSchedule(agentID: known.id, name: "k", prompt: "p"),
            AgentSchedule(agentID: UUID(), name: "u", prompt: "p")
        ]
        try? JSONEncoder().encode(stray).write(to: orphanDirectory.appendingPathComponent("agent-schedules.json"))
        orphans.load()
        expect(orphans.schedules.map(\.name) == ["k"], "a schedule of an unknown agent is dropped on load")

        let brokenDirectory = scratch()
        defer { try? FileManager.default.removeItem(at: brokenDirectory) }
        let broken = AgentStore(directory: brokenDirectory)
        guard let owner = try? broken.add(AgentProfile(name: "B", directory: "/tmp")) else { return }
        let file = brokenDirectory.appendingPathComponent("agent-schedules.json")
        try? Data("not json".utf8).write(to: file)
        broken.load()
        expect(!broken.schedulesAvailable, "an unreadable schedules file is noticed")
        expect(
            (try? broken.saveSchedule(AgentSchedule(agentID: owner.id, name: "n", prompt: "p"), now: t0)) == nil,
            "and never written over")
        expect((try? String(contentsOf: file, encoding: .utf8)) == "not json", "the file is as it was")
        expect(broken.isAvailable, "the agents themselves still save")
    }

    static func profilesWithoutBackgroundDecode() {
        let plain = AgentProfile(name: "Old", directory: "/tmp")
        guard let data = try? JSONEncoder().encode(plain),
            let text = String(data: data, encoding: .utf8),
            let decoded = try? JSONDecoder().decode(AgentProfile.self, from: data)
        else { return expect(false, "a profile encodes") }
        expect(!text.contains("background"), "an untouched agent writes no background policy")
        expect(
            decoded.background == nil && decoded.backgroundPolicy == AgentBackgroundPolicy(),
            "a file from before the feature reads as the defaults")
        let defaults = AgentBackgroundPolicy()
        expect(
            defaults.consent == .ask && !defaults.notifies && defaults.minutes == 15,
            "ask, no banner, a quarter of an hour")
        var tuned = plain
        tuned.background = AgentBackgroundPolicy(consent: .decline, notifies: true, minutes: 30)
        let again = (try? JSONEncoder().encode(tuned)).flatMap {
            try? JSONDecoder().decode(AgentProfile.self, from: $0)
        }
        expect(again == tuned, "a policy round-trips")
    }

    // MARK: - Nothing resident

    /// No schedule, no banner: nothing is made, armed or observed.
    static func nothingIsResidentWithoutASchedule() {
        let rig = agent("Rig")
        let enabled = AgentSchedule(agentID: rig.id, name: "n", prompt: "p")
        var disabled = enabled
        disabled.isEnabled = false
        expect(
            !AgentBackgroundNeeds.of(aiEnabled: true, agents: [rig], schedules: []).any,
            "agents alone need nothing in the background")
        expect(
            !AgentBackgroundNeeds.of(aiEnabled: true, agents: [rig], schedules: [disabled]).any,
            "nor does a switched-off schedule")
        expect(
            !AgentBackgroundNeeds.of(aiEnabled: true, agents: [], schedules: [enabled]).any,
            "nor one whose agent is gone")
        expect(
            AgentBackgroundNeeds.of(aiEnabled: true, agents: [rig], schedules: [enabled])
                == AgentBackgroundNeeds(scheduler: true, notifier: false),
            "an enabled schedule needs the scheduler, and only it")
        var notifying = rig
        notifying.background = AgentBackgroundPolicy(notifies: true)
        expect(
            AgentBackgroundNeeds.of(aiEnabled: true, agents: [notifying], schedules: [])
                == AgentBackgroundNeeds(scheduler: false, notifier: true),
            "a banner opt-in needs the notifier, and only it")
        expect(
            !AgentBackgroundNeeds.of(aiEnabled: false, agents: [notifying], schedules: [enabled]).any,
            "AI off needs nothing at all")

        let directory = scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AgentStore(directory: directory)
        guard let owner = try? store.add(AgentProfile(name: "Rig", directory: "/tmp")) else { return }
        var started = 0
        let scheduler = AgentScheduler(store: store) { _ in
            started += 1
            return .started
        }
        scheduler.apply(settling: true)
        expect(!scheduler.isArmed && !scheduler.isObserving, "no schedule: no task and no observer")
        var off = AgentSchedule(agentID: owner.id, name: "n", prompt: "p", isEnabled: false)
        off = (try? store.saveSchedule(off, now: Date())) ?? off
        scheduler.apply(settling: false)
        expect(!scheduler.isArmed && !scheduler.isObserving, "a switched-off schedule arms nothing")
        off.isEnabled = true
        _ = try? store.saveSchedule(off, now: Date())
        scheduler.apply(settling: false)
        expect(scheduler.isArmed && scheduler.isObserving, "an enabled one sleeps toward its time")
        off.isEnabled = false
        _ = try? store.saveSchedule(off, now: Date())
        scheduler.apply(settling: false)
        expect(!scheduler.isArmed && !scheduler.isObserving, "switching it off tears both down")
        _ = try? store.saveSchedule({ var on = off; on.isEnabled = true; return on }(), now: Date())
        scheduler.apply(settling: false)
        scheduler.stop()
        expect(!scheduler.isArmed && !scheduler.isObserving, "and stop leaves nothing behind")
        expect(started == 0, "nothing ran early")
    }

    static func theSchedulerFiresWhatIsDue() {
        let directory = scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AgentStore(directory: directory)
        guard let owner = try? store.add(AgentProfile(name: "Rig", directory: "/tmp")) else { return }
        let created = at("2026-10-22T07:00:00Z")
        guard
            let schedule = try? store.saveSchedule(
                AgentSchedule(agentID: owner.id, name: "n", prompt: "p", rule: daily8, createdAt: created),
                now: created)
        else { return expect(false, "it saves") }
        var now = at("2026-10-22T08:01:00Z")
        var answer = AgentScheduler.Start.busy
        var starts: [UUID] = []
        let scheduler = AgentScheduler(
            store: store,
            start: {
                starts.append($0.id)
                return answer
            }, now: { now }, calendar: { calendar() })
        defer { scheduler.stop() }

        scheduler.apply(settling: true)
        expect(starts.isEmpty && scheduler.isArmed, "after launch, a due run waits out the settle")
        scheduler.apply(settling: false)
        expect(starts.isEmpty, "the settle holds through other changes")
        now = now.addingTimeInterval(AgentSchedulePolicy.settle)
        scheduler.apply(settling: false)
        expect(starts == [schedule.id], "then it starts")
        expect(store.baseline(for: schedule) == created, "a busy agent leaves the baseline")
        expect(!scheduler.isArmed && scheduler.isObserving, "and nothing spins on it: the run's end re-applies")
        answer = .started
        scheduler.apply(settling: false)
        expect(starts.count == 2 && store.baseline(for: schedule) == now, "a start moves the baseline to now")
        expect(scheduler.isArmed, "and arms for tomorrow")
        scheduler.apply(settling: false)
        expect(starts.count == 2, "it never runs twice for one occurrence")
    }

    // MARK: - The consent gate

    @Observable
    @MainActor
    final class DialogFlag {
        var isUp = true
    }

    static func consentQueuesBehindADialog() async {
        let flag = DialogFlag()
        let gate = AgentConsentGate()
        let order = Recorder()
        let first = Task { @MainActor in
            await gate.run(dialogIsUp: { flag.isUp }) {
                order.append("first")
                try? await Task.sleep(for: .milliseconds(30))
                order.append("first done")
            }
        }
        let second = Task { @MainActor in
            await gate.run(dialogIsUp: { flag.isUp }) { order.append("second") }
        }
        try? await Task.sleep(for: .milliseconds(50))
        expect(order.items.isEmpty && !gate.isIdle, "nobody asks over an open dialog, and nobody is dropped")
        flag.isUp = false
        await first.value
        await second.value
        expect(
            order.items == ["first", "first done", "second"],
            "they ask in turn once it closes, never two at once: \(order.items)")
        expect(gate.isIdle, "and nothing is held afterwards")
    }

    @MainActor
    final class Recorder {
        private(set) var items: [String] = []
        func append(_ item: String) { items.append(item) }
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.withLock { count } }
        func add() { lock.withLock { count += 1 } }
    }
}
