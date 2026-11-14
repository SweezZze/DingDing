import SwiftUI

// MARK: - Home ("Combats" tab), Apple Sports style

struct EventsView: View {
    @Environment(AppStore.self) private var store
    @State private var path: [String] = []
    @State private var filter: League?

    var body: some View {
        let featured = store.featuredEvent
        let others = store.upcomingEvents.filter { $0.id != featured?.id && (filter == nil || $0.league == filter) }

        NavigationStack(path: $path) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12, pinnedViews: []) {
                    ExpiryBanner()

                    if let error = store.lastError {
                        Label(error, systemImage: "wifi.exclamationmark")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }

                    UpcomingRingsPanel()

                    if let featured {
                        NavigationLink(value: featured.id) {
                            FeaturedEventCard(event: featured)
                        }
                        .buttonStyle(PressableStyle())
                        .contextMenu { pinMenu(featured.id) }
                    }

                    LeagueFilterBar(selection: $filter)
                        .padding(.top, 10)

                    ForEach(groupByDay(others), id: \.day) { group in
                        Text(group.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.top, 10)
                            .padding(.leading, 4)
                        ForEach(group.events) { event in
                            NavigationLink(value: event.id) {
                                EventScoreCard(event: event)
                            }
                            .buttonStyle(PressableStyle())
                            .contextMenu { pinMenu(event.id) }
                        }
                    }

                    if others.isEmpty, featured != nil {
                        Text("Aucun autre événement \(filter.map { $0.displayName + " " } ?? "")pour le moment.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 20)
                    }

                    if let last = store.lastRefresh {
                        Text("Données ESPN · mises à jour \(last.dingRelative)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 12)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
            #if DEBUG
            .defaultScrollAnchor(ProcessInfo.processInfo.arguments.contains("-scrollBottom") ? .bottom : .top)
            #endif
            .background(Color.black.ignoresSafeArea())
            .overlay {
                if store.upcomingEvents.isEmpty {
                    if store.isLoading {
                        ProgressView("Chargement des cartes…")
                    } else {
                        ContentUnavailableView("Aucun événement", systemImage: "calendar.badge.exclamationmark",
                                               description: Text("Tire vers le bas pour actualiser."))
                    }
                }
            }
            .navigationTitle("Combats")
            .navigationDestination(for: String.self) { eventId in
                EventDetailView(eventId: eventId)
            }
            .refreshable { await store.refreshAll() }
            #if DEBUG
            .task { await debugLaunchActions() }
            #endif
        }
    }

    @ViewBuilder
    private func pinMenu(_ eventId: String) -> some View {
        Button {
            withAnimation(.snappy) { store.togglePin(eventId) }
        } label: {
            if store.isPinned(eventId) {
                Label("Désépingler", systemImage: "pin.slash")
            } else {
                Label("Épingler en haut", systemImage: "pin")
            }
        }
    }

    private struct DayGroup {
        var day: Date
        var title: String
        var events: [EventSummary]
    }

    private func groupByDay(_ events: [EventSummary]) -> [DayGroup] {
        let calendar = Calendar.current
        var groups: [DayGroup] = []
        for event in events {
            let day = calendar.startOfDay(for: event.date)
            if let i = groups.firstIndex(where: { $0.day == day }) {
                groups[i].events.append(event)
            } else {
                let title: String
                if calendar.isDateInToday(day) { title = "Aujourd'hui" }
                else if calendar.isDateInTomorrow(day) { title = "Demain" }
                else { title = day.formatted(.dateTime.weekday(.wide).day().month(.wide)).capitalizedFirst }
                groups.append(DayGroup(day: day, title: title, events: [event]))
            }
        }
        return groups
    }

    #if DEBUG
    /// Launch arguments used to take screenshots in the simulator.
    private func debugLaunchActions() async {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-simulate") {
            await store.startSimulation()
            if let id = store.simulation?.template.summary.id { path = [id] }
        } else if let i = args.firstIndex(of: "-openEvent"), i + 1 < args.count {
            path = [args[i + 1]]
        }
        if args.contains("-demoAlarms") {
            if store.details.isEmpty { await store.refreshAll() }
            for event in store.upcomingEvents.prefix(2) {
                guard let detail = store.detail(for: event.id) else { continue }
                for fight in detail.activeFights.suffix(2) where store.alarms[fight.id] == nil {
                    store.setTriggers([.fightsBefore(1), .endOfPrevious], fight: fight, event: event)
                }
            }
        }

    }
    #endif
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

/// Slight shrink when pressed, like Apple Sports cards.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.snappy(duration: 0.2), value: configuration.isPressed)
    }
}

/// Countdown text: "Dans 1 j 4 h", "Dans 35 min", "En direct".
func countdownText(to date: Date, live: Bool, over: Bool) -> String {
    if over { return "Terminé" }
    if live { return "En direct" }
    let seconds = date.timeIntervalSinceNow
    if seconds <= 0 { return "Imminent" }
    let minutes = Int(seconds / 60)
    let days = minutes / 1440, hours = (minutes % 1440) / 60, mins = minutes % 60
    if days > 0 { return "Dans \(days) j \(hours) h" }
    if hours > 0 { return "Dans \(hours) h \(String(format: "%02d", mins))" }
    return "Dans \(mins) min"
}

extension League {
    var color: Color {
        switch self {
        case .ufc: .ding
        case .pfl: Color(red: 0.20, green: 0.45, blue: 1.0)
        }
    }
}

// MARK: - League chips

struct LeagueFilterBar: View {
    @Binding var selection: League?

    var body: some View {
        HStack(spacing: 8) {
            chip("Tous", selected: selection == nil) { selection = nil }
            ForEach(League.allCases) { league in
                chip(league.displayName, selected: selection == league, color: league.color) {
                    selection = selection == league ? nil : league
                }
            }
            Spacer()
        }
    }

    private func chip(_ title: String, selected: Bool, color: Color = .white, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.snappy) { action() }
        } label: {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(selected ? color.opacity(color == .white ? 0.9 : 1) : Color(white: 0.14), in: Capsule())
                .foregroundStyle(selected ? (color == .white ? Color.black : Color.white) : Color.white)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Featured (pinned / next) event

struct FeaturedEventCard: View {
    @Environment(AppStore.self) private var store
    var event: EventSummary

    var body: some View {
        let detail = store.detail(for: event.id)
        let active = detail?.activeFights ?? []
        let main = active.last
        let live = detail?.isLive == true
        let over = detail?.isOver == true
        let pinned = store.isPinned(event.id)
        let hide = store.hidesResults(for: event.id)
        let mainCard = active.filter { $0.segment == "main" }.reversed().prefix(4)

        VStack(spacing: 0) {
            // Header
            HStack(spacing: 6) {
                Image(systemName: pinned ? "pin.fill" : (live ? "dot.radiowaves.left.and.right" : "sparkles"))
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(pinned ? Color.gold : event.league.color)
                Text(pinned ? "ÉPINGLÉ" : (live ? "EN DIRECT" : "PROCHAIN ÉVÉNEMENT"))
                    .font(.caption2.weight(.heavy))
                    .tracking(0.8)
                    .foregroundStyle(.secondary)
                Spacer()
                LeagueBadge(league: event.league)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)

            // Face-off with the "scoreboard" in the middle
            ZStack(alignment: .bottom) {
                Ellipse()
                    .fill(event.league.color.opacity(0.55))
                    .frame(width: 300, height: 150)
                    .blur(radius: 60)
                    .offset(y: 30)
                    .frame(maxWidth: .infinity)
                    .frame(height: 190)
                if let main, main.fighters.count == 2 {
                    HStack(alignment: .bottom, spacing: 0) {
                        Headshot(fighter: main.fighters[0], height: 175, mirrored: true)
                        Headshot(fighter: main.fighters[1], height: 175)
                    }
                    .mask(LinearGradient(colors: [.black, .black, .black.opacity(0.05)], startPoint: .top, endPoint: .bottom))
                } else {
                    Image(systemName: "figure.boxing")
                        .font(.system(size: 90))
                        .foregroundStyle(.white.opacity(0.25))
                        .frame(height: 175)
                }

                // Central status, like a score
                VStack(spacing: 2) {
                    TimelineView(.periodic(from: .now, by: 30)) { _ in
                        Text(centerStatus(detail: detail, live: live, over: over))
                            .font(.system(size: 26, weight: .heavy).width(.condensed).monospacedDigit())
                            .foregroundStyle(live ? Color.ding : .white)
                    }
                    Text(centerCaption(detail: detail, live: live, over: over))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.75))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial.opacity(0.9), in: RoundedRectangle(cornerRadius: 12))
                .padding(.bottom, 52)
            }

            // Names
            if let main, main.fighters.count == 2 {
                HStack(alignment: .top) {
                    FighterName(fighter: main.fighters[0], alignment: .leading)
                    Spacer(minLength: 8)
                    FighterName(fighter: main.fighters[1], alignment: .trailing)
                }
                .padding(.horizontal, 16)
                .padding(.top, -44)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(event.name)
                    .font(.title3.weight(.heavy))
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                HStack(spacing: 6) {
                    if let main, main.isTitleFight {
                        Text("Titre · \(main.weightClass)").foregroundStyle(Color.gold)
                    }
                    if let venue = event.venue {
                        Text(venue).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .font(.caption.weight(.semibold))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 12)

            if live, let detail {
                LiveProgress(detail: detail)
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
            }

            // Mini scoreboard of the main card
            if mainCard.count > 1 {
                VStack(spacing: 0) {
                    ForEach(Array(mainCard.dropFirst())) { fight in
                        Divider().overlay(Color.white.opacity(0.06))
                        MiniFightRow(fight: fight, hideResult: hide, hasAlarm: store.alarms[fight.id] != nil)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
            }

            // Footer
            HStack(spacing: 6) {
                let alarms = store.alarms(forEvent: event.id)
                if alarms.isEmpty {
                    Image(systemName: "bell.badge").foregroundStyle(Color.ding)
                    Text("Régler mes alarmes")
                } else {
                    Image(systemName: "bell.fill").foregroundStyle(Color.ding)
                    Text("\(alarms.count) combat\(alarms.count > 1 ? "s" : "") suivi\(alarms.count > 1 ? "s" : "")")
                    if store.watchedEventIds.contains(event.id) {
                        Image(systemName: "moon.zzz.fill").foregroundStyle(Color.gold)
                    }
                }
                Spacer()
                Text("Voir la carte complète")
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .font(.footnote.weight(.semibold))
            .padding(16)
        }
        .background(Color(white: 0.09))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(.white.opacity(0.07)))
        .foregroundStyle(.white)
    }

    private func centerStatus(detail: EventDetail?, live: Bool, over: Bool) -> String {
        if over { return "TERMINÉ" }
        if live, let fight = detail?.activeFights.first(where: { $0.state == .live }) {
            return fight.round.map { "R\($0)" } ?? "LIVE"
        }
        if live { return "LIVE" }
        let mainStart = detail?.segments.last?.start ?? event.date
        if mainStart.timeIntervalSinceNow < 20 * 3600 { return mainStart.dingTime }
        return mainStart.formatted(.dateTime.weekday(.abbreviated).day()).uppercased()
    }

    private func centerCaption(detail: EventDetail?, live: Bool, over: Bool) -> String {
        if over { return event.date.formatted(.dateTime.day().month(.abbreviated)) }
        if live {
            if let fight = detail?.activeFights.first(where: { $0.state == .live }) { return fight.label }
            return "Entre deux combats"
        }
        let mainStart = detail?.segments.last?.start ?? event.date
        if mainStart.timeIntervalSinceNow < 20 * 3600 { return "Main card · " + countdownText(to: mainStart, live: false, over: false).lowercased() }
        return "Main card \(mainStart.dingTime)"
    }
}

struct Headshot: View {
    var fighter: Fighter
    var height: CGFloat
    var mirrored = false

    var body: some View {
        AsyncImage(url: fighter.headshotURL) { phase in
            if let image = phase.image {
                image.resizable().scaledToFit()
            } else {
                Image(systemName: "person.fill")
                    .font(.system(size: height * 0.4))
                    .foregroundStyle(.white.opacity(0.2))
            }
        }
        .scaleEffect(x: mirrored ? -1 : 1, y: 1)
        .frame(maxWidth: .infinity, maxHeight: height, alignment: .bottom)
    }
}

struct FighterName: View {
    var fighter: Fighter
    var alignment: HorizontalAlignment

    var body: some View {
        VStack(alignment: alignment, spacing: 0) {
            Text(fighter.name.split(separator: " ").first.map(String.init) ?? "")
                .font(.caption.weight(.medium))
                .foregroundStyle(.white.opacity(0.75))
            Text(fighter.lastName.uppercased())
                .font(.system(size: 22, weight: .heavy).width(.condensed))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let record = fighter.record {
                Text(record).font(.caption2.monospacedDigit()).foregroundStyle(.white.opacity(0.6))
            }
        }
        .shadow(color: .black.opacity(0.9), radius: 6)
    }
}

/// One line of the main card inside the featured card.
struct MiniFightRow: View {
    var fight: Fight
    var hideResult: Bool
    var hasAlarm: Bool

    var body: some View {
        let winner = hideResult ? nil : fight.result?.winnerId
        HStack(spacing: 8) {
            side(fight.fighters.first, leading: true, winner: winner)
            VStack(spacing: 0) {
                switch fight.state {
                case .live:
                    Text(fight.round.map { "R\($0)" } ?? "LIVE").foregroundStyle(Color.ding)
                case .finished:
                    Text(hideResult ? "FIN" : (fight.result?.method.map(Fight.frenchMethod) ?? "FIN"))
                        .foregroundStyle(.secondary)
                case .canceled:
                    Text("ANNULÉ").foregroundStyle(.orange)
                case .scheduled:
                    Image(systemName: hasAlarm ? "bell.fill" : "circle.fill")
                        .font(.system(size: hasAlarm ? 11 : 4))
                        .foregroundStyle(hasAlarm ? Color.ding : Color.white.opacity(0.25))
                }
            }
            .font(.caption2.weight(.bold).width(.condensed))
            .lineLimit(1)
            .frame(width: 64)
            side(fight.fighters.dropFirst().first, leading: false, winner: winner)
        }
        .padding(.vertical, 8)
    }

    private func side(_ fighter: Fighter?, leading: Bool, winner: String?) -> some View {
        let lost = winner != nil && winner != fighter?.id
        return HStack(spacing: 8) {
            if !leading { Spacer(minLength: 0) }
            if leading { FighterAvatar(fighter: fighter, size: 30, dimmed: lost) }
            Text(fighter?.lastName ?? "?")
                .font(.subheadline.weight(winner == fighter?.id ? .heavy : .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .opacity(lost ? 0.5 : 1)
            if !leading { FighterAvatar(fighter: fighter, size: 30, dimmed: lost) }
            if leading { Spacer(minLength: 0) }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Other events: scoreboard-style cards

struct EventScoreCard: View {
    @Environment(AppStore.self) private var store
    var event: EventSummary

    var body: some View {
        let detail = store.detail(for: event.id)
        let main = detail?.activeFights.last
        let live = detail?.isLive == true
        let over = detail?.isOver == true
        let alarmCount = store.alarms(forEvent: event.id).count
        let mainStart = detail?.segments.last?.start ?? event.date
        let names = main?.fighters ?? namesFromTitle

        VStack(spacing: 10) {
            HStack(spacing: 6) {
                LeagueBadge(league: event.league)
                Text(shortTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                if store.isPinned(event.id) {
                    Image(systemName: "pin.fill").font(.caption2).foregroundStyle(Color.gold)
                }
                if alarmCount > 0 {
                    Label("\(alarmCount)", systemImage: "bell.fill")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Color.ding)
                }
            }

            HStack(spacing: 0) {
                fighterSide(names.first, leading: true)
                VStack(spacing: 1) {
                    if live {
                        Text("LIVE").font(.system(size: 18, weight: .heavy).width(.condensed)).foregroundStyle(Color.ding)
                    } else if over {
                        Text("FIN").font(.system(size: 18, weight: .heavy).width(.condensed)).foregroundStyle(.secondary)
                    } else {
                        Text(mainStart.dingTime)
                            .font(.system(size: 22, weight: .heavy).width(.condensed).monospacedDigit())
                    }
                    Text(over ? "Terminé" : (live ? "En cours" : "Main card"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(width: 78)
                fighterSide(names.dropFirst().first, leading: false)
            }
        }
        .padding(14)
        .background(Color(white: 0.09), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.white.opacity(0.06)))
        .foregroundStyle(.white)
    }

    /// "UFC 336: Van vs. Kape" → two placeholder fighters when ESPN has no card yet.
    private var namesFromTitle: [Fighter] {
        guard let part = event.name.components(separatedBy: ":").dropFirst().first else { return [] }
        let sides = part.components(separatedBy: " vs").map {
            $0.trimmingCharacters(in: CharacterSet(charactersIn: ". ")).trimmingCharacters(in: .whitespaces)
        }
        guard sides.count == 2, sides.allSatisfy({ !$0.isEmpty }) else { return [] }
        return sides.map { Fighter(id: "title-\($0)", name: $0, shortName: $0) }
    }

    /// "UFC 334", "UFC Fight Night", "PFL Lyon"
    private var shortTitle: String {
        event.name.components(separatedBy: ":").first?.trimmingCharacters(in: .whitespaces) ?? event.shortName
    }

    private func fighterSide(_ fighter: Fighter?, leading: Bool) -> some View {
        HStack(spacing: 10) {
            if !leading { Spacer(minLength: 0) }
            if leading { FighterAvatar(fighter: fighter, size: 48) }
            VStack(alignment: leading ? .leading : .trailing, spacing: 1) {
                Text((fighter.map { $0.id.hasPrefix("title-") ? $0.name : $0.lastName } ?? "À venir").uppercased())
                    .font(.system(size: 17, weight: .heavy).width(.condensed))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if let record = fighter?.record {
                    Text(record).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            if !leading { FighterAvatar(fighter: fighter, size: 48) }
            if leading { Spacer(minLength: 0) }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Shared pieces used by the event page

/// Two fighters facing each other, ESPN cut-out headshots.
struct FaceOff: View {
    var fight: Fight
    var height: CGFloat

    var body: some View {
        let a = fight.fighters[0], b = fight.fighters[1]
        ZStack(alignment: .bottom) {
            HStack(alignment: .bottom, spacing: 0) {
                Headshot(fighter: a, height: height, mirrored: true)
                Headshot(fighter: b, height: height)
            }
            .frame(height: height)
            .mask(LinearGradient(colors: [.black, .black, .clear], startPoint: .top, endPoint: .bottom))

            HStack(alignment: .lastTextBaseline) {
                FighterName(fighter: a, alignment: .leading)
                Spacer()
                Text("VS").font(.title3.weight(.black)).foregroundStyle(.white.opacity(0.85))
                Spacer()
                FighterName(fighter: b, alignment: .trailing)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 6)
        }
    }
}

/// "Early prelims 23:00 · Prelims 01:00 · Main card 03:00"
struct SegmentTimes: View {
    var detail: EventDetail?
    var fallback: Date

    var body: some View {
        if let detail, !detail.segments.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text(detail.segments.first!.start.formatted(.dateTime.weekday(.wide).day().month(.wide)).capitalizedFirst)
                    .font(.subheadline.weight(.semibold))
                HStack(spacing: 10) {
                    ForEach(detail.segments, id: \.key) { segment in
                        HStack(spacing: 3) {
                            Text(segment.name).foregroundStyle(.white.opacity(0.65))
                            Text(segment.start.dingTime).fontWeight(.bold).monospacedDigit()
                        }
                    }
                }
                .font(.caption)
            }
        } else {
            Text(fallback.dingDayTime).font(.subheadline)
        }
    }
}

struct LiveProgress: View {
    var detail: EventDetail

    var body: some View {
        let active = detail.activeFights
        let done = active.filter { $0.state == .finished }.count
        VStack(alignment: .leading, spacing: 4) {
            ProgressView(value: Double(done), total: Double(max(active.count, 1)))
                .tint(Color.ding)
            HStack {
                if let live = active.first(where: { $0.state == .live }) {
                    Circle().fill(Color.ding).frame(width: 6, height: 6)
                    Text("\(live.label) · \(live.liveText)").lineLimit(1).minimumScaleFactor(0.7)
                } else if let next = active.first(where: { $0.state == .scheduled }) {
                    Text("Prochain : \(next.label)")
                }
                Spacer()
                Text("\(done)/\(active.count) combats").monospacedDigit()
            }
            .font(.caption.weight(.semibold))
        }
    }
}

/// Warns when the free 7-day signature is about to expire.
struct ExpiryBanner: View {
    var body: some View {
        if let expiry = AppExpiry.date, expiry.timeIntervalSinceNow < 2 * 86400 {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "clock.badge.exclamationmark").font(.title3).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("DingDing expire \(expiry.dingRelative)").font(.subheadline.weight(.bold))
                    Text("Allume le Mac et mets l'iPhone sur le même Wi-Fi : il la renouvelle tout seul.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
        }
    }
}

#Preview {
    EventsView()
        .environment(PreviewData.store)
        .preferredColorScheme(.dark)
}
