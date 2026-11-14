import Foundation

/// Replays a finished event at high speed so the whole alarm pipeline can be tested
/// without waiting for a real UFC night: each fight lasts `liveFor` seconds,
/// then there is a short break before the next one.
enum Simulation {
    static let idPrefix = "sim-"
    static let preDelay: TimeInterval = 45
    static let liveFor: TimeInterval = 20
    static let cycle: TimeInterval = 30

    struct Session: Codable, Hashable {
        var template: EventDetail
        var start: Date
    }

    static func makeSession(from finished: EventDetail, now: Date = Date()) -> Session {
        var template = finished
        template.summary.id = idPrefix + finished.summary.id
        template.summary.name = "Simulation · " + finished.summary.name
        template.summary.shortName = "Simulation"
        template.summary.date = now.addingTimeInterval(preDelay)
        for i in template.fights.indices {
            template.fights[i].segmentStart = now.addingTimeInterval(preDelay)
        }
        // Keep only fights that really happened, renumbered.
        template.fights = template.fights.filter { $0.state == .finished }
        for i in template.fights.indices { template.fights[i].order = i }
        return Session(template: template, start: now)
    }

    static func detail(for session: Session, now: Date = Date()) -> EventDetail {
        var detail = session.template
        let elapsed = now.timeIntervalSince(session.start) - preDelay
        let current = elapsed < 0 ? -1 : Int(elapsed / cycle)
        let within = elapsed - Double(max(current, 0)) * cycle

        for i in detail.fights.indices {
            let original = session.template.fights[i]
            if i < current || (i == current && within >= liveFor) {
                detail.fights[i].state = .finished
                detail.fights[i].result = original.result
            } else if i == current {
                detail.fights[i].state = .live
                detail.fights[i].result = nil
                detail.fights[i].round = min(Int(within / (liveFor / 3)) + 1, 3)
                detail.fights[i].clock = nil
                detail.fights[i].statusDetail = "Round \(detail.fights[i].round ?? 1)"
            } else {
                detail.fights[i].state = .scheduled
                detail.fights[i].result = nil
                detail.fights[i].round = nil
            }
        }
        if current < 0 {
            detail.summary.state = "pre"
        } else if current >= detail.fights.count {
            detail.summary.state = "post"
        } else {
            detail.summary.state = "in"
        }
        detail.fetchedAt = now
        return detail
    }

    static func isOver(_ session: Session, now: Date = Date()) -> Bool {
        now.timeIntervalSince(session.start) > preDelay + Double(session.template.fights.count) * cycle + 60
    }
}
