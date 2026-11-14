import Foundation

/// Sample data for SwiftUI previews in Xcode (not used by the real app).
@MainActor
enum PreviewData {
    static func fighter(_ id: String, _ name: String, _ record: String, _ espnId: String) -> Fighter {
        Fighter(id: id, name: name, shortName: name, record: record, country: nil,
                headshotURL: URL(string: "https://a.espncdn.com/i/headshots/mma/players/full/\(espnId).png"), flagURL: nil)
    }

    static let detail: EventDetail = {
        let base = Calendar.current.date(bySettingHour: 23, minute: 0, second: 0, of: Date())!
        let summary = EventSummary(id: "preview-334", league: .ufc, name: "UFC 334: Gane vs. Hokit", shortName: "UFC 334",
                                   date: base, state: "in", venue: "Madison Square Garden")
        let prelims = base.addingTimeInterval(2 * 3600)
        let main = base.addingTimeInterval(4 * 3600)
        let raw: [(String, String, String, String, String, String, String, String, Date, String?, FightState)] = [
            ("p1", "prelims1", "Prelims", "Welters", "Charles Radtke", "4416297", "Stephen Thompson", "2615077", prelims, nil, .finished),
            ("p2", "prelims1", "Prelims", "Légers", "Chris Duncan", "4867356", "Drew Dober", "2951202", prelims, nil, .live),
            ("m5", "main", "Main card", "Mouches", "Luis Gurule", "5218137", "Bilal Hasan", "5264405", main, nil, .scheduled),
            ("m4", "main", "Main card", "Welters", "Kevin Holland", "3943695", "Uroš Medić", "4685870", main, nil, .scheduled),
            ("m3", "main", "Main card", "Moyens", "Yousri Belgaroui", "5149815", "Caio Borralho", "4835137", main, nil, .scheduled),
            ("m2", "main", "Main card", "Coqs (F)", "Amanda Nunes", "2516131", "Kayla Harrison", "4332765", main, "Co-Main Event - Title Fight", .scheduled),
            ("m1", "main", "Main card", "Lourds", "Josh Hokit", "4049391", "Ciryl Gane", "4426000", main, "Main Event - Title Fight", .scheduled),
        ]
        let fights = raw.enumerated().map { index, f in
            Fight(id: f.0, order: index, segment: f.1, segmentName: f.2, segmentStart: f.8, weightClass: f.3, note: f.9,
                  fighters: [fighter("a\(f.0)", f.4, "20-5-0", f.5), fighter("b\(f.0)", f.6, "18-3-0", f.7)],
                  state: f.10, round: f.10 == .live ? 2 : nil, clock: nil, statusDetail: nil,
                  result: f.10 == .finished ? FightResult(winnerId: "bp1", method: "KO/TKO", detail: "Punch", round: 2, clock: "3:12") : nil)
        }
        return EventDetail(summary: summary, fights: fights, fetchedAt: Date())
    }()

    static let store: AppStore = {
        let store = AppStore(preview: true)
        store.events = [detail.summary]
        store.details = [detail.id: detail]
        store.alarms = ["m1": FightAlarm(id: "m1", eventId: detail.id, league: .ufc, eventName: detail.summary.name,
                                         fightLabel: "Hokit vs Gane", fighterIds: ["am1", "bm1"],
                                         triggers: [AlarmTrigger(kind: .fightsBefore(1)), AlarmTrigger(kind: .endOfPrevious)],
                                         fromFavorite: false, estimatedStart: nil)]
        store.favorites = ["bm1": FavoriteFighter(id: "bm1", name: "Ciryl Gane", headshotURL: detail.fights.last?.fighters.last?.headshotURL)]
        return store
    }()
}
