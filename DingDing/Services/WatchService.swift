import ActivityKit
import Foundation
import Observation

/// "Veille": keeps DingDing alive during the night, polls ESPN and drives the Live Activity.
@Observable
@MainActor
final class WatchService {
    static let shared = WatchService()

    private(set) var isRunning = false
    private(set) var lastPoll: Date?
    private(set) var consecutiveFailures = 0
    private var lastHeartbeat = Date()
    private var loop: Task<Void, Never>?
    private var activities: [String: Activity<CardActivityAttributes>] = [:]

    // MARK: - Start / stop

    /// Starts the veille. `byUser`: the user asked for it (clears a manual pause).
    func start(eventId: String, store: AppStore, byUser: Bool = false) {
        if byUser { store.pausedVeille.remove(eventId) }
        guard !store.watchedEventIds.contains(eventId) else { return }
        store.watchedEventIds.insert(eventId)
        store.save()
        Log.add("🌙 Veille lancée\(byUser ? "" : " automatiquement") : \(store.summary(for: eventId)?.shortName ?? eventId)")
        ensureRunning(store: store)
        if let detail = store.detail(for: eventId) { updateActivity(for: detail, store: store) }
        store.scheduleReconcile()
    }

    /// Stops the veille. `byUser`: manual pause, it won't restart by itself.
    func stop(eventId: String, store: AppStore, byUser: Bool = false) {
        if byUser { store.pausedVeille.insert(eventId) }
        guard store.watchedEventIds.contains(eventId) else { store.save(); return }
        store.watchedEventIds.remove(eventId)
        store.save()
        endActivity(eventId)
        Log.add("Veille \(byUser ? "mise en pause" : "arrêtée") : \(store.summary(for: eventId)?.shortName ?? eventId)")
        if store.watchedEventIds.isEmpty { stopLoop() }
        store.scheduleReconcile()
    }

    /// Called at launch: resumes a veille that was running when the app was relaunched.
    func resumeIfNeeded(store: AppStore) {
        // Drop events that no longer need watching.
        for id in store.watchedEventIds where !needsWatching(id, store: store) {
            store.watchedEventIds.remove(id)
        }
        if !store.watchedEventIds.isEmpty { ensureRunning(store: store) }
        // Adopt the Live Activities of watched events, end the others (left by a previous run).
        for activity in Activity<CardActivityAttributes>.activities {
            let eventId = activity.attributes.eventId
            if store.watchedEventIds.contains(eventId), activities[eventId] == nil {
                activities[eventId] = activity
            } else if activities[eventId]?.id != activity.id {
                Task { await activity.end(nil, dismissalPolicy: .immediate) }
            }
        }
    }

    /// Hours before an event during which the veille runs by itself.
    static let autoWindowHours: Double = 24

    /// Starts the veille automatically for events with alarms within 24 h (or live),
    /// unless the user paused it.
    func autoStartIfNeeded(store: AppStore) {
        for eventId in store.eventsWithAlarms where !store.watchedEventIds.contains(eventId) && !store.pausedVeille.contains(eventId) {
            guard let summary = store.summary(for: eventId) else { continue }
            let soon = summary.date.timeIntervalSinceNow < Self.autoWindowHours * 3600
            if soon && needsWatching(eventId, store: store) {
                start(eventId: eventId, store: store)
            }
        }
        // Forget pauses of events that are over.
        store.pausedVeille = store.pausedVeille.filter { needsWatching($0, store: store) }
    }

    /// What the UI shows for an event.
    enum Status { case active, paused, waiting }

    func status(for eventId: String, store: AppStore) -> Status {
        if store.watchedEventIds.contains(eventId) { return .active }
        if store.pausedVeille.contains(eventId) { return .paused }
        return .waiting
    }

    func needsWatching(_ eventId: String, store: AppStore) -> Bool {
        let pending = store.alarms(forEvent: eventId).contains { !$0.pendingTriggers.isEmpty }
        let over = store.detail(for: eventId)?.isOver ?? false
        return pending && !over
    }

    private func ensureRunning(store: AppStore) {
        KeepAlive.shared.start()
        guard loop == nil else { return }
        isRunning = true
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let ids = store.watchedEventIds
                if ids.isEmpty { break }
                var failed = false
                for id in ids {
                    let before = store.detail(for: id)?.fetchedAt
                    await store.refreshDetail(id, quiet: true)
                    if store.detail(for: id)?.fetchedAt == before, !id.hasPrefix(Simulation.idPrefix) { failed = true }
                }
                self.consecutiveFailures = failed ? self.consecutiveFailures + 1 : 0
                self.lastPoll = Date()
                // Heartbeat in the journal: proves the app stayed awake all night.
                if Date().timeIntervalSince(self.lastHeartbeat) > 30 * 60 {
                    self.lastHeartbeat = Date()
                    Log.add("💓 Veille toujours active\(failed ? " (ESPN injoignable)" : "")")
                }
                let interval = self.pollInterval(store: store)
                try? await Task.sleep(for: .seconds(interval))
            }
            self?.stopLoop()
        }
    }

    private func stopLoop() {
        loop?.cancel()
        loop = nil
        isRunning = false
        KeepAlive.shared.stop()
    }

    /// 30 s when an alarm may ring within 90 min (or the event is live), 2 min when it's
    /// within 4 h, 5 min otherwise (the veille can start a day early: spare the battery).
    private func pollInterval(store: AppStore) -> Double {
        var interval = 300.0
        for id in store.watchedEventIds {
            if id.hasPrefix(Simulation.idPrefix) { return 4 }
            guard let detail = store.detail(for: id) else { continue }
            if detail.isLive { interval = min(interval, 30) }
            let next = nextAlarm(for: detail, store: store)?.date
            if let next, next.timeIntervalSinceNow < 90 * 60 { interval = min(interval, 30) }
            if (next ?? detail.summary.date).timeIntervalSinceNow < 4 * 3600 { interval = min(interval, 120) }
        }
        return interval
    }

    // MARK: - After each refresh

    func didProcess(_ detail: EventDetail, store: AppStore) {
        guard store.watchedEventIds.contains(detail.id) else { return }
        updateActivity(for: detail, store: store)
        if !needsWatching(detail.id, store: store) {
            Log.add("Plus d'alarme en attente pour \(detail.summary.shortName) : fin de la veille")
            stop(eventId: detail.id, store: store)
        }
    }

    // MARK: - Live Activity

    struct NextAlarm {
        var label: String
        var fightsBefore: Int?
        var date: Date?
    }

    func nextAlarm(for detail: EventDetail, store: AppStore) -> NextAlarm? {
        let starts = store.estimatedStarts(for: detail)
        var best: (NextAlarm, Date)?
        for alarm in store.alarms(forEvent: detail.id) {
            for trigger in alarm.pendingTriggers {
                let date = TriggerLogic.estimatedDate(of: trigger.kind, fightId: alarm.id, in: detail, starts: starts)
                let candidate = NextAlarm(label: "\(trigger.kind.shortTitle) · \(alarm.fightLabel)",
                                          fightsBefore: TriggerLogic.fightsRemaining(before: trigger.kind, fightId: alarm.id, in: detail),
                                          date: date)
                let key = date ?? .distantFuture
                if best == nil || key < best!.1 { best = (candidate, key) }
            }
        }
        return best?.0
    }

    func contentState(for detail: EventDetail, store: AppStore) -> CardActivityAttributes.ContentState {
        let active = detail.activeFights
        let done = active.filter { $0.state == .finished }.count
        let live = active.first { $0.state == .live }
        let status: String
        if let live {
            status = live.round.map { "Round \($0)" } ?? "En cours"
        } else if done == 0 {
            status = "Début prévu \(detail.summary.date.formatted(date: .omitted, time: .shortened))"
        } else if done == active.count {
            status = "Soirée terminée"
        } else {
            let next = active.first { $0.state == .scheduled }
            status = "Prochain : \(next?.label ?? "—")"
        }
        let next = nextAlarm(for: detail, store: store)
        let stale = consecutiveFailures >= 3
        return .init(currentFight: live?.label,
                     status: status,
                     done: done,
                     total: active.count,
                     nextAlarm: next?.label,
                     fightsBeforeAlarm: next?.fightsBefore,
                     estimatedAlarm: next?.date,
                     stale: stale)
    }

    /// iOS ends a Live Activity after ~8 h: only start it when the alarm is less than 7 h away.
    private func wantsActivity(_ detail: EventDetail, store: AppStore) -> Bool {
        if detail.isLive || detail.summary.isSimulation { return true }
        let reference = nextAlarm(for: detail, store: store)?.date ?? detail.summary.date
        return reference.timeIntervalSinceNow < 7 * 3600
    }

    private static let createdKey = "activityCreated"
    private var activityCreated: [String: Double] {
        get { UserDefaults.standard.dictionary(forKey: Self.createdKey) as? [String: Double] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: Self.createdKey) }
    }

    private func updateActivity(for detail: EventDetail, store: AppStore) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let state = contentState(for: detail, store: store)
        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(15 * 60))
        if let activity = activities[detail.id], activity.activityState != .active {
            activities[detail.id] = nil   // ended by iOS (8 h limit) or by the user
        }
        if let activity = activities[detail.id] ?? Activity<CardActivityAttributes>.activities.first(where: { $0.attributes.eventId == detail.id && $0.activityState == .active }) {
            activities[detail.id] = activity
            guard activity.content.state != state else { return }
            Task { await activity.update(content) }
        } else if store.appIsActive, wantsActivity(detail, store: store) {
            // A Live Activity can only be started while the app is on screen.
            do {
                let attributes = CardActivityAttributes(eventId: detail.id,
                                                        eventName: detail.summary.shortName == "Simulation" ? detail.summary.name : detail.summary.shortName,
                                                        league: detail.summary.league.displayName)
                let activity = try Activity.request(attributes: attributes, content: content, pushType: nil)
                activities[detail.id] = activity
                activityCreated[activity.id] = Date().timeIntervalSince1970
            } catch {
                Log.add("⚠️ Live Activity impossible : \(error.localizedDescription)")
            }
        }
    }

    /// When the app comes on screen: (re)creates the Live Activities so they last until the alarm.
    func refreshActivities(store: AppStore) {
        for eventId in store.watchedEventIds {
            guard let detail = store.detail(for: eventId) else { continue }
            if let activity = activities[eventId], activity.activityState == .active,
               Date().timeIntervalSince1970 - (activityCreated[activity.id] ?? 0) > 3600,
               wantsActivity(detail, store: store), !detail.isLive {
                // Older than 1 h: replace it by a fresh one (full 8 h ahead).
                activities[eventId] = nil
                activityCreated[activity.id] = nil
                Task { await activity.end(nil, dismissalPolicy: .immediate) }
            }
            updateActivity(for: detail, store: store)
        }
    }

    private func endActivity(_ eventId: String) {
        guard let activity = activities.removeValue(forKey: eventId) else { return }
        activityCreated[activity.id] = nil
        Task { await activity.end(nil, dismissalPolicy: .after(Date().addingTimeInterval(20 * 60))) }
    }
}
