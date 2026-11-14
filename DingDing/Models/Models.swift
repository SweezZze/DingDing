import Foundation

enum League: String, Codable, CaseIterable, Identifiable, Hashable {
    case ufc
    case pfl

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .ufc: "UFC"
        case .pfl: "PFL"
        }
    }
}

struct EventSummary: Codable, Identifiable, Hashable {
    var id: String
    var league: League
    var name: String
    var shortName: String
    var date: Date
    /// ESPN state: "pre", "in", "post".
    var state: String
    var venue: String?

    var isSimulation: Bool { id.hasPrefix(Simulation.idPrefix) }
}

enum FightState: String, Codable, Hashable {
    case scheduled
    case live
    case finished
    case canceled
}

struct Fighter: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var shortName: String
    var record: String?
    var country: String?
    var headshotURL: URL?
    var flagURL: URL?

    var lastName: String {
        name.split(separator: " ").dropFirst().joined(separator: " ").nonEmpty ?? name
    }
}

struct FightResult: Codable, Hashable {
    var winnerId: String?
    var method: String?
    var detail: String?
    var round: Int?
    var clock: String?
}

struct Fight: Codable, Identifiable, Hashable {
    var id: String
    /// 0 = first fight of the night, increasing up to the main event.
    var order: Int
    var segment: String
    var segmentName: String
    var segmentStart: Date
    var weightClass: String
    var note: String?
    var fighters: [Fighter]
    var state: FightState
    var round: Int?
    var clock: String?
    var statusDetail: String?
    var result: FightResult?

    var label: String {
        fighters.map(\.lastName).joined(separator: " vs ")
    }

    var fullLabel: String {
        fighters.map(\.name).joined(separator: " vs ")
    }

    /// "Round 2 · 3:12", "Fin du round 1"… for a fight in progress.
    var liveText: String {
        let round = round ?? 1
        let detail = (statusDetail ?? "").lowercased()
        if detail.contains("end") { return "Fin du round \(round)" }
        if let clock, !["", "-", "0:00", "0:00.0"].contains(clock) { return "Round \(round) · \(clock)" }
        return "Round \(round)"
    }

    /// "KO/TKO · R2 3:12"
    var resultText: String? {
        guard let result else { return nil }
        let method = result.method.map(Self.frenchMethod)
        let when = [result.round.map { "R\($0)" }, result.clock].compactMap { $0 }.joined(separator: " ")
        return [method, when.nonEmpty].compactMap { $0 }.joined(separator: " · ")
    }

    static func frenchMethod(_ method: String) -> String {
        let m = method.lowercased()
        if m.contains("ko") { return "KO/TKO" }
        if m.contains("sub") { return "Soumission" }
        if m.contains("split") { return "Décision partagée" }
        if m.contains("majority") { return "Décision majoritaire" }
        if m.contains("dec") || m.contains("unanimous") { return "Décision" }
        if m.contains("draw") { return "Nul" }
        if m.contains("dq") || m.contains("disq") { return "Disqualification" }
        if m.contains("no contest") || m == "nc" { return "No contest" }
        return method
    }

    var isMainEvent: Bool { note?.localizedCaseInsensitiveContains("main event") == true && !isCoMain }
    var isCoMain: Bool { note?.localizedCaseInsensitiveContains("co-main") == true }
    var isTitleFight: Bool { note?.localizedCaseInsensitiveContains("title") == true }
}

struct EventDetail: Codable, Hashable, Identifiable {
    var summary: EventSummary
    /// Ordered from first fight of the night to main event.
    var fights: [Fight]
    var fetchedAt: Date

    var id: String { summary.id }

    /// Fights that will actually happen, in order.
    var activeFights: [Fight] { fights.filter { $0.state != .canceled } }

    var segments: [(key: String, name: String, start: Date, fights: [Fight])] {
        var result: [(key: String, name: String, start: Date, fights: [Fight])] = []
        for fight in fights {
            if let index = result.firstIndex(where: { $0.key == fight.segment }) {
                result[index].fights.append(fight)
            } else {
                result.append((fight.segment, fight.segmentName, fight.segmentStart, [fight]))
            }
        }
        return result
    }

    var isLive: Bool { fights.contains { $0.state == .live } || (summary.state == "in") }
    var isOver: Bool {
        let active = activeFights
        return !active.isEmpty && active.allSatisfy { $0.state == .finished }
    }
}

// MARK: - Alarms

enum TriggerKind: Codable, Hashable, Identifiable, Comparable {
    /// Rings when the fight `n` places before mine starts (n = 1 → the previous fight).
    case fightsBefore(Int)
    /// Rings when the previous fight ends (walkouts of my fight).
    case endOfPrevious
    /// Rings when my fight starts.
    case startOfFight

    var id: String {
        switch self {
        case .fightsBefore(let n): "before-\(n)"
        case .endOfPrevious: "end-previous"
        case .startOfFight: "start"
        }
    }

    /// Chronological rank (higher = later in the night).
    var rank: Int {
        switch self {
        case .fightsBefore(let n): 10 - n
        case .endOfPrevious: 10
        case .startOfFight: 11
        }
    }

    static func < (lhs: TriggerKind, rhs: TriggerKind) -> Bool { lhs.rank < rhs.rank }

    static let all: [TriggerKind] = [.fightsBefore(4), .fightsBefore(3), .fightsBefore(2), .fightsBefore(1), .endOfPrevious, .startOfFight]

    var title: String {
        switch self {
        case .fightsBefore(1): "Début du combat d'avant"
        case .fightsBefore(let n): "Début du combat \(n) places avant"
        case .endOfPrevious: "Fin du combat d'avant"
        case .startOfFight: "Début de mon combat"
        }
    }

    var subtitle: String {
        switch self {
        case .fightsBefore(1): "≈ 15-25 min pour te lever"
        case .fightsBefore(let n): "≈ \(n * 20) min d'avance"
        case .endOfPrevious: "Walkouts : ≈ 5-10 min avant"
        case .startOfFight: "Le combat commence"
        }
    }

    var shortTitle: String {
        switch self {
        case .fightsBefore(1): "Combat d'avant"
        case .fightsBefore(let n): "\(n) combats avant"
        case .endOfPrevious: "Fin du précédent"
        case .startOfFight: "Début"
        }
    }

    /// Text of the alarm when it rings.
    func alarmReason(for label: String) -> String {
        switch self {
        case .fightsBefore(1): "\(label) : le combat d'avant commence"
        case .fightsBefore(let n): "\(label) : plus que \(n) combats"
        case .endOfPrevious: "\(label) : c'est le prochain !"
        case .startOfFight: "\(label) : ça commence !"
        }
    }
}

struct AlarmTrigger: Codable, Hashable, Identifiable {
    var kind: TriggerKind
    /// When the live trigger rang.
    var firedAt: Date?
    /// AlarmKit id of the backup alarm (scheduled at the estimated time).
    var backupAlarmId: UUID?
    var backupDate: Date?

    var id: String { kind.id }
}

struct FightAlarm: Codable, Hashable, Identifiable {
    /// ESPN fight id.
    var id: String
    var eventId: String
    var league: League
    var eventName: String
    var fightLabel: String
    var fighterIds: [String]
    var triggers: [AlarmTrigger]
    var fromFavorite: Bool
    /// Last known estimated start of the fight.
    var estimatedStart: Date?

    var pendingTriggers: [AlarmTrigger] { triggers.filter { $0.firedAt == nil } }
}

struct FavoriteFighter: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var headshotURL: URL?
}

struct AppSettings: Codable, Hashable {
    var antiSpoiler: Bool = false
    var leagues: Set<League> = [.ufc, .pfl]
    var favoriteTriggers: [TriggerKind] = [.fightsBefore(1)]
    /// Backup alarm rings this many minutes before the estimated time.
    var backupMarginMinutes: Int = 10
    var backupEnabled: Bool = true
    /// Event pinned at the top of the home screen (nil = next event).
    var pinnedEventId: String?
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
