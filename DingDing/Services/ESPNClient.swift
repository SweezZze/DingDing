import Foundation

/// Reads ESPN's public (unofficial) MMA endpoints.
/// - scoreboard: list of events for a date range
/// - fightcenter: full card of one event, with live status and results
struct ESPNClient {
    enum ClientError: Error, LocalizedError {
        case badStatus(Int)
        case malformed

        var errorDescription: String? {
            switch self {
            case .badStatus(let code): "ESPN a répondu \(code)"
            case .malformed: "Réponse ESPN illisible"
            }
        }
    }

    var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    func upcomingEvents(league: League, from: Date = Date().addingTimeInterval(-36 * 3600), days: Int = 90) async throws -> [EventSummary] {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        let start = formatter.string(from: from)
        let end = formatter.string(from: from.addingTimeInterval(Double(days) * 86400))
        let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/mma/\(league.rawValue)/scoreboard?dates=\(start)-\(end)&limit=100")!
        let data = try await get(url)
        return try ESPNParser.parseScoreboard(data, league: league)
    }

    func eventDetail(_ summary: EventSummary) async throws -> EventDetail {
        let url = URL(string: "https://site.web.api.espn.com/apis/common/v3/sports/mma/\(summary.league.rawValue)/fightcenter/\(summary.id)?region=us&lang=en")!
        let data = try await get(url)
        return try ESPNParser.parseFightCenter(data, summary: summary)
    }

    private func get(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ClientError.badStatus(http.statusCode)
        }
        return data
    }
}

enum ESPNParser {
    static func date(_ string: String?) -> Date? {
        guard let string else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: string) { return d }
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: string) { return d }
        // "2026-11-14T22:00Z" (no seconds)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm'Z'"
        return f.date(from: string)
    }

    static func parseScoreboard(_ data: Data, league: League) throws -> [EventSummary] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let events = root["events"] as? [[String: Any]] else { throw ESPNClient.ClientError.malformed }
        return events.compactMap { event in
            guard let id = event["id"] as? String,
                  let name = event["name"] as? String,
                  let date = date(event["date"] as? String) else { return nil }
            let status = (event["status"] as? [String: Any])?["type"] as? [String: Any]
            let venues = event["venues"] as? [[String: Any]]
            let venue = venues?.first?["fullName"] as? String
            return EventSummary(id: id,
                                league: league,
                                name: name,
                                shortName: (event["shortName"] as? String) ?? name,
                                date: date,
                                state: (status?["state"] as? String) ?? "pre",
                                venue: venue)
        }
    }

    static func parseFightCenter(_ data: Data, summary: EventSummary) throws -> EventDetail {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cards = root["cards"] as? [String: [String: Any]] else { throw ESPNClient.ClientError.malformed }

        var updatedSummary = summary
        if let event = root["event"] as? [String: Any] {
            if let name = event["name"] as? String { updatedSummary.name = name }
            if let d = date(event["date"] as? String) { updatedSummary.date = d }
        }

        struct Segment {
            var key: String
            var name: String
            var start: Date
            var fights: [[String: Any]]
        }

        var segments: [Segment] = []
        for (key, card) in cards {
            let competitions = (card["competitions"] as? [[String: Any]]) ?? []
            guard !competitions.isEmpty else { continue }
            let starts = competitions.compactMap { date($0["date"] as? String) }
            segments.append(Segment(key: key,
                                    name: segmentName(key: key, espn: card["displayName"] as? String),
                                    start: starts.min() ?? summary.date,
                                    fights: competitions))
        }
        // Earliest segment first (early prelims → prelims → main card).
        segments.sort { lhs, rhs in
            lhs.start != rhs.start ? lhs.start < rhs.start : segmentRank(lhs.key) < segmentRank(rhs.key)
        }

        var fights: [Fight] = []
        for segment in segments {
            // ESPN lists each card main-event-first; the night runs the other way.
            let ordered = segment.fights.enumerated().sorted { a, b in
                let ma = a.element["matchNumber"] as? Int ?? 0
                let mb = b.element["matchNumber"] as? Int ?? 0
                return ma != mb ? ma > mb : a.offset > b.offset
            }.map(\.element)
            for competition in ordered {
                if let fight = parseFight(competition, order: fights.count, segment: segment.key, segmentName: segment.name, segmentStart: segment.start) {
                    fights.append(fight)
                }
            }
        }

        if fights.contains(where: { $0.state == .live }) {
            updatedSummary.state = "in"
        } else if !fights.isEmpty, fights.allSatisfy({ $0.state == .finished || $0.state == .canceled }) {
            updatedSummary.state = "post"
        } else if fights.contains(where: { $0.state == .finished }) {
            updatedSummary.state = "in"
        }

        return EventDetail(summary: updatedSummary, fights: fights, fetchedAt: Date())
    }

    static func segmentName(key: String, espn: String?) -> String {
        switch key {
        case "main": "Main card"
        case "prelims1": "Prelims"
        case "prelims2": "Early prelims"
        default: espn ?? key.capitalized
        }
    }

    static func segmentRank(_ key: String) -> Int {
        switch key {
        case "prelims2": 0
        case "prelims1": 1
        case "main": 2
        default: 1
        }
    }

    static func parseState(_ status: [String: Any]?) -> FightState {
        let type = status?["type"] as? [String: Any]
        let name = (type?["name"] as? String ?? "").uppercased()
        let state = type?["state"] as? String ?? "pre"
        let completed = type?["completed"] as? Bool ?? false
        if name.contains("CANCEL") || name.contains("POSTPONE") || name.contains("FORFEIT") { return .canceled }
        switch state {
        case "in": return .live
        case "post": return completed || name.contains("FINAL") ? .finished : .canceled
        default: return .scheduled
        }
    }

    static func parseFight(_ c: [String: Any], order: Int, segment: String, segmentName: String, segmentStart: Date) -> Fight? {
        guard let id = c["id"] as? String else { return nil }
        let status = c["status"] as? [String: Any]
        let state = parseState(status)
        let type = c["type"] as? [String: Any]
        let weight = (type?["text"] as? String) ?? (type?["abbreviation"] as? String) ?? ""

        let competitors = ((c["competitors"] as? [[String: Any]]) ?? []).sorted {
            ($0["order"] as? Int ?? 0) < ($1["order"] as? Int ?? 0)
        }
        var winnerId: String?
        let fighters: [Fighter] = competitors.compactMap { comp in
            guard let athlete = comp["athlete"] as? [String: Any] else { return nil }
            let fid = (comp["id"] as? String) ?? (athlete["id"] as? String) ?? UUID().uuidString
            if comp["winner"] as? Bool == true { winnerId = fid }
            let headshot = (athlete["headshot"] as? [String: Any])?["href"] as? String
            let flag = (athlete["flag"] as? [String: Any])?["href"] as? String
            let records = comp["records"] as? [[String: Any]]
            let record = (comp["displayRecord"] as? String) ?? (records?.first?["summary"] as? String)
            let name = (athlete["displayName"] as? String) ?? (athlete["fullName"] as? String) ?? "?"
            return Fighter(id: fid,
                           name: name,
                           shortName: (athlete["shortName"] as? String) ?? name,
                           record: record,
                           country: (athlete["country"] as? String) ?? ((athlete["flag"] as? [String: Any])?["alt"] as? String),
                           headshotURL: headshot.flatMap(URL.init(string:)),
                           flagURL: flag.flatMap(URL.init(string:)))
        }

        let period = status?["period"] as? Int
        let clock = status?["displayClock"] as? String
        var result: FightResult?
        if state == .finished {
            let r = status?["result"] as? [String: Any]
            result = FightResult(winnerId: winnerId,
                                 method: (r?["shortDisplayName"] as? String) ?? (r?["displayName"] as? String),
                                 detail: r?["displayDescription"] as? String,
                                 round: period,
                                 clock: clock)
        }
        let typeInfo = status?["type"] as? [String: Any]

        return Fight(id: id,
                     order: order,
                     segment: segment,
                     segmentName: segmentName,
                     segmentStart: segmentStart,
                     weightClass: frenchWeight(weight),
                     note: c["note"] as? String,
                     fighters: fighters,
                     state: state,
                     round: (period ?? 0) > 0 ? period : nil,
                     clock: clock,
                     statusDetail: typeInfo?["detail"] as? String,
                     result: result)
    }

    static func frenchWeight(_ s: String) -> String {
        let map: [String: String] = [
            "Strawweight": "Pailles", "Flyweight": "Mouches", "Bantamweight": "Coqs",
            "Featherweight": "Plumes", "Lightweight": "Légers", "Welterweight": "Welters",
            "Middleweight": "Moyens", "Light Heavyweight": "Mi-lourds", "Heavyweight": "Lourds",
            "Catch Weight": "Poids négocié", "Catchweight": "Poids négocié",
        ]
        var base = s
        var women = false
        for prefix in ["Women's ", "W "] where base.hasPrefix(prefix) {
            base = String(base.dropFirst(prefix.count))
            women = true
        }
        guard let fr = map[base] else { return s }
        return women ? "\(fr) (F)" : fr
    }
}
