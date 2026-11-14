import XCTest
@testable import DingDing

final class ParserTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json"))
        return try Data(contentsOf: url)
    }

    private let summary = EventSummary(id: "600061400", league: .ufc, name: "UFC 334", shortName: "UFC 334",
                                       date: Date(timeIntervalSince1970: 0), state: "pre", venue: nil)

    func testUpcomingCardIsInNightOrder() throws {
        let detail = try ESPNParser.parseFightCenter(fixture("fightcenter_upcoming"), summary: summary)
        XCTAssertEqual(detail.fights.count, 13)
        // First fight of the night: early prelims, last listed by ESPN (matchNumber 13).
        XCTAssertEqual(detail.fights.first?.segment, "prelims2")
        XCTAssertEqual(detail.fights.first?.fighters.map(\.name).sorted(), ["Evan Elder", "Samuel Sanches"])
        // Main event last.
        XCTAssertEqual(detail.fights.last?.segment, "main")
        XCTAssertTrue(detail.fights.last?.isMainEvent == true)
        XCTAssertEqual(Set(detail.fights.last!.fighters.map(\.name)), ["Ciryl Gane", "Josh Hokit"])
        // Segments chronological.
        XCTAssertEqual(detail.segments.map(\.key), ["prelims2", "prelims1", "main"])
        XCTAssertTrue(detail.fights.allSatisfy { $0.state == .scheduled })
        XCTAssertEqual(detail.fights.map(\.order), Array(0..<13))
        XCTAssertNotNil(detail.fights.last?.fighters.first?.headshotURL)
    }

    func testFinishedCardHasResults() throws {
        let detail = try ESPNParser.parseFightCenter(fixture("fightcenter_final"), summary: summary)
        XCTAssertEqual(detail.fights.count, 14)
        XCTAssertTrue(detail.isOver)
        let main = try XCTUnwrap(detail.fights.last)
        XCTAssertEqual(main.result?.method, "KO/TKO")
        XCTAssertEqual(main.result?.round, 3)
        let winner = main.fighters.first { $0.id == main.result?.winnerId }
        XCTAssertEqual(winner?.name, "Johnny Walker")
        XCTAssertEqual(detail.summary.state, "post")
    }

    func testScoreboard() throws {
        let events = try ESPNParser.parseScoreboard(fixture("scoreboard_ufc"), league: .ufc)
        XCTAssertEqual(events.first?.name, "UFC 334: Gane vs. Hokit")
        XCTAssertEqual(events.first?.date, ESPNParser.date("2026-11-14T22:00Z"))
    }

    func testDates() {
        XCTAssertNotNil(ESPNParser.date("2026-11-15T02:00:00.000+00:00"))
        XCTAssertNotNil(ESPNParser.date("2026-11-14T22:00Z"))
        XCTAssertNotNil(ESPNParser.date("2026-11-14T22:00:00Z"))
    }

    func testStatusMapping() {
        func s(_ name: String, _ state: String, _ completed: Bool) -> [String: Any] {
            ["type": ["name": name, "state": state, "completed": completed]]
        }
        XCTAssertEqual(ESPNParser.parseState(s("STATUS_SCHEDULED", "pre", false)), .scheduled)
        XCTAssertEqual(ESPNParser.parseState(s("STATUS_IN_PROGRESS", "in", false)), .live)
        XCTAssertEqual(ESPNParser.parseState(s("STATUS_END_OF_ROUND", "in", false)), .live)
        XCTAssertEqual(ESPNParser.parseState(s("STATUS_FINAL", "post", true)), .finished)
        XCTAssertEqual(ESPNParser.parseState(s("STATUS_CANCELED", "post", false)), .canceled)
        XCTAssertEqual(ESPNParser.parseState(s("STATUS_POSTPONED", "pre", false)), .canceled)
    }

    func testFrenchWeights() {
        XCTAssertEqual(ESPNParser.frenchWeight("Heavyweight"), "Lourds")
        XCTAssertEqual(ESPNParser.frenchWeight("Women's Bantamweight"), "Coqs (F)")
        XCTAssertEqual(ESPNParser.frenchWeight("W Strawweight"), "Pailles (F)")
        XCTAssertEqual(ESPNParser.frenchWeight("Openweight"), "Openweight")
    }
}

final class TriggerLogicTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    /// 6 fights: f0…f2 prelims (t0), f3…f5 main (t0 + 2h). States given by `states`.
    func card(_ states: [FightState]) -> EventDetail {
        let summary = EventSummary(id: "e", league: .ufc, name: "UFC", shortName: "UFC", date: t0, state: "pre", venue: nil)
        let fights = states.enumerated().map { i, state in
            Fight(id: "f\(i)", order: i, segment: i < 3 ? "prelims1" : "main", segmentName: "", segmentStart: i < 3 ? t0 : t0.addingTimeInterval(7200),
                  weightClass: "", note: nil, fighters: [], state: state, round: nil, clock: nil, statusDetail: nil, result: nil)
        }
        return EventDetail(summary: summary, fights: fights, fetchedAt: t0)
    }

    func alarm(_ fight: String, _ kinds: [TriggerKind]) -> FightAlarm {
        FightAlarm(id: fight, eventId: "e", league: .ufc, eventName: "", fightLabel: "X vs Y", fighterIds: [],
                   triggers: kinds.map { AlarmTrigger(kind: $0) }, fromFavorite: false, estimatedStart: nil)
    }

    func testFightsBefore() {
        let s: FightState = .scheduled
        XCTAssertEqual(TriggerLogic.isReached(.fightsBefore(1), fightId: "f4", in: card([.finished, .finished, .finished, s, s, s])), false)
        XCTAssertEqual(TriggerLogic.isReached(.fightsBefore(1), fightId: "f4", in: card([.finished, .finished, .finished, .live, s, s])), true)
        XCTAssertEqual(TriggerLogic.isReached(.fightsBefore(2), fightId: "f4", in: card([.finished, .finished, .live, s, s, s])), true)
        XCTAssertEqual(TriggerLogic.isReached(.fightsBefore(3), fightId: "f4", in: card([.finished, .live, s, s, s, s])), true)
        XCTAssertEqual(TriggerLogic.isReached(.fightsBefore(3), fightId: "f4", in: card([.live, s, s, s, s, s])), false)
    }

    func testMissedRefreshStillRings() {
        // Previous fight ended by quick KO between two refreshes and my fight already started.
        let detail = card([.finished, .finished, .finished, .finished, .live, .scheduled])
        XCTAssertEqual(TriggerLogic.isReached(.fightsBefore(1), fightId: "f4", in: detail), true)
        XCTAssertEqual(TriggerLogic.isReached(.endOfPrevious, fightId: "f4", in: detail), true)
        XCTAssertEqual(TriggerLogic.dueTriggers(for: alarm("f4", [.fightsBefore(2), .endOfPrevious, .startOfFight]), in: detail),
                       [.fightsBefore(2), .endOfPrevious, .startOfFight])
    }

    func testEndOfPrevious() {
        XCTAssertEqual(TriggerLogic.isReached(.endOfPrevious, fightId: "f4", in: card([.finished, .finished, .finished, .live, .scheduled, .scheduled])), false)
        XCTAssertEqual(TriggerLogic.isReached(.endOfPrevious, fightId: "f4", in: card([.finished, .finished, .finished, .finished, .scheduled, .scheduled])), true)
    }

    func testCanceledFightsAreSkipped() {
        // f3 canceled: the fight before f4 is f2.
        let detail = card([.finished, .finished, .live, .canceled, .scheduled, .scheduled])
        XCTAssertEqual(TriggerLogic.isReached(.fightsBefore(1), fightId: "f4", in: detail), true)
        XCTAssertNil(TriggerLogic.isReached(.startOfFight, fightId: "f3", in: detail))
    }

    func testFirstFightOfNight() {
        // Not enough fights before: rings when the night starts.
        let detail = card([.live, .scheduled, .scheduled, .scheduled, .scheduled, .scheduled])
        XCTAssertEqual(TriggerLogic.isReached(.fightsBefore(3), fightId: "f1", in: detail), true)
        XCTAssertEqual(TriggerLogic.isReached(.fightsBefore(3), fightId: "f1", in: card(Array(repeating: .scheduled, count: 6))), false)
    }

    func testFiredTriggersAreNotDueAgain() {
        var a = alarm("f4", [.fightsBefore(1)])
        a.triggers[0].firedAt = t0
        XCTAssertEqual(TriggerLogic.dueTriggers(for: a, in: card([.finished, .finished, .finished, .live, .scheduled, .scheduled])), [])
    }

    func testEstimatesBeforeEvent() {
        let starts = TriggerLogic.estimatedStarts(for: card(Array(repeating: .scheduled, count: 6)), now: t0.addingTimeInterval(-3600))
        XCTAssertEqual(starts["f0"], t0)
        XCTAssertEqual(starts["f1"], t0.addingTimeInterval(18 * 60))
        XCTAssertEqual(starts["f2"], t0.addingTimeInterval(36 * 60))
        // Main card starts at its scheduled time, not earlier.
        XCTAssertEqual(starts["f3"], t0.addingTimeInterval(7200))
        XCTAssertEqual(starts["f4"], t0.addingTimeInterval(7200 + 22 * 60))
    }

    func testEstimatesFollowLiveDelays() {
        // Prelims running late: f2 started at t0 + 2h10 → main card can't start on time.
        let now = t0.addingTimeInterval(2 * 3600 + 15 * 60)
        let detail = card([.finished, .finished, .live, .scheduled, .scheduled, .scheduled])
        let starts = TriggerLogic.estimatedStarts(for: detail, now: now, observedStarts: ["f2": t0.addingTimeInterval(2 * 3600 + 10 * 60)])
        XCTAssertEqual(starts["f3"], t0.addingTimeInterval(2 * 3600 + 28 * 60))
        XCTAssertEqual(starts["f4"], t0.addingTimeInterval(2 * 3600 + 50 * 60))
        // Trigger estimates.
        XCTAssertEqual(TriggerLogic.estimatedDate(of: .fightsBefore(1), fightId: "f4", in: detail, starts: starts), starts["f3"])
        XCTAssertEqual(TriggerLogic.estimatedDate(of: .endOfPrevious, fightId: "f4", in: detail, starts: starts), starts["f4"]!.addingTimeInterval(-240))
    }

    func testFightsRemaining() {
        let detail = card([.finished, .live, .scheduled, .scheduled, .scheduled, .scheduled])
        // f1 live (started = 2). Alarm "combat d'avant" for f5 rings when f4 starts: f2, f3 still to start first.
        XCTAssertEqual(TriggerLogic.fightsRemaining(before: .fightsBefore(1), fightId: "f5", in: detail), 2)
        XCTAssertEqual(TriggerLogic.fightsRemaining(before: .fightsBefore(1), fightId: "f3", in: detail), 0)
        XCTAssertEqual(TriggerLogic.fightsRemaining(before: .startOfFight, fightId: "f5", in: detail), 3)
    }

    func testBackupDeadMan() {
        let now = t0
        let estimate = t0.addingTimeInterval(3600)
        // Not watching: estimate minus margin.
        XCTAssertEqual(TriggerLogic.backupDate(estimate: estimate, marginMinutes: 10, now: now, watching: false), t0.addingTimeInterval(3000))
        // Watching, estimate far: same.
        XCTAssertEqual(TriggerLogic.backupDate(estimate: estimate, marginMinutes: 10, now: now, watching: true), t0.addingTimeInterval(3000))
        // Watching, estimate passed but fight not there yet: pushed 15 min ahead.
        XCTAssertEqual(TriggerLogic.backupDate(estimate: t0.addingTimeInterval(-600), marginMinutes: 10, now: now, watching: true), t0.addingTimeInterval(900))
    }
}

final class SimulationTests: XCTestCase {
    func testReplayProgression() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "fightcenter_final", withExtension: "json"))
        let summary = EventSummary(id: "x", league: .ufc, name: "UFC FN", shortName: "UFC FN", date: Date(), state: "post", venue: nil)
        let finished = try ESPNParser.parseFightCenter(Data(contentsOf: url), summary: summary)
        let start = Date(timeIntervalSince1970: 1_000_000)
        let session = Simulation.makeSession(from: finished, now: start)
        XCTAssertTrue(session.template.summary.isSimulation)

        let before = Simulation.detail(for: session, now: start.addingTimeInterval(10))
        XCTAssertTrue(before.fights.allSatisfy { $0.state == .scheduled })

        let firstLive = Simulation.detail(for: session, now: start.addingTimeInterval(Simulation.preDelay + 1))
        XCTAssertEqual(firstLive.fights[0].state, .live)
        XCTAssertNil(firstLive.fights[0].result)

        let third = Simulation.detail(for: session, now: start.addingTimeInterval(Simulation.preDelay + 2 * Simulation.cycle + 1))
        XCTAssertEqual(third.fights[0].state, .finished)
        XCTAssertNotNil(third.fights[0].result)
        XCTAssertEqual(third.fights[2].state, .live)
        XCTAssertEqual(third.fights[3].state, .scheduled)

        let end = Simulation.detail(for: session, now: start.addingTimeInterval(10_000))
        XCTAssertTrue(end.isOver)
    }
}
