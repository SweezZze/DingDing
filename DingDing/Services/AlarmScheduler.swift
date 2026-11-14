import ActivityKit
import AlarmKit
import Foundation
import SwiftUI

/// Thin wrapper around AlarmKit (real alarms that ring even in silent mode).
@MainActor
enum AlarmScheduler {
    static var manager: AlarmManager { .shared }

    static var isAuthorized: Bool { manager.authorizationState == .authorized }
    static var authorizationState: AlarmManager.AuthorizationState { manager.authorizationState }

    @discardableResult
    static func requestAuthorization() async -> Bool {
        switch manager.authorizationState {
        case .authorized: return true
        case .denied: return false
        case .notDetermined:
            return (try? await manager.requestAuthorization()) == .authorized
        @unknown default: return false
        }
    }

    /// Schedules an alarm at `date`. Returns its id, or nil on failure.
    @discardableResult
    static func schedule(at date: Date, title: String, fightLabel: String, isBackup: Bool, quiet: Bool = false, id: UUID = UUID()) async -> UUID? {
        guard await requestAuthorization() else { return nil }
        let alert = AlarmPresentation.Alert(title: LocalizedStringResource(stringLiteral: title))
        let attributes = AlarmAttributes<DingAlarmMetadata>(
            presentation: AlarmPresentation(alert: alert),
            metadata: DingAlarmMetadata(fightLabel: fightLabel, reason: title, isBackup: isBackup),
            tintColor: Color(red: 0.93, green: 0.16, blue: 0.22)
        )
        let configuration = AlarmManager.AlarmConfiguration<DingAlarmMetadata>(
            schedule: .fixed(max(date, Date().addingTimeInterval(1))),
            attributes: attributes
        )
        do {
            _ = try await manager.schedule(id: id, configuration: configuration)
            if !quiet { Log.add("Alarme \(isBackup ? "de secours" : "live") programmée \(date.formatted(date: .omitted, time: .shortened)) — \(title)") }
            return id
        } catch {
            Log.add("⚠️ Échec programmation alarme : \(error.localizedDescription)")
            return nil
        }
    }

    /// Rings right now.
    @discardableResult
    static func ringNow(title: String, fightLabel: String) async -> UUID? {
        await schedule(at: Date().addingTimeInterval(1), title: title, fightLabel: fightLabel, isBackup: false)
    }

    static func cancel(_ id: UUID?) {
        guard let id else { return }
        try? manager.cancel(id: id)
    }

    /// Ids of alarms currently known by the system.
    static var scheduledIds: Set<UUID> {
        Set(((try? manager.alarms) ?? []).map(\.id))
    }

    /// Cancels every alarm we own that is not in `keep`.
    static func cancelAll(except keep: Set<UUID>) {
        for alarm in (try? manager.alarms) ?? [] where !keep.contains(alarm.id) && alarm.state != .alerting {
            try? manager.cancel(id: alarm.id)
        }
    }
}
