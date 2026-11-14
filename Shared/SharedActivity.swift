import ActivityKit
import AlarmKit
import Foundation

/// Live Activity shown on the lock screen / Dynamic Island while DingDing is watching an event.
struct CardActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// "Gane vs Hokit" — the fight currently in progress, if any.
        var currentFight: String?
        /// "Round 2", "Entre deux combats", "Pas encore commencé"…
        var status: String
        /// Number of finished fights / total fights of the night.
        var done: Int
        var total: Int
        /// Next alarm that will ring ("Début du combat d'avant · Gane vs Hokit").
        var nextAlarm: String?
        /// Fights still to go before that alarm rings.
        var fightsBeforeAlarm: Int?
        /// Estimated time of that alarm.
        var estimatedAlarm: Date?
        /// True when the last refresh failed (no network…).
        var stale: Bool
    }

    var eventId: String
    var eventName: String
    var league: String
}

/// Metadata attached to every AlarmKit alarm DingDing schedules.
struct DingAlarmMetadata: AlarmMetadata {
    var fightLabel: String
    var reason: String
    var isBackup: Bool
}
