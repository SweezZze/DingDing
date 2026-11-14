import Foundation

/// Pure logic: when does an alarm trigger fire, and when is it expected to fire.
/// Kept free of UI / AlarmKit so it can be unit-tested (and mirrored on a server later).
enum TriggerLogic {
    /// Typical time between the start of two fights (fight + walkouts + breaks).
    static func slot(for fight: Fight) -> TimeInterval {
        fight.segment == "main" ? 22 * 60 : 18 * 60
    }

    /// Time between the end of a fight and the start of the next one (results + walkouts).
    static let walkoutGap: TimeInterval = 4 * 60
    /// Minimum remaining time we assume for a fight in progress.
    static let minRemaining: TimeInterval = 5 * 60

    /// Has `kind` been reached for the fight `fightId`?
    /// Returns nil when the fight is unknown or canceled (the alarm can't ring).
    /// A trigger also counts as reached when a *later* fight has already started,
    /// so a quick KO between two refreshes can never make us miss the alarm.
    static func isReached(_ kind: TriggerKind, fightId: String, in detail: EventDetail) -> Bool? {
        let active = detail.activeFights
        guard let pos = active.firstIndex(where: { $0.id == fightId }) else { return nil }

        func startedFrom(_ index: Int) -> Bool {
            active[max(index, 0)...].contains { $0.state != .scheduled }
        }

        switch kind {
        case .fightsBefore(let n):
            return startedFrom(pos - n)
        case .endOfPrevious:
            if pos > 0, active[pos - 1].state == .finished { return true }
            return startedFrom(pos)
        case .startOfFight:
            return startedFrom(pos)
        }
    }

    /// Pending triggers of `alarm` that should ring now.
    static func dueTriggers(for alarm: FightAlarm, in detail: EventDetail) -> [TriggerKind] {
        alarm.pendingTriggers
            .map(\.kind)
            .filter { isReached($0, fightId: alarm.id, in: detail) == true }
            .sorted()
    }

    /// Estimated start time of every active fight.
    /// - observedStarts: when DingDing first saw each fight go live (more precise than the schedule).
    static func estimatedStarts(for detail: EventDetail, now: Date = Date(), observedStarts: [String: Date] = [:]) -> [String: Date] {
        var result: [String: Date] = [:]
        var cursor: Date?
        let active = detail.activeFights

        for (index, fight) in active.enumerated() {
            let scheduled = max(fight.segmentStart, cursor ?? fight.segmentStart)
            switch fight.state {
            case .finished:
                let start = observedStarts[fight.id] ?? scheduled
                result[fight.id] = start
                let nextStarted = index + 1 < active.count && active[index + 1].state != .scheduled
                cursor = nextStarted ? start.addingTimeInterval(slot(for: fight)) : max(now.addingTimeInterval(walkoutGap), start)
            case .live:
                let start = observedStarts[fight.id] ?? min(scheduled, now)
                result[fight.id] = start
                cursor = max(start.addingTimeInterval(slot(for: fight)), now.addingTimeInterval(minRemaining))
            case .scheduled:
                // A fight that hasn't started can't start in the past.
                let start = detail.isLive ? max(scheduled, now) : scheduled
                result[fight.id] = start
                cursor = start.addingTimeInterval(slot(for: fight))
            case .canceled:
                break
            }
        }
        return result
    }

    /// Estimated moment a trigger will ring.
    static func estimatedDate(of kind: TriggerKind, fightId: String, in detail: EventDetail, starts: [String: Date]) -> Date? {
        let active = detail.activeFights
        guard let pos = active.firstIndex(where: { $0.id == fightId }), let mine = starts[fightId] else { return nil }
        switch kind {
        case .fightsBefore(let n):
            return starts[active[max(pos - n, 0)].id]
        case .endOfPrevious:
            return pos > 0 ? mine.addingTimeInterval(-walkoutGap) : mine
        case .startOfFight:
            return mine
        }
    }

    /// Number of fights that still have to start before the fight that rings `kind`
    /// (0 = the next fight to start — or the one in progress — rings the alarm).
    static func fightsRemaining(before kind: TriggerKind, fightId: String, in detail: EventDetail) -> Int? {
        let active = detail.activeFights
        guard let pos = active.firstIndex(where: { $0.id == fightId }) else { return nil }
        let targetIndex: Int
        switch kind {
        case .fightsBefore(let n): targetIndex = max(pos - n, 0)
        case .endOfPrevious, .startOfFight: targetIndex = pos
        }
        let started = active.lastIndex { $0.state != .scheduled }.map { $0 + 1 } ?? 0
        return max(targetIndex - started, 0)
    }

    /// When the backup AlarmKit alarm should ring.
    /// - While DingDing is alive and watching, the backup is kept at least `deadMan` in the
    ///   future: if iOS kills the app, the backup rings at most `deadMan` later.
    static func backupDate(estimate: Date, marginMinutes: Int, now: Date, watching: Bool, deadMan: TimeInterval = 15 * 60) -> Date {
        let early = estimate.addingTimeInterval(-Double(marginMinutes) * 60)
        if watching {
            return max(early, now.addingTimeInterval(deadMan))
        }
        return max(early, now.addingTimeInterval(60))
    }
}
