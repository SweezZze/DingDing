import SwiftUI

struct AlarmsView: View {
    @Environment(AppStore.self) private var store
    @State private var editing: Fight?

    /// Alarms that will still ring, grouped by event (soonest event first).
    private var pendingGroups: [(eventId: String, alarms: [FightAlarm])] {
        let pending = store.alarms.values.filter { store.nextRing(for: $0) != nil }
        let ids = Set(pending.map(\.eventId))
        return ids
            .sorted { (store.summary(for: $0)?.date ?? .distantFuture) < (store.summary(for: $1)?.date ?? .distantFuture) }
            .map { id in (id, store.alarms(forEvent: id).filter { store.nextRing(for: $0) != nil }) }
    }

    private var doneAlarms: [FightAlarm] {
        store.alarms.values
            .filter { store.nextRing(for: $0) == nil }
            .sorted { ($0.estimatedStart ?? .distantPast) > ($1.estimatedStart ?? .distantPast) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if !AlarmScheduler.isAuthorized {
                        authorizationCard
                    }

                    if let next = store.upcomingRings().first {
                        Button { open(next.alarm) } label: { NextRingHero(ring: next) }
                            .buttonStyle(PressableStyle())
                    }

                    ForEach(pendingGroups, id: \.eventId) { group in
                        eventHeader(group.eventId)
                        VStack(spacing: 0) {
                            ForEach(Array(group.alarms.enumerated()), id: \.element.id) { index, alarm in
                                if index > 0 { Divider().overlay(Color.white.opacity(0.06)).padding(.leading, 66) }
                                alarmButton(alarm)
                            }
                        }
                        .dingCard()
                    }

                    if !doneAlarms.isEmpty {
                        HStack {
                            SectionHeader(title: "Déjà sonnées ou terminées")
                            Button("Effacer") {
                                withAnimation { for alarm in doneAlarms { store.removeAlarm(alarm.id) } }
                            }
                            .font(.caption.weight(.semibold))
                            .padding(.top, 14)
                        }
                        VStack(spacing: 0) {
                            ForEach(Array(doneAlarms.enumerated()), id: \.element.id) { index, alarm in
                                if index > 0 { Divider().overlay(Color.white.opacity(0.06)).padding(.leading, 66) }
                                alarmButton(alarm)
                            }
                        }
                        .dingCard()
                        .opacity(0.7)
                    }

                    if !store.alarms.isEmpty {
                        Label("Touche une alarme pour la modifier, ou appuie longuement pour la supprimer.", systemImage: "hand.tap")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.top, 8)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 30)
            }
            .scrollIndicators(.hidden)
            .background(Color.black.ignoresSafeArea())
            .overlay {
                if store.alarms.isEmpty {
                    ContentUnavailableView {
                        Label("Aucune alarme", systemImage: "bell.slash")
                    } description: {
                        Text("Ouvre un événement dans l'onglet Combats et touche un combat pour choisir quand DingDing doit te réveiller.")
                    }
                }
            }
            .navigationTitle("Alarmes")
            .navigationDestination(for: String.self) { EventDetailView(eventId: $0) }
            .sheet(item: $editing) { fight in
                if let alarm = store.alarms[fight.id], let detail = store.detail(for: alarm.eventId) {
                    FightAlarmSheet(fight: fight, detail: detail)
                        .presentationDetents([.large])
                }
            }
        }
    }

    private func open(_ alarm: FightAlarm) {
        if let fight = store.detail(for: alarm.eventId)?.fights.first(where: { $0.id == alarm.id }) {
            editing = fight
        }
    }

    private func alarmButton(_ alarm: FightAlarm) -> some View {
        Button { open(alarm) } label: {
            AlarmRow(alarm: alarm)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) {
                withAnimation { store.removeAlarm(alarm.id) }
            } label: {
                Label("Supprimer l'alarme", systemImage: "trash")
            }
        }
    }

    private func eventHeader(_ eventId: String) -> some View {
        let summary = store.summary(for: eventId)
        return NavigationLink(value: eventId) {
            HStack(spacing: 8) {
                if let summary { LeagueBadge(league: summary.league) }
                Text(summary?.shortName ?? "Événement")
                    .font(.subheadline.weight(.heavy))
                if let date = summary?.date {
                    Text(date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("Carte").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Image(systemName: "chevron.right").font(.caption2.weight(.bold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 6)
            .padding(.top, 14)
        }
        .buttonStyle(.plain)
    }

    private var authorizationCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").font(.title3).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 6) {
                Text("Les alarmes ne sont pas autorisées").font(.subheadline.weight(.bold))
                Text("Sans autorisation, DingDing ne peut pas sonner. Réglages iOS → DingDing → Alarmes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Autoriser") { Task { await AlarmScheduler.requestAuthorization() } }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dingCard(tint: .orange)
    }
}

// MARK: - Big "next alarm" card

struct NextRingHero: View {
    @Environment(AppStore.self) private var store
    var ring: UpcomingRing

    var body: some View {
        let summary = store.summary(for: ring.alarm.eventId)
        let live = store.detail(for: ring.alarm.eventId)?.isLive == true
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("PROCHAINE ALARME")
                        .font(.caption2.weight(.heavy))
                        .tracking(0.8)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let summary { LeagueBadge(league: summary.league) }
                }
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text("≈").font(.title2.weight(.heavy)).foregroundStyle(.secondary)
                            Text(ring.date?.dingTime ?? "--:--")
                                .font(.system(size: 56, weight: .heavy).width(.condensed).monospacedDigit())
                        }
                        Label(ring.kind.title, systemImage: ring.kind.symbol)
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(Color.ding)
                        Text("\(ring.alarm.fightLabel) · \(summary?.shortName ?? ring.alarm.eventName)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    if let fighters = ring.fight?.fighters {
                        PairAvatars(fighters: fighters, size: 58)
                    }
                }
                TimelineView(.periodic(from: .now, by: 30)) { _ in
                    HStack(spacing: 6) {
                        if let date = ring.date { Pill(text: shortCountdown(to: date).capitalizedFirst, color: .white) }
                        if live, let n = ring.fightsBefore {
                            Pill(text: n <= 0 ? "Au prochain combat" : "Encore \(n) combat\(n > 1 ? "s" : "")", color: .gold)
                        }
                        if store.watchedEventIds.contains(ring.alarm.eventId) {
                            Pill(text: "Veille active", color: .gold)
                        }
                    }
                }
                .padding(.top, 4)
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity)
        .background(alignment: .topTrailing) {
            Circle()
                .fill(Color.ding.opacity(0.45))
                .frame(width: 220, height: 220)
                .blur(radius: 70)
                .offset(x: 60, y: -70)
        }
        .dingCard(cornerRadius: 24, tint: .ding)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .foregroundStyle(.white)
    }
}

// MARK: - One alarm

struct AlarmRow: View {
    @Environment(AppStore.self) private var store
    var alarm: FightAlarm

    var body: some View {
        let detail = store.detail(for: alarm.eventId)
        let fight = detail?.fights.first { $0.id == alarm.id }
        let starts = detail.map { store.estimatedStarts(for: $0) } ?? [:]
        let position = detail?.activeFights.firstIndex { $0.id == alarm.id }

        HStack(alignment: .top, spacing: 12) {
            PairAvatars(fighters: fight?.fighters ?? [], size: 40)
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Text(alarm.fightLabel)
                        .font(.subheadline.weight(.bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    if alarm.fromFavorite { Image(systemName: "star.fill").font(.caption2).foregroundStyle(Color.gold) }
                    Spacer(minLength: 4)
                    switch fight?.state {
                    case .live?: LiveBadge(text: fight?.round.map { "R\($0)" } ?? "LIVE")
                    case .finished?: Pill(text: "Terminé")
                    case .canceled?: Pill(text: "Annulé", color: .orange)
                    default:
                        if let start = starts[alarm.id] ?? alarm.estimatedStart {
                            Text("≈ \(start.dingTime)")
                                .font(.caption.weight(.semibold).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if let fight, let position, let detail {
                    Text("\(fight.segmentName) · combat \(position + 1)/\(detail.activeFights.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                FlowLayout(spacing: 6) {
                    ForEach(alarm.triggers) { trigger in
                        let estimate = detail.flatMap { TriggerLogic.estimatedDate(of: trigger.kind, fightId: alarm.id, in: $0, starts: starts) }
                        TriggerTimeChip(kind: trigger.kind, fired: trigger.firedAt, estimate: estimate)
                    }
                }
            }
        }
        .contentShape(Rectangle())
    }
}

/// "① Combat d'avant ≈ 03:56", "✓ Début 04:18"
struct TriggerTimeChip: View {
    var kind: TriggerKind
    var fired: Date?
    var estimate: Date?

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: fired != nil ? "checkmark" : kind.symbol)
            Text(kind.shortTitle)
            if let fired {
                Text(fired.dingTime).monospacedDigit().opacity(0.8)
            } else if let estimate {
                Text("≈ \(estimate.dingTime)").monospacedDigit().foregroundStyle(.white.opacity(0.85))
            }
        }
        .font(.caption2.weight(.bold))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(fired != nil ? Color.white.opacity(0.07) : Color.ding.opacity(0.18)))
        .foregroundStyle(fired != nil ? Color.secondary : Color.ding)
        .lineLimit(1)
    }
}

/// Wraps its children on several lines.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = rows[rows.count - 1].indices.isEmpty ? size.width : rows[rows.count - 1].width + spacing + size.width
            if needed > width, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows.filter { !$0.indices.isEmpty }
    }
}

#Preview {
    AlarmsView()
        .environment(PreviewData.store)
        .preferredColorScheme(.dark)
}
