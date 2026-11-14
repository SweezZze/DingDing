import SwiftUI

struct EventDetailView: View {
    @Environment(AppStore.self) private var store
    var eventId: String
    @State private var selectedFight: Fight?

    var body: some View {
        Group {
            if let detail = store.detail(for: eventId) {
                content(detail)
            } else {
                ProgressView("Chargement de la carte…")
            }
        }
        .navigationTitle(store.summary(for: eventId)?.shortName ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    withAnimation(.snappy) { store.togglePin(eventId) }
                } label: {
                    Image(systemName: store.isPinned(eventId) ? "pin.fill" : "pin")
                }
                .tint(store.isPinned(eventId) ? .gold : .white)
                .accessibilityLabel(store.isPinned(eventId) ? "Désépingler" : "Épingler en haut de l'accueil")
            }
            if store.settings.antiSpoiler {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        if store.revealedEvents.contains(eventId) {
                            store.revealedEvents.remove(eventId)
                        } else {
                            store.revealedEvents.insert(eventId)
                        }
                    } label: {
                        Image(systemName: store.hidesResults(for: eventId) ? "eye.slash" : "eye")
                    }
                    .accessibilityLabel("Afficher les résultats")
                }
            }
        }
        .sheet(item: $selectedFight) { fight in
            if let detail = store.detail(for: eventId) {
                FightAlarmSheet(fight: fight, detail: detail)
                    .presentationDetents([.large])
            }
        }
        #if DEBUG
        .task {
            if ProcessInfo.processInfo.arguments.contains("-alarmSheet") {
                try? await Task.sleep(for: .seconds(3))
                selectedFight = store.detail(for: eventId)?.activeFights.last
            }
        }
        #endif
        .task(id: eventId) {
            // Live refresh while the screen is open.
            while !Task.isCancelled {
                await store.refreshDetail(eventId)
                let live = store.detail(for: eventId)?.isLive == true || eventId.hasPrefix(Simulation.idPrefix)
                try? await Task.sleep(for: .seconds(eventId.hasPrefix(Simulation.idPrefix) ? 3 : (live ? 30 : 180)))
            }
        }
    }

    @ViewBuilder
    private func content(_ detail: EventDetail) -> some View {
        let starts = store.estimatedStarts(for: detail)
        let hide = store.hidesResults(for: eventId)
        let tint = detail.summary.league.color
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                EventHero(detail: detail)

                if let live = detail.activeFights.first(where: { $0.state == .live }) {
                    SectionHeader(title: "En cours")
                    Button { selectedFight = live } label: {
                        LiveFightCard(fight: live, title: "En cours", hasAlarm: store.alarms[live.id] != nil)
                            .padding(14)
                            .dingCard(tint: tint)
                    }
                    .buttonStyle(PressableStyle())
                } else if detail.summary.state == "in", let next = detail.activeFights.first(where: { $0.state == .scheduled }) {
                    SectionHeader(title: "Prochain combat")
                    Button { selectedFight = next } label: {
                        LiveFightCard(fight: next, title: "Prochain combat", estimated: starts[next.id], hasAlarm: store.alarms[next.id] != nil)
                            .padding(14)
                            .dingCard(tint: tint)
                    }
                    .buttonStyle(PressableStyle())
                }

                if !store.alarms(forEvent: eventId).isEmpty, WatchService.shared.needsWatching(eventId, store: store) {
                    VeilleStrip(eventId: eventId)
                        .padding(.top, 4)
                }

                ForEach(detail.segments.reversed(), id: \.key) { segment in
                    SectionHeader(title: segment.name, trailing: segment.start.dingTime)
                    VStack(spacing: 0) {
                        ForEach(Array(segment.fights.reversed().enumerated()), id: \.element.id) { index, fight in
                            if index > 0 { Divider().overlay(Color.white.opacity(0.06)).padding(.leading, 14) }
                            Button {
                                selectedFight = fight
                            } label: {
                                FightRow(fight: fight, estimatedStart: starts[fight.id], hideResult: hide)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 12)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .dingCard()
                }

                Label("Touche un combat pour régler une alarme. Les heures « ≈ » sont estimées et s'affinent en direct pendant la soirée.", systemImage: "hand.tap")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.top, 10)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 30)
        }
        .scrollIndicators(.hidden)
        .background(Color.black.ignoresSafeArea())
        .refreshable { await store.refreshDetail(eventId) }
    }
}

/// Top of the event page: face-off of the main event on a glow of the league colour.
struct EventHero: View {
    var detail: EventDetail

    var body: some View {
        let league = detail.summary.league
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                LeagueBadge(league: league)
                if detail.isLive { LiveBadge() }
                if detail.isOver { Pill(text: "Terminé", color: .white) }
                Spacer()
                if let venue = detail.summary.venue {
                    Label(venue, systemImage: "mappin.and.ellipse")
                        .font(.caption2.weight(.medium))
                        .lineLimit(1)
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            .padding([.horizontal, .top], 14)

            ZStack(alignment: .bottom) {
                Ellipse()
                    .fill(league.color.opacity(0.6))
                    .frame(width: 300, height: 140)
                    .blur(radius: 60)
                    .offset(y: 20)
                    .frame(maxWidth: .infinity)
                if let main = detail.activeFights.last, main.fighters.count == 2 {
                    FaceOff(fight: main, height: 170)
                } else {
                    Image(systemName: "figure.boxing")
                        .font(.system(size: 80))
                        .foregroundStyle(.white.opacity(0.25))
                        .frame(height: 150)
                }
            }
            .frame(height: 185)

            VStack(alignment: .leading, spacing: 8) {
                Text(detail.summary.name)
                    .font(.title3.weight(.heavy))
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                if let main = detail.activeFights.last, main.isTitleFight {
                    Label("Combat pour le titre · \(main.weightClass)", systemImage: "crown.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.gold)
                }
                SegmentTimes(detail: detail, fallback: detail.summary.date)
                if detail.isLive || detail.isOver {
                    LiveProgress(detail: detail).padding(.top, 2)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .dingCard(cornerRadius: 24)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .foregroundStyle(.white)
    }
}

struct FightRow: View {
    @Environment(AppStore.self) private var store
    var fight: Fight
    var estimatedStart: Date?
    var hideResult: Bool

    var body: some View {
        let alarm = store.alarms[fight.id]
        let over = fight.state == .finished || fight.state == .canceled
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                if fight.isMainEvent { Pill(text: "MAIN EVENT", color: .gold) }
                else if fight.isCoMain { Pill(text: "CO-MAIN", color: .gold) }
                if fight.isTitleFight { Pill(text: "TITRE", color: .gold) }
                Text(fight.weightClass).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 4)
                status
                if !over { bell(alarm) }
            }
            HStack(alignment: .center, spacing: 8) {
                fighterView(fight.fighters.first, alignment: .leading)
                Text("VS").font(.caption2.weight(.black)).foregroundStyle(.quaternary)
                fighterView(fight.fighters.dropFirst().first, alignment: .trailing)
            }
            if let alarm, !over {
                HStack(spacing: 6) {
                    ForEach(alarm.triggers) { trigger in
                        TriggerChip(kind: trigger.kind, fired: trigger.firedAt != nil)
                    }
                    if alarm.fromFavorite { Image(systemName: "star.fill").font(.caption2).foregroundStyle(Color.gold) }
                }
            }
        }
        .opacity(over ? 0.75 : 1)
        .contentShape(Rectangle())
    }

    /// Bell on the right: red when an alarm is set, outline otherwise ("tap me").
    private func bell(_ alarm: FightAlarm?) -> some View {
        let pending = alarm.map { !$0.pendingTriggers.isEmpty } ?? false
        return Image(systemName: alarm == nil ? "bell" : (pending ? "bell.fill" : "bell.slash"))
            .font(.caption.weight(.bold))
            .foregroundStyle(alarm == nil ? Color.white.opacity(0.7) : .white)
            .frame(width: 28, height: 28)
            .background(Circle().fill(alarm == nil ? Color.white.opacity(0.08) : (pending ? Color.ding : Color.gray.opacity(0.4))))
            .accessibilityLabel(alarm == nil ? "Régler une alarme" : "Alarme réglée")
    }

    @ViewBuilder
    private var status: some View {
        switch fight.state {
        case .live:
            LiveBadge(text: fight.round.map { "R\($0)" } ?? "LIVE")
        case .finished:
            if !hideResult, let text = fight.resultText {
                Pill(text: text, color: .green)
            } else {
                Pill(text: "Terminé")
            }
        case .canceled:
            Pill(text: "Annulé", color: .orange)
        case .scheduled:
            if let estimatedStart {
                Text("≈ \(estimatedStart.dingTime)")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func fighterView(_ fighter: Fighter?, alignment: HorizontalAlignment) -> some View {
        let isWinner = !hideResult && fight.result?.winnerId != nil && fight.result?.winnerId == fighter?.id
        let isLoser = !hideResult && fight.result?.winnerId != nil && fight.result?.winnerId != fighter?.id
        let favorite = fighter.map { store.isFavorite($0.id) } ?? false
        let leading = alignment == .leading
        return HStack(spacing: 10) {
            if !leading { Spacer(minLength: 0) }
            if leading { avatar(fighter, winner: isWinner, loser: isLoser) }
            VStack(alignment: alignment, spacing: 1) {
                Text(fighter.map { $0.name.split(separator: " ").first.map(String.init) ?? "" } ?? "")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 3) {
                    if favorite && !leading { Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(Color.gold) }
                    Text((fighter?.lastName ?? "?").uppercased())
                        .font(.system(size: 16, weight: isWinner ? .black : .heavy).width(.condensed))
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                    if favorite && leading { Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(Color.gold) }
                }
                Text(fighter?.record ?? "").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
            .opacity(isLoser ? 0.5 : 1)
            if !leading { avatar(fighter, winner: isWinner, loser: isLoser) }
            if leading { Spacer(minLength: 0) }
        }
        .frame(maxWidth: .infinity)
    }

    private func avatar(_ fighter: Fighter?, winner: Bool, loser: Bool) -> some View {
        FighterAvatar(fighter: fighter, size: 44, dimmed: loser)
            .overlay(alignment: .bottomTrailing) {
                if winner {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.white, .green)
                        .background(Circle().fill(.black))
                }
            }
    }
}

/// Small capsule for one trigger of an alarm.
struct TriggerChip: View {
    var kind: TriggerKind
    var fired = false

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: fired ? "checkmark" : kind.symbol)
            Text(kind.shortTitle)
        }
        .font(.caption2.weight(.bold))
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(fired ? Color.white.opacity(0.08) : Color.ding.opacity(0.18)))
        .foregroundStyle(fired ? Color.secondary : Color.ding)
        .lineLimit(1)
    }
}

/// Highlighted card for the fight in progress (or the next one between two fights).
struct LiveFightCard: View {
    var fight: Fight
    var title: String
    var estimated: Date?
    var hasAlarm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                if fight.state == .live { LiveBadge(text: "EN COURS") } else { Pill(text: title.uppercased(), color: .gold) }
                Text(fight.weightClass).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if hasAlarm { Image(systemName: "bell.fill").font(.caption).foregroundStyle(Color.ding) }
                if fight.state == .live {
                    Text(fight.liveText).font(.headline.monospacedDigit()).foregroundStyle(Color.ding)
                } else if let estimated {
                    Text("≈ \(estimated.dingTime)").font(.subheadline.weight(.semibold).monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            HStack(alignment: .top) {
                ForEach(Array(fight.fighters.enumerated()), id: \.element.id) { index, fighter in
                    if index == 1 {
                        Text("VS").font(.caption.weight(.black)).foregroundStyle(.tertiary).padding(.top, 28)
                    }
                    VStack(spacing: 4) {
                        FighterAvatar(fighter: fighter, size: 68)
                        Text(fighter.lastName.uppercased())
                            .font(.system(size: 17, weight: .heavy).width(.condensed))
                            .lineLimit(1).minimumScaleFactor(0.7)
                        Text(fighter.record ?? "").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            if fight.state == .live {
                HStack(spacing: 4) {
                    ForEach(1...(fight.isMainEvent || fight.isTitleFight ? 5 : 3), id: \.self) { r in
                        Capsule()
                            .fill(r < (fight.round ?? 1) ? Color.ding : (r == (fight.round ?? 1) ? Color.ding.opacity(0.6) : Color.white.opacity(0.12)))
                            .frame(height: 4)
                    }
                }
            }
        }
        .contentShape(Rectangle())
        .foregroundStyle(.white)
    }
}

#Preview {
    NavigationStack {
        EventDetailView(eventId: PreviewData.detail.id)
    }
    .environment(PreviewData.store)
    .preferredColorScheme(.dark)
}
