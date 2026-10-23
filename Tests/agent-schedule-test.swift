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
        launcherRowsHaveTheirOwnIDs()
        addressesParse()
        dailyOccurrences()
        weekdaysSkipTheWeekend()
        everyNHoursRepeatsDaily()
        daylightSavingIsSane()
        verdicts()
        aWeekAwayRunsOnce()
        ledgerIndicator()
        oneItemForRunsAndSessions()
        runTitles()
        consentModes()
        consentPlans()
        await consentIsPutAsTheRunAllows()
        await anUnattendedRefusalIsReported()
        runEndings()
        spendPolicy()
        cappedRunsAreCounted()
        spendPersists()
        noteBlocks()
        await aScheduledAnswerLandsInItsNote()
        schedulesPersist()
        profilesWithoutBackgroundDecode()
        nothingIsResidentWithoutASchedule()
        theSchedulerFiresWhatIsDue()
        aDueTimePassedAsleepWaitsForTheSettle()
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

    static func launcherRowsHaveTheirOwnIDs() {
        let rig = agent("Rig")
        expect(rig.entryID.hasPrefix(AgentProfile.entryIDPrefix), "an agent's row has the agents' prefix")
        expect(AgentProfile.id(fromEntryID: rig.entryID) == rig.id, "and its id reads back")
        let id = rig.id.uuidString.lowercased()
        expect(AgentProfile.id(fromEntryID: "agent:" + id) == nil, "an @handle task row is not an agent's row")
        expect(AgentProfile.id(fromEntryID: "agent-pick:" + id) == nil, "nor is a Choose Agent row")
        expect(AgentProfile.id(fromEntryID: AgentProfile.entryIDPrefix + "nope") == nil, "a broken id names nobody")
        var renamed = rig
        renamed.name = "Renamed"
        expect(renamed.entryID == rig.entryID, "a rename keeps the row's favorite, alias and chord")
    }

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
        expect(ledger.indicator == .waiting(1), "a run waiting for an answer beats running")
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

    static func oneItemForRunsAndSessions() {
        typealias Indicator = AgentRunLedger.Indicator
        expect(Indicator.of(waiting: 0, running: 0, failed: false, done: false) == .hidden, "nothing: no item")
        expect(Indicator.of(waiting: 2, running: 3, failed: true, done: true) == .waiting(2), "waiting first")
        expect(Indicator.of(waiting: 0, running: 3, failed: true, done: true) == .running(3), "then working")
        expect(Indicator.of(waiting: 0, running: 0, failed: true, done: true) == .failed, "then a failure")
        expect(Indicator.of(waiting: 0, running: 0, failed: false, done: true) == .done, "then a success")
        expect(Indicator.waiting(1).merged(with: .waiting(2)) == .waiting(3), "waiting runs and sessions add up")
        expect(Indicator.running(1).merged(with: .running(1)) == .running(2), "so do working ones")
        expect(Indicator.running(4).merged(with: .waiting(1)) == .waiting(1), "a session waiting beats runs working")
        expect(Indicator.done.merged(with: .failed) == .failed, "an unseen failure beats an unseen success")
        expect(Indicator.hidden.merged(with: .done) == .done, "one source alone keeps the item")
        expect(Indicator.hidden.merged(with: .hidden) == .hidden, "and with neither it goes")
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

    static func consentPlans() {
        let chat = AgentConsentPlan(mode: .foreground, refusal: 2)
        expect(chat == .inFront && chat.activates && chat.defaultIndex == 0, "a chat's ask comes forward on Allow")
        expect(!chat.countsDecline(answer: 2) && !chat.countsDecline(answer: nil), "and is never counted")
        let quiet = AgentConsentPlan(mode: .ask, refusal: 2)
        expect(
            quiet == .quiet(refusal: 2) && !quiet.activates && quiet.defaultIndex == 2,
            "an unattended ask stays behind the app in front, with Return on Don't Allow")
        expect(
            quiet.countsDecline(answer: 2) && quiet.countsDecline(answer: nil) && !quiet.countsDecline(answer: 0),
            "a refusal or no answer counts; an Allow does not")
        expect(AgentConsentPlan(mode: .ask, refusal: nil) == .refused, "nothing to put on Return: refused unasked")
        expect(AgentConsentPlan(mode: .decline, refusal: 2) == .refused, "decline refuses unasked")
        expect(AgentConsentPlan.refused.countsDecline(answer: nil), "and counts")
    }

    @MainActor
    final class ConsentProbe {
        var mode = AgentConsentMode.ask
        var answer: Int? = 2
        var presented: [AgentConsentPlan] = []
        var waiting: [Bool] = []
        var declined = 0

        func ask(_ gate: AgentConsentGate, refusal: Int? = 2, dialog: DialogFlag? = nil) async -> Int? {
            await gate.ask(
                refusal: refusal, mode: { self.mode }, dialogIsUp: { dialog?.isUp ?? false },
                waiting: { self.waiting.append($0) }, declined: { self.declined += 1 },
                present: { plan in
                    self.presented.append(plan)
                    return self.answer
                })
        }
    }

    /// The gate's whole ask: what is shown, when it is refused unseen, and what the row counts.
    static func consentIsPutAsTheRunAllows() async {
        let gate = AgentConsentGate()
        let inFront = ConsentProbe()
        inFront.mode = .foreground
        let chatAnswer = await inFront.ask(gate)
        expect(
            chatAnswer == 2 && inFront.presented == [.inFront] && inFront.declined == 0 && inFront.waiting.isEmpty,
            "a chat's ask is shown in front, and its refusal is the user's own, not counted")

        let quiet = ConsentProbe()
        var answer = await quiet.ask(gate)
        expect(quiet.presented == [.quiet(refusal: 2)], "an unattended ask is shown quietly, Return on refusal")
        expect(answer == 2 && quiet.declined == 1, "a refusal is counted on the run's row")
        expect(quiet.waiting == [true, false], "and the row waits only while it is asked")
        quiet.answer = 0
        answer = await quiet.ask(gate)
        expect(answer == 0 && quiet.declined == 1, "an Allow is not counted")

        let declining = ConsentProbe()
        declining.mode = .decline
        answer = await declining.ask(gate)
        expect(
            answer == nil && declining.presented.isEmpty && declining.declined == 1 && declining.waiting.isEmpty,
            "decline refuses without a dialog, and counts it")
        let noRefusal = ConsentProbe()
        answer = await noRefusal.ask(gate, refusal: nil)
        expect(answer == nil && noRefusal.presented.isEmpty && noRefusal.declined == 1, "no refusal to offer: refused")

        let flag = DialogFlag()
        let leaving = ConsentProbe()
        let queued = Task { @MainActor in await leaving.ask(gate, dialog: flag) }
        try? await Task.sleep(for: .milliseconds(30))
        expect(leaving.presented.isEmpty && leaving.waiting == [true], "queued behind a dialog, the row waits")
        leaving.mode = .decline
        flag.isUp = false
        answer = await queued.value
        expect(
            answer == nil && leaving.presented.isEmpty && leaving.declined == 1,
            "whoever was at the Mac left during the wait: refused unseen, and counted")
        expect(leaving.waiting == [true, false], "and the row stops waiting")

        flag.isUp = true
        let stopped = ConsentProbe()
        let cancelled = Task { @MainActor in await stopped.ask(gate, dialog: flag) }
        try? await Task.sleep(for: .milliseconds(30))
        cancelled.cancel()
        flag.isUp = false
        answer = await cancelled.value
        expect(
            answer == nil && stopped.presented.isEmpty && stopped.declined == 0,
            "Stop during the wait shows nothing and counts nothing")
        expect(gate.isIdle, "and the gate holds nothing afterwards")
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

    static func runEndings() {
        expect(AgentRun.endState(complete: true, reply: "ok", stoppedAfter: nil) == .done, "a complete answer is done")
        expect(
            AgentRun.endState(complete: false, reply: "Working\nError: rate limited\n", stoppedAfter: nil)
                == .failed("Error: rate limited"),
            "a broken reply fails with its last line")
        expect(
            AgentRun.endState(complete: false, reply: "Working", stoppedAfter: 15)
                == .failed("Stopped after 15 minutes"),
            "the watchdog's stop says so")
        expect(
            AgentRun.endState(complete: false, reply: nil, stoppedAfter: nil)
                == .failed("The response ended unexpectedly."),
            "no reply at all still says something")
        if case .failed(let reason) = AgentRun.endState(
            complete: false, reply: String(repeating: "x", count: 300), stoppedAfter: nil)
        {
            expect(reason.count == 120 && reason.hasSuffix("…"), "a long line is cut for the row")
        } else {
            expect(false, "a long line fails")
        }
        expect(AgentBackgroundPolicy(minutes: 0).limitMinutes == 5, "a hand-edited limit can't go under five minutes")
        expect(AgentBackgroundPolicy(minutes: 999).limitMinutes == 60, "nor over an hour")
        expect(AgentBackgroundPolicy().limitMinutes == 15, "and the default is a quarter of an hour")
    }

    // MARK: - Spend cap

    static func spendPolicy() {
        let utc = calendar()
        let today = AgentSpendPolicy.day(of: at("2026-10-22T23:59:00Z"), calendar: utc)
        expect(today == "2026-10-22", "a day is the local calendar's, got \(today)")
        expect(
            AgentSpendPolicy.day(of: at("2026-10-22T23:59:00Z"), calendar: calendar("Asia/Tokyo")) == "2026-10-23",
            "so it turns at the Mac's own midnight")
        let none = AgentScheduleSpend()
        expect(AgentSpendPolicy.allowsStart(none, on: today), "no cap holds nothing")
        expect(!AgentSpendPolicy.isOver(none, on: today, running: 1_000), "and stops nothing")
        let five = AgentScheduleSpend(capUSD: 5, day: today, spentUSD: 4.99)
        expect(AgentSpendPolicy.allowsStart(five, on: today), "below the cap a due run starts")
        expect(!AgentSpendPolicy.isOver(five, on: today, running: 0.01), "reaching the cap exactly is not past it")
        expect(AgentSpendPolicy.isOver(five, on: today, running: 0.02), "a running turn past it is")
        let spent = AgentSpendPolicy.adding(0.01, to: five, on: today)
        expect(!AgentSpendPolicy.allowsStart(spent, on: today), "at the cap the next due run does not start")
        expect(AgentSpendPolicy.allowsStart(spent, on: "2026-10-23"), "and the next day starts afresh")
        expect(AgentSpendPolicy.spent(spent, on: "2026-10-23") == 0, "yesterday's total counts for nothing")
        let tomorrow = AgentSpendPolicy.adding(0.5, to: spent, on: "2026-10-23")
        expect(
            tomorrow.day == "2026-10-23" && tomorrow.spentUSD == 0.5 && tomorrow.capUSD == 5,
            "a cost on a new day starts its total and keeps the cap")
        expect(AgentSpendPolicy.adding(-3, to: none, on: today).spentUSD == 0, "a negative cost adds nothing")
        expect(AgentSpendPolicy.adding(.nan, to: none, on: today).spentUSD == 0, "nor does a broken one")
        let zero = AgentScheduleSpend(capUSD: 0)
        expect(!AgentSpendPolicy.allowsStart(zero, on: today), "a cap of zero holds every schedule")
        expect(AgentSpendPolicy.cap(-1) == nil && AgentSpendPolicy.cap(.infinity) == nil, "a nonsense cap is none")
        expect(AgentSpendPolicy.cap(2.5) == 2.5 && AgentSpendPolicy.cap(nil) == nil, "a real one is kept")
        let posix = Locale(identifier: "en_US")
        expect(AgentSpendPolicy.amount(5, locale: posix) == "$5.00", "dollars in the reader's style")
        expect(
            AgentSpendPolicy.notStarted(cap: 5, locale: posix)
                == "Not started: scheduled runs reached today's cap of $5.00",
            "a held run says why it never ran")
        expect(
            AgentSpendPolicy.stopped(cap: 5, locale: posix) == "Stopped at today's spend cap of $5.00",
            "and a stopped one why it stopped")
        let partial = try? JSONDecoder().decode(AgentScheduleSpend.self, from: Data(#"{"capUSD":3}"#.utf8))
        expect(partial == AgentScheduleSpend(capUSD: 3), "every field of the file is optional")
    }

    static func cappedRunsAreCounted() {
        let scheduled = UUID()
        expect(AgentRun.Origin.schedule(scheduled, manual: false).isCapped, "a schedule's own run is capped")
        expect(!AgentRun.Origin.schedule(scheduled, manual: true).isCapped, "Run Now is a gesture, not capped")
        expect(!AgentRun.Origin.launcher.isCapped, "and neither is an @handle run")
        var ledger = AgentRunLedger()
        var capped = run(origin: .schedule(scheduled, manual: false))
        capped.cost = 0.4
        var manual = run(origin: .schedule(scheduled, manual: true))
        manual.cost = 9
        var finished = run(state: .done, origin: .schedule(UUID(), manual: false))
        finished.cost = 7
        ledger.begin(capped)
        ledger.begin(manual)
        ledger.begin(finished)
        expect(abs(ledger.cappedSpend - 0.4) < 1e-12, "only capped runs still going count as running spend")
        expect(capped.spend(final: 0.6) == 0.6, "a capped run's final cost is what the day adds")
        expect(capped.spend(final: nil) == 0.4, "one cut off before its final cost adds its last report")
        expect(run(origin: .schedule(scheduled, manual: false)).spend(final: nil) == nil, "none reported, none added")
        expect(manual.spend(final: 9) == nil, "and a Run Now never adds to the day")
        expect(
            AgentRun.endState(complete: false, reply: "Working", stoppedAfter: 15, capped: "Stopped at the cap")
                == .failed("Stopped at the cap"),
            "a run the cap stopped says so, ahead of any other reason")
        expect(
            AgentRun.endState(complete: true, reply: "ok", stoppedAfter: nil, capped: "Stopped at the cap") == .done,
            "an answer that completed before the stop landed is still done")
    }

    static func spendPersists() {
        let directory = scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AgentStore(directory: directory)
        store.load()
        expect(store.scheduleSpend == AgentScheduleSpend(), "no file: no cap, nothing spent")
        expect((try? store.setScheduleCap(5)) != nil, "a cap saves")
        store.recordScheduledSpend(1.25, on: "2026-10-22")
        let reloaded = AgentStore(directory: directory)
        reloaded.load()
        expect(
            reloaded.scheduleSpend == AgentScheduleSpend(capUSD: 5, day: "2026-10-22", spentUSD: 1.25),
            "the cap and the day's spend survive a relaunch")
        expect((try? reloaded.setScheduleCap(-2)) != nil, "clearing the cap saves")
        expect(reloaded.scheduleSpend.capUSD == nil && reloaded.scheduleSpend.spentUSD == 1.25, "and keeps the spend")

        let file = directory.appendingPathComponent("agent-schedule-spend.json")
        try? Data("not json".utf8).write(to: file)
        let broken = AgentStore(directory: directory)
        broken.load()
        expect(broken.scheduleSpend.capUSD == 0, "a file that won't read caps at zero, so nothing scheduled starts")
        broken.recordScheduledSpend(1, on: "2026-10-22")
        expect((try? Data(contentsOf: file)) == Data("not json".utf8), "and a run never writes over it")
        expect((try? broken.setScheduleCap(3)) != nil, "setting the cap again is the user's gesture")
        let fixed = AgentStore(directory: directory)
        fixed.load()
        expect(fixed.scheduleSpend.capUSD == 3, "and it writes a file that reads")
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

    /// The note on disk, or the one open in Notes through its store, which keeps the user's edit.
    static func aScheduledAnswerLandsInItsNote() async {
        let directory = scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = NotesRepository(notesDirectory: directory, trashOperation: { _ in })
        guard let digest = try? repository.create(title: "Digest"),
            (try? repository.save(id: digest.id, source: "Yesterday\n")) != nil
        else { return expect(false, "the fixture note is written") }
        func read(_ title: String) -> String? {
            try? String(contentsOf: directory.appendingPathComponent(title + ".md"), encoding: .utf8)
        }
        let closed = NotesStore(repository: repository, loadSelection: { digest.id })
        var problem = await AgentNoteWriter.append("## Today", toNoteTitled: "Digest", store: closed)
        expect(problem == nil && read("Digest") == "Yesterday\n\n## Today\n", "a closed note gets the section on disk")
        problem = await AgentNoteWriter.append("## Today", toNoteTitled: "Fresh", store: closed)
        expect(problem == nil && read("Fresh") == "## Today\n", "a missing note is made for it")
        problem = await AgentNoteWriter.append("## Today", toNoteTitled: "a/b", store: closed)
        expect(problem != nil, "a title no file can carry is reported for the run's row")

        let open = NotesStore(repository: repository, loadSelection: { digest.id })
        guard await open.start(), open.activeID == digest.id else { return expect(false, "Notes opens the digest") }
        open.updateSource(open.source + "typed by hand\n")
        problem = await AgentNoteWriter.append("## Later", toNoteTitled: "Digest", store: open)
        expect(problem == nil, "the open note takes the section")
        expect(
            open.source == "Yesterday\n\n## Today\ntyped by hand\n\n## Later\n",
            "through its editor, after the user's unsaved edit")
        _ = await open.flush()
        expect(read("Digest") == open.source, "and the editor's save writes both")
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

    /// The Mac slept through 08:00: whatever reaches the scheduler first after it waits 60 s.
    static func aDueTimePassedAsleepWaitsForTheSettle() {
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
        var now = at("2026-10-22T07:30:00Z")
        var slept = Duration.seconds(12)
        var starts: [UUID] = []
        let scheduler = AgentScheduler(
            store: store,
            start: {
                starts.append($0.id)
                return .started
            }, now: { now }, calendar: { calendar() }, slept: { slept })
        defer { scheduler.stop() }

        scheduler.apply(settling: false)
        expect(scheduler.isArmed && starts.isEmpty, "awake before 08:00, it sleeps toward it")
        scheduler.suspend()
        expect(!scheduler.isArmed && scheduler.isObserving, "nothing ticks while the Mac sleeps, but the wake is heard")
        now = at("2026-10-22T08:30:00Z")
        slept += .seconds(3_590)
        scheduler.apply(settling: false)
        expect(starts.isEmpty, "a clock change or a run's end before the wake still waits out the settle")
        expect(scheduler.isArmed, "and arms for the settle's end")
        now = now.addingTimeInterval(5)
        scheduler.apply(settling: true)
        expect(starts.isEmpty, "the wake itself, arriving second, waits too")
        now = now.addingTimeInterval(AgentSchedulePolicy.settle)
        scheduler.apply(settling: false)
        expect(starts == [schedule.id], "then the missed 08:00 runs once")
        expect(store.baseline(for: schedule) == now, "and counts as done for today")
        now = at("2026-10-23T08:00:05Z")
        slept += .milliseconds(200)
        scheduler.apply(settling: false)
        expect(starts.count == 2, "a hiccup under a second is not a sleep: the next 08:00 runs on time")
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
