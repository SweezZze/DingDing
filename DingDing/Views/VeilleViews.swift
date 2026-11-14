import SwiftUI

// MARK: - Overall veille status

struct VeilleSummary {
    var status: WatchService.Status
    var title: String
    var subtitle: String

    @MainActor
    init(eventIds: Set<String>, store: AppStore) {
        let watch = WatchService.shared
        let statuses = eventIds.map { watch.status(for: $0, store: store) }
        if statuses.contains(.active) {
            status = .active
            title = "Veille active"
            if watch.consecutiveFailures >= 3, let poll = watch.lastPoll {
                subtitle = "⚠️ ESPN injoignable depuis \(poll.dingRelative) · le secours reste programmé"
            } else if let poll = watch.lastPoll {
                subtitle = "DingDing suit la soirée en direct · vérifié \(poll.dingRelative)"
            } else {
                subtitle = "DingDing suit la soirée en direct"
            }
        } else if !statuses.isEmpty, statuses.allSatisfy({ $0 == .paused }) {
            status = .paused
            title = "Veille en pause"
            subtitle = "Seule l'alarme de secours sonnera · touche pour reprendre"
        } else {
            status = .waiting
            title = "Veille en attente"
            subtitle = "Elle démarre toute seule 24 h avant l'événement"
        }
    }

    var color: Color {
        switch status {
        case .active: .gold
        case .paused: .orange
        case .waiting: .secondary
        }
    }

    var symbol: String {
        switch status {
        case .active: "moon.zzz.fill"
        case .paused: "pause.circle.fill"
        case .waiting: "moon"
        }
    }
}

struct VeilleStatusLabel: View {
    var summary: VeilleSummary
    var compact = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: summary.symbol)
                .font(compact ? .body : .title3)
                .foregroundStyle(summary.color)
                .symbolEffect(.pulse, options: .repeat(.continuous), isActive: summary.status == .active)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(summary.title).font(.subheadline.weight(.bold))
                Text(summary.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 4)
            Image(systemName: "info.circle")
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}

// MARK: - One upcoming ring

struct UpcomingRingRow: View {
    @Environment(AppStore.self) private var store
    var ring: UpcomingRing
    var showEvent = false

    var body: some View {
        let live = store.detail(for: ring.alarm.eventId)?.isLive == true
        HStack(spacing: 12) {
            PairAvatars(fighters: ring.fight?.fighters ?? [], size: 38)
            VStack(alignment: .leading, spacing: 3) {
                Text(ring.alarm.fightLabel)
                    .font(.subheadline.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                HStack(spacing: 4) {
                    Image(systemName: ring.kind.symbol)
                    Text(ring.kind.shortTitle)
                    if showEvent {
                        Text("· \(store.summary(for: ring.alarm.eventId)?.shortName ?? ring.alarm.eventName)")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.ding)
                .lineLimit(1)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 1) {
                Text(ring.date.map { "≈ \($0.dingTime)" } ?? "—")
                    .font(.system(size: 20, weight: .heavy).width(.condensed).monospacedDigit())
                TimelineView(.periodic(from: .now, by: 30)) { _ in
                    Text(caption(live: live))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .contentShape(Rectangle())
    }

    private func caption(live: Bool) -> String {
        if live, let n = ring.fightsBefore {
            return n <= 0 ? "au prochain combat" : "encore \(n) combat\(n > 1 ? "s" : "")"
        }
        return ring.date.map(shortCountdown(to:)) ?? ""
    }
}

// MARK: - Home: "Prochaines alarmes" + veille status in one card

struct UpcomingRingsPanel: View {
    @Environment(AppStore.self) private var store
    @State private var showInfo = false

    var body: some View {
        let rings = store.upcomingRings(withinHours: 24)
        if !rings.isEmpty {
            let eventIds = Set(rings.map(\.alarm.eventId))
            let summary = VeilleSummary(eventIds: eventIds, store: store)
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "Prochaines alarmes", trailing: rings.count > 1 ? "\(rings.count)" : nil)
                    .padding(.top, 0)
                VStack(spacing: 0) {
                    Button { showInfo = true } label: {
                        VeilleStatusLabel(summary: summary)
                            .padding(14)
                    }
                    .buttonStyle(.plain)

                    ForEach(rings) { ring in
                        Divider().overlay(Color.white.opacity(0.06)).padding(.leading, 14)
                        NavigationLink(value: ring.alarm.eventId) {
                            UpcomingRingRow(ring: ring, showEvent: eventIds.count > 1)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 11)
                        }
                        .buttonStyle(PressableStyle())
                    }
                }
                .dingCard(tint: summary.status == .active ? .gold : nil)
            }
            .sheet(isPresented: $showInfo) {
                VeilleInfoSheet()
                    .presentationDetents([.large])
            }
        }
    }
}

// MARK: - Event page: one line

struct VeilleStrip: View {
    @Environment(AppStore.self) private var store
    var eventId: String
    @State private var showInfo = false

    var body: some View {
        let summary = VeilleSummary(eventIds: [eventId], store: store)
        Button { showInfo = true } label: {
            VeilleStatusLabel(summary: summary, compact: true)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .dingCard(cornerRadius: 16, tint: summary.status == .active ? .gold : nil)
        }
        .buttonStyle(PressableStyle())
        .sheet(isPresented: $showInfo) {
            VeilleInfoSheet()
                .presentationDetents([.large])
        }
    }
}

// MARK: - What the veille is, and per-event switches

struct VeilleInfoSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    private var events: [EventSummary] {
        store.eventsWithAlarms
            .compactMap { store.summary(for: $0) }
            .filter { WatchService.shared.needsWatching($0.id, store: store) }
            .sorted { $0.date < $1.date }
    }

    var body: some View {
        let watch = WatchService.shared
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 10) {
                        Image(systemName: "moon.zzz.fill")
                            .font(.system(size: 44))
                            .foregroundStyle(Color.gold)
                            .symbolEffect(.pulse, options: .repeat(.continuous))
                        Text("Dors tranquille")
                            .font(.title2.weight(.heavy))
                        Text("iOS endort les apps en arrière-plan. La veille garde DingDing éveillée pendant la nuit pour suivre la soirée **en direct** et faire sonner ton alarme **pile au bon moment**, même si les combats finissent plus tôt ou plus tard que prévu.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
                .listRowBackground(Color.clear)

                if !events.isEmpty {
                    Section {
                        ForEach(events) { event in
                            Toggle(isOn: Binding(
                                get: { store.watchedEventIds.contains(event.id) },
                                set: { on in
                                    if on { watch.start(eventId: event.id, store: store, byUser: true) }
                                    else { watch.stop(eventId: event.id, store: store, byUser: true) }
                                }
                            )) {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        LeagueBadge(league: event.league)
                                        Text(event.shortName).font(.subheadline.weight(.semibold))
                                    }
                                    Text(statusText(event))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .tint(.gold)
                        }
                    } header: {
                        Text("Suivre en direct")
                    } footer: {
                        Text("Automatique : elle démarre seule dès qu'une de tes alarmes est dans moins de 24 h et s'arrête quand elles ont toutes sonné. Coupe-la seulement si tu ne veux pas qu'elle tourne.")
                    }
                }

                Section("Comment ça marche") {
                    InfoRow(symbol: "antenna.radiowaves.left.and.right", color: .ding,
                            title: "Suivi ESPN en direct",
                            text: "Toutes les 30 s pendant la soirée. Si un combat se termine au premier round, l'alarme sonne quand même au bon moment.")
                    InfoRow(symbol: "shield.lefthalf.filled", color: .green,
                            title: "Alarme de secours",
                            text: "Programmée à l'heure estimée, au cas où iOS couperait DingDing. Tant que la veille tourne, elle est repoussée et ne sonne pas pour rien.")
                    InfoRow(symbol: "rectangle.badge.checkmark", color: .blue,
                            title: "Écran verrouillé",
                            text: "La soirée s'affiche sur l'écran verrouillé et dans la Dynamic Island.")
                }

                Section("Pour que ça marche à coup sûr") {
                    InfoRow(symbol: "battery.100percent.bolt", color: .green,
                            title: "Laisse l'iPhone en charge", text: nil)
                    InfoRow(symbol: "xmark.app", color: .orange,
                            title: "Ne ferme pas DingDing", text: "Pas de balayage vers le haut dans le sélecteur d'apps. Verrouiller l'écran ne pose aucun problème.")
                    InfoRow(symbol: "speaker.slash", color: .gray,
                            title: "Mode silencieux ou Concentration", text: "Aucun souci : c'est une vraie alarme, elle sonne quand même.")
                }

                if let poll = watch.lastPoll {
                    Section {
                        LabeledContent("Dernière vérification", value: poll.dingRelative)
                    }
                }
            }
            .navigationTitle("Veille")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") { dismiss() }.bold()
                }
            }
        }
    }

    private func statusText(_ event: EventSummary) -> String {
        switch WatchService.shared.status(for: event.id, store: store) {
        case .active: return "En veille · \(event.date.dingDayTime)"
        case .paused: return "En pause · seule l'alarme de secours sonnera"
        case .waiting: return "Démarrera seule · \(event.date.dingDayTime)"
        }
    }
}

private struct InfoRow: View {
    var symbol: String
    var color: Color
    var title: String
    var text: String?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(color)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                if let text {
                    Text(text).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

#Preview {
    NavigationStack {
        ScrollView { UpcomingRingsPanel().padding() }
    }
    .environment(PreviewData.store)
    .preferredColorScheme(.dark)
}
