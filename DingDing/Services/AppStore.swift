import Foundation
import Observation
import SwiftUI

/// Everything DingDing knows: events, cards, alarms, favourites, settings.
@Observable
@MainActor
final class AppStore {
    // MARK: Persisted
    var events: [EventSummary] = []
    var details: [String: EventDetail] = [:]
    var alarms: [String: FightAlarm] = [:]
    var favorites: [String: FavoriteFighter] = [:]
    var settings = AppSettings() { didSet { if settings != oldValue { save(); scheduleReconcile() } } }
    var observedStarts: [String: Date] = [:]
    /// Auto (favourite) alarms the user removed: never recreate them.
    var dismissedAutoAlarms: Set<String> = []
    var watchedEventIds: Set<String> = []
    /// Events whose veille the user paused by hand (never auto-restarted).
    var pausedVeille: Set<String> = []
    var simulation: Simulation.Session?

    // MARK: Runtime
    var isLoading = false
    var lastError: String?
    var lastRefresh: Date?
    /// Results revealed despite anti-spoiler, per event.
    var revealedEvents: Set<String> = []
    var appIsActive = true

    private let client = ESPNClient()
    private var reconcileTask: Task<Void, Never>?

    /// `preview: true` → empty in-memory store for Xcode previews (never touches the saved data).
    private let isPreview: Bool

    init(preview: Bool = false) {
        isPreview = preview
        if !preview { load() }
    }

    // MARK: - Queries

    var upcomingEvents: [EventSummary] {
        var list = events.filter { settings.leagues.contains($0.league) }
        if let sim = simulation { list.insert(Simulation.detail(for: sim).summary, at: 0) }
        return list
    }

    /// Event shown big at the top: the pinned one, otherwise the next (or live) one.
    var featuredEvent: EventSummary? {
        let list = upcomingEvents
        if let pinned = settings.pinnedEventId, let event = list.first(where: { $0.id == pinned }) {
            return event
        }
        // Next event that isn't over yet (a live one counts).
        return list.first { detail(for: $0.id)?.isOver != true } ?? list.first
    }

    func isPinned(_ eventId: String) -> Bool { settings.pinnedEventId == eventId }

    func togglePin(_ eventId: String) {
        settings.pinnedEventId = isPinned(eventId) ? nil : eventId
    }

    func detail(for eventId: String) -> EventDetail? {
        if let sim = simulation, sim.template.summary.id == eventId { return Simulation.detail(for: sim) }
        return details[eventId]
    }

    func summary(for eventId: String) -> EventSummary? {
        detail(for: eventId)?.summary ?? events.first { $0.id == eventId }
    }

    func alarms(forEvent eventId: String) -> [FightAlarm] {
        alarms.values.filter { $0.eventId == eventId }.sorted { ($0.estimatedStart ?? .distantFuture) < ($1.estimatedStart ?? .distantFuture) }
    }

    var eventsWithAlarms: [String] {
        Array(Set(alarms.values.filter { !$0.pendingTriggers.isEmpty }.map(\.eventId)))
    }

    func hidesResults(for eventId: String) -> Bool {
        settings.antiSpoiler && !revealedEvents.contains(eventId)
    }

    func isFavorite(_ fighterId: String) -> Bool { favorites[fighterId] != nil }

    /// The next trigger that will ring for an alarm, with its estimate.
    func nextRing(for alarm: FightAlarm) -> UpcomingRing? {
        guard let kind = alarm.pendingTriggers.map(\.kind).min() else { return nil }
        let detail = detail(for: alarm.eventId)
        let fight = detail?.fights.first { $0.id == alarm.id }
        guard fight?.state != .finished, fight?.state != .canceled else { return nil }
        var date: Date?
        var remaining: Int?
        if let detail {
            date = TriggerLogic.estimatedDate(of: kind, fightId: alarm.id, in: detail, starts: estimatedStarts(for: detail))
            remaining = TriggerLogic.fightsRemaining(before: kind, fightId: alarm.id, in: detail)
        }
        return UpcomingRing(alarm: alarm, kind: kind, date: date, fightsBefore: remaining, fight: fight)
    }

    /// Alarms still to ring, soonest first (optionally only those within `hours`).
    func upcomingRings(withinHours hours: Double? = nil) -> [UpcomingRing] {
        let limit = hours.map { Date().addingTimeInterval($0 * 3600) }
        return alarms.values.compactMap(nextRing(for:))
            .filter { ring in
                guard let limit else { return true }
                if let date = ring.date { return date < limit }
                return (summary(for: ring.alarm.eventId)?.date ?? .distantFuture) < limit
            }
            .sorted { ($0.date ?? .distantFuture) < ($1.date ?? .distantFuture) }
    }

    func estimatedStarts(for detail: EventDetail) -> [String: Date] {
        TriggerLogic.estimatedStarts(for: detail, now: Date(), observedStarts: observedStarts)
    }

    // MARK: - Refresh

    func refreshAll() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        var fresh: [EventSummary] = []
        var failures: [String] = []
        for league in League.allCases where settings.leagues.contains(league) {
            do {
                fresh += try await client.upcomingEvents(league: league)
            } catch {
                failures.append("\(league.displayName) : \(error.localizedDescription)")
            }
        }
        if failures.isEmpty || !fresh.isEmpty {
            // Keep events we have alarms on even if ESPN dropped them from the range.
            let alarmEvents = Set(alarms.values.map(\.eventId))
            let kept = events.filter { old in alarmEvents.contains(old.id) && !fresh.contains(where: { $0.id == old.id }) }
            events = (fresh + kept)
                .filter { $0.date > Date().addingTimeInterval(-30 * 3600) || alarmEvents.contains($0.id) }
                .sorted { $0.date < $1.date }
        }
        lastError = failures.isEmpty ? nil : failures.joined(separator: "\n")

        // Load cards of the next weeks in parallel (needed for favourites and estimates).
        let horizon = Date().addingTimeInterval(120 * 86400)
        let client = self.client
        let toLoad = events.filter { $0.date < horizon }
        await withTaskGroup(of: (String, EventDetail?).self) { group in
            for event in toLoad {
                group.addTask { (event.id, try? await client.eventDetail(event)) }
            }
            for await (id, fresh) in group {
                guard let fresh else { continue }
                let previous = details[id]
                details[id] = fresh
                if let i = events.firstIndex(where: { $0.id == id }) { events[i] = fresh.summary }
                process(fresh, previous: previous)
            }
        }
        lastRefresh = Date()
        cleanupOldData()
        save()
    }

    func refreshDetail(_ eventId: String, quiet: Bool = false) async {
        if let sim = simulation, sim.template.summary.id == eventId {
            process(Simulation.detail(for: sim), previous: nil)
            return
        }
        guard let summary = summary(for: eventId) else { return }
        do {
            let previous = details[eventId]
            let fresh = try await client.eventDetail(summary)
            details[eventId] = fresh
            if let i = events.firstIndex(where: { $0.id == eventId }) { events[i] = fresh.summary }
            process(fresh, previous: previous)
            if !quiet { lastError = nil }
        } catch {
            if !quiet { lastError = error.localizedDescription }
            Log.add("⚠️ Rafraîchissement \(summary.shortName) impossible : \(error.localizedDescription)")
        }
    }

    // MARK: - Core: react to a new state of the card

    private var previousSim: EventDetail?

    func process(_ detail: EventDetail, previous: EventDetail?) {
        let now = Date()
        let previous = previous ?? (detail.summary.isSimulation ? previousSim : nil)
        if detail.summary.isSimulation { previousSim = detail }

        // 1. Remember when fights started (better estimates for the rest of the night).
        for fight in detail.fights where fight.state == .live || fight.state == .finished {
            guard observedStarts[fight.id] == nil else { continue }
            let before = previous?.fights.first { $0.id == fight.id }?.state
            if fight.state == .live || before == .scheduled || before == .live {
                observedStarts[fight.id] = now
                Log.add("🥊 \(fight.label) a commencé")
            }
        }

        // 2. Auto alarms for favourite fighters.
        applyFavorites(to: detail)

        // 3. Fire triggers that are reached.
        let starts = estimatedStarts(for: detail)
        for var alarm in alarms.values where alarm.eventId == detail.id {
            guard let fight = detail.fights.first(where: { $0.id == alarm.id }) else { continue }
            alarm.estimatedStart = starts[alarm.id] ?? alarm.estimatedStart

            if fight.state == .canceled {
                if !alarm.pendingTriggers.isEmpty {
                    for i in alarm.triggers.indices where alarm.triggers[i].firedAt == nil {
                        AlarmScheduler.cancel(alarm.triggers[i].backupAlarmId)
                        alarm.triggers[i].backupAlarmId = nil
                        alarm.triggers[i].backupDate = nil
                        alarm.triggers[i].firedAt = now
                    }
                    Log.add("❌ \(alarm.fightLabel) annulé : alarmes supprimées")
                }
                alarms[alarm.id] = alarm
                continue
            }

            let due = TriggerLogic.dueTriggers(for: alarm, in: detail)
            if let latest = due.max() {
                for i in alarm.triggers.indices where due.contains(alarm.triggers[i].kind) {
                    alarm.triggers[i].firedAt = now
                    AlarmScheduler.cancel(alarm.triggers[i].backupAlarmId)
                    alarm.triggers[i].backupAlarmId = nil
                    alarm.triggers[i].backupDate = nil
                }
                // Don't ring for a fight that is already over (app opened the next morning…).
                if fight.state != .finished {
                    let title = latest.alarmReason(for: alarm.fightLabel)
                    Log.add("🔔 \(title)")
                    let label = alarm.fightLabel
                    Task { await AlarmScheduler.ringNow(title: title, fightLabel: label) }
                } else {
                    Log.add("\(alarm.fightLabel) déjà terminé : alarme ignorée")
                }
            }
            alarms[alarm.id] = alarm
        }

        save()
        scheduleReconcile()
        WatchService.shared.didProcess(detail, store: self)
    }

    // MARK: - Alarms

    func triggers(for fightId: String) -> Set<TriggerKind> {
        Set(alarms[fightId]?.triggers.map(\.kind) ?? [])
    }

    func setTriggers(_ kinds: Set<TriggerKind>, fight: Fight, event: EventSummary, fromFavorite: Bool = false) {
        if kinds.isEmpty {
            removeAlarm(fight.id)
            return
        }
        var alarm = alarms[fight.id] ?? FightAlarm(id: fight.id,
                                                   eventId: event.id,
                                                   league: event.league,
                                                   eventName: event.name,
                                                   fightLabel: fight.label,
                                                   fighterIds: fight.fighters.map(\.id),
                                                   triggers: [],
                                                   fromFavorite: fromFavorite,
                                                   estimatedStart: nil)
        let wasPending = Set(alarm.pendingTriggers.map(\.kind))
        // Remove deselected triggers.
        for trigger in alarm.triggers where !kinds.contains(trigger.kind) {
            AlarmScheduler.cancel(trigger.backupAlarmId)
        }
        alarm.triggers.removeAll { !kinds.contains($0.kind) }
        // Add new ones.
        for kind in kinds where !alarm.triggers.contains(where: { $0.kind == kind }) {
            alarm.triggers.append(AlarmTrigger(kind: kind))
        }
        alarm.triggers.sort { $0.kind < $1.kind }
        // A trigger whose moment is already past must not ring right away.
        if let current = detail(for: event.id) {
            for i in alarm.triggers.indices where alarm.triggers[i].firedAt == nil && !wasPending.contains(alarm.triggers[i].kind) {
                if TriggerLogic.isReached(alarm.triggers[i].kind, fightId: fight.id, in: current) == true {
                    alarm.triggers[i].firedAt = Date()
                }
            }
        }
        if !fromFavorite { alarm.fromFavorite = false }
        alarms[fight.id] = alarm
        dismissedAutoAlarms.remove(fight.id)
        Log.add("Alarme réglée : \(fight.label) (\(alarm.triggers.map(\.kind.shortTitle).joined(separator: ", ")))")
        save()
        Task {
            _ = await AlarmScheduler.requestAuthorization()
            if let current = self.detail(for: event.id) { self.process(current, previous: nil) } else { self.scheduleReconcile() }
            WatchService.shared.autoStartIfNeeded(store: self)
        }
    }

    func removeAlarm(_ fightId: String) {
        guard let alarm = alarms[fightId] else { return }
        for trigger in alarm.triggers { AlarmScheduler.cancel(trigger.backupAlarmId) }
        alarms[fightId] = nil
        if alarm.fromFavorite { dismissedAutoAlarms.insert(fightId) }
        Log.add("Alarme supprimée : \(alarm.fightLabel)")
        save()
    }

    /// Re-arms already fired triggers (e.g. after a test).
    func rearm(_ fightId: String) {
        guard var alarm = alarms[fightId] else { return }
        for i in alarm.triggers.indices { alarm.triggers[i].firedAt = nil }
        alarms[fightId] = alarm
        save()
        scheduleReconcile()
    }

    // MARK: - Favourites

    func toggleFavorite(_ fighter: Fighter) {
        if favorites[fighter.id] != nil {
            favorites[fighter.id] = nil
        } else {
            favorites[fighter.id] = FavoriteFighter(id: fighter.id, name: fighter.name, headshotURL: fighter.headshotURL)
            for detail in details.values { applyFavorites(to: detail) }
        }
        save()
        scheduleReconcile()
    }

    func removeFavorite(_ id: String) {
        favorites[id] = nil
        save()
    }

    private func applyFavorites(to detail: EventDetail) {
        guard !favorites.isEmpty, !detail.summary.isSimulation, !settings.favoriteTriggers.isEmpty else { return }
        for fight in detail.fights where fight.state == .scheduled {
            guard alarms[fight.id] == nil, !dismissedAutoAlarms.contains(fight.id),
                  fight.fighters.contains(where: { favorites[$0.id] != nil }) else { continue }
            let alarm = FightAlarm(id: fight.id,
                                   eventId: detail.id,
                                   league: detail.summary.league,
                                   eventName: detail.summary.name,
                                   fightLabel: fight.label,
                                   fighterIds: fight.fighters.map(\.id),
                                   triggers: settings.favoriteTriggers.sorted().map { AlarmTrigger(kind: $0) },
                                   fromFavorite: true,
                                   estimatedStart: nil)
            alarms[fight.id] = alarm
            Log.add("⭐️ Alarme auto pour un favori : \(fight.label)")
        }
    }

    // MARK: - Backup alarms

    /// Schedules / moves / cancels backup alarms so they match the latest estimates.
    func scheduleReconcile() {
        let previous = reconcileTask
        reconcileTask = Task {
            await previous?.value
            await reconcileBackups()
        }
    }

    func reconcileBackups() async {
        guard AlarmScheduler.isAuthorized else { return }
        let now = Date()
        let existing = AlarmScheduler.scheduledIds
        var keep: Set<UUID> = []

        for fightId in Array(alarms.keys) {
            guard var alarm = alarms[fightId] else { continue }
            let detail = self.detail(for: alarm.eventId)
            let isSim = alarm.eventId.hasPrefix(Simulation.idPrefix)
            let watching = watchedEventIds.contains(alarm.eventId) || appIsActive
            let starts = detail.map(estimatedStarts(for:)) ?? [:]
            var changed = false

            for i in alarm.triggers.indices {
                let trigger = alarm.triggers[i]
                var desired: Date?
                if trigger.firedAt == nil, settings.backupEnabled, !isSim, let detail,
                   detail.fights.first(where: { $0.id == fightId })?.state == .scheduled || detail.fights.first(where: { $0.id == fightId })?.state == .live,
                   let estimate = TriggerLogic.estimatedDate(of: trigger.kind, fightId: fightId, in: detail, starts: starts) {
                    desired = TriggerLogic.backupDate(estimate: estimate, marginMinutes: settings.backupMarginMinutes, now: now, watching: watching)
                }

                guard let desired else {
                    if trigger.backupAlarmId != nil {
                        AlarmScheduler.cancel(trigger.backupAlarmId)
                        alarm.triggers[i].backupAlarmId = nil
                        alarm.triggers[i].backupDate = nil
                        changed = true
                    }
                    continue
                }

                let stillThere = trigger.backupAlarmId.map(existing.contains) ?? false
                if stillThere, let current = trigger.backupDate, abs(current.timeIntervalSince(desired)) < 90 {
                    keep.insert(trigger.backupAlarmId!)
                    continue
                }
                // An already-rung backup (date passed, gone from the system) is not re-created
                // unless the estimate moved forward meanwhile.
                if !stillThere, let current = trigger.backupDate, current < now, desired <= current.addingTimeInterval(90) {
                    continue
                }
                AlarmScheduler.cancel(trigger.backupAlarmId)
                let title = "Secours · " + trigger.kind.alarmReason(for: alarm.fightLabel)
                // The veille slides the backup forward every poll: don't flood the journal with it.
                let quiet = trigger.backupDate.map { abs($0.timeIntervalSince(desired)) < 10 * 60 } ?? false
                if let id = await AlarmScheduler.schedule(at: desired, title: title, fightLabel: alarm.fightLabel, isBackup: true, quiet: quiet) {
                    alarm.triggers[i].backupAlarmId = id
                    alarm.triggers[i].backupDate = desired
                    keep.insert(id)
                } else {
                    alarm.triggers[i].backupAlarmId = nil
                    alarm.triggers[i].backupDate = nil
                }
                changed = true
            }
            if changed, var current = alarms[fightId] {
                for updated in alarm.triggers {
                    guard let j = current.triggers.firstIndex(where: { $0.kind == updated.kind }) else {
                        AlarmScheduler.cancel(updated.backupAlarmId)
                        continue
                    }
                    if current.triggers[j].firedAt == nil {
                        current.triggers[j].backupAlarmId = updated.backupAlarmId
                        current.triggers[j].backupDate = updated.backupDate
                    } else if let id = updated.backupAlarmId {
                        // Fired while we were scheduling: drop the backup we just created.
                        AlarmScheduler.cancel(id)
                        keep.remove(id)
                    }
                }
                alarms[fightId] = current
            } else if changed {
                for updated in alarm.triggers { AlarmScheduler.cancel(updated.backupAlarmId) }
            }
        }
        // Remove orphans (deleted alarms, old builds…) but never the live alarms that are ringing.
        AlarmScheduler.cancelAll(except: keep.union(liveAlarmIdsToKeep(now: now)))
        save()
    }

    /// Live alarms scheduled in the last minute may not be ringing yet: don't cancel them.
    private func liveAlarmIdsToKeep(now: Date) -> Set<UUID> {
        let alarmsList = (try? AlarmScheduler.manager.alarms) ?? []
        return Set(alarmsList.filter { alarm in
            if case .fixed(let date) = alarm.schedule { return abs(date.timeIntervalSince(now)) < 120 }
            return false
        }.map(\.id))
    }

    // MARK: - Simulation

    func startSimulation() async {
        isLoading = true
        defer { isLoading = false }
        do {
            var past: [EventSummary] = []
            past = try await client.upcomingEvents(league: .ufc, from: Date().addingTimeInterval(-30 * 86400), days: 30)
            guard let last = past.filter({ $0.date < Date() }).last else { lastError = "Aucun événement récent à rejouer"; return }
            let detail = try await client.eventDetail(last)
            stopSimulation()
            simulation = Simulation.makeSession(from: detail)
            previousSim = nil
            Log.add("🧪 Simulation lancée : \(detail.summary.name)")
            save()
        } catch {
            lastError = "Simulation impossible : \(error.localizedDescription)"
        }
    }

    func stopSimulation() {
        guard let sim = simulation else { return }
        let id = sim.template.summary.id
        for alarm in alarms.values where alarm.eventId == id { removeAlarm(alarm.id) }
        WatchService.shared.stop(eventId: id, store: self)
        simulation = nil
        previousSim = nil
        save()
    }

    // MARK: - Housekeeping

    private func cleanupOldData() {
        let limit = Date().addingTimeInterval(-3 * 86400)
        let oldEvents = Set(events.filter { $0.date < limit }.map(\.id))
        for (id, detail) in details where detail.summary.date < limit {
            details[id] = nil
        }
        for alarm in alarms.values where oldEvents.contains(alarm.eventId) || (details[alarm.eventId] == nil && !events.contains { $0.id == alarm.eventId } && !alarm.eventId.hasPrefix(Simulation.idPrefix)) {
            for trigger in alarm.triggers { AlarmScheduler.cancel(trigger.backupAlarmId) }
            alarms[alarm.id] = nil
        }
        events.removeAll { oldEvents.contains($0.id) }
        let knownFights = Set(details.values.flatMap { $0.fights.map(\.id) })
        observedStarts = observedStarts.filter { knownFights.contains($0.key) }
        if let sim = simulation, Simulation.isOver(sim, now: Date().addingTimeInterval(-3600)) { stopSimulation() }
    }

    // MARK: - Persistence

    private struct Persisted: Codable {
        var events: [EventSummary]
        var details: [String: EventDetail]
        var alarms: [String: FightAlarm]
        var favorites: [String: FavoriteFighter]
        var settings: AppSettings
        var observedStarts: [String: Date]
        var dismissedAutoAlarms: Set<String>
        var watchedEventIds: Set<String>
        var simulation: Simulation.Session?
        var pausedVeille: Set<String>?
    }

    private static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("dingding.json")
    }

    func save() {
        guard !isPreview else { return }
        let state = Persisted(events: events, details: details, alarms: alarms, favorites: favorites, settings: settings,
                              observedStarts: observedStarts, dismissedAutoAlarms: dismissedAutoAlarms,
                              watchedEventIds: watchedEventIds, simulation: simulation,
                              pausedVeille: pausedVeille)
        do {
            let data = try JSONEncoder().encode(state)
            try data.write(to: Self.fileURL, options: .atomic)
        } catch {
            print("save failed \(error)")
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.fileURL),
              let state = try? JSONDecoder().decode(Persisted.self, from: data) else { return }
        events = state.events
        details = state.details
        alarms = state.alarms
        favorites = state.favorites
        settings = state.settings
        observedStarts = state.observedStarts
        dismissedAutoAlarms = state.dismissedAutoAlarms
        watchedEventIds = state.watchedEventIds
        simulation = state.simulation
        pausedVeille = state.pausedVeille ?? []
    }
}

/// Next ring of one alarm, for the UI.
struct UpcomingRing: Identifiable {
    var alarm: FightAlarm
    var kind: TriggerKind
    var date: Date?
    /// Fights still to start before it rings (nil = unknown).
    var fightsBefore: Int?
    var fight: Fight?

    var id: String { alarm.id }
}
