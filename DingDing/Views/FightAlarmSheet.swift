import SwiftUI

/// Choose when DingDing rings for one fight. Changes are saved when the sheet closes
/// (OK button or swipe down).
struct FightAlarmSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var fight: Fight
    var detail: EventDetail

    @State private var selection: Set<TriggerKind> = []
    @State private var loaded = false
    @State private var deleted = false

    private var canSetAlarm: Bool { fight.state == .scheduled || fight.state == .live }

    var body: some View {
        let starts = store.estimatedStarts(for: detail)
        let position = detail.activeFights.firstIndex { $0.id == fight.id } ?? 0
        let alarm = store.alarms[fight.id]

        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    header
                    infoLine(position: position, start: starts[fight.id])

                    if !canSetAlarm {
                        Label(fight.state == .canceled ? "Ce combat est annulé." : "Ce combat est terminé.",
                              systemImage: fight.state == .canceled ? "xmark.circle" : "flag.checkered")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                            .dingCard(cornerRadius: 16)
                    } else {
                        SectionHeader(title: "Me réveiller…", trailing: selection.isEmpty ? nil : "\(selection.count) choisie\(selection.count > 1 ? "s" : "")")
                        VStack(spacing: 0) {
                            let kinds = TriggerKind.all
                            ForEach(Array(kinds.enumerated()), id: \.element) { index, kind in
                                timelineRow(kind, position: position, starts: starts, alarm: alarm,
                                            first: index == 0, last: index == kinds.count - 1)
                            }
                        }
                        .padding(.vertical, 4)
                        .dingCard()

                        Text("Coche autant de moments que tu veux. C'est une vraie alarme : elle sonne même en mode silencieux. Une alarme de secours est aussi programmée à l'heure estimée, au cas où.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                    }

                    if alarm != nil {
                        VStack(spacing: 0) {
                            if alarm?.pendingTriggers.isEmpty == true, canSetAlarm {
                                Button {
                                    store.rearm(fight.id)
                                } label: {
                                    Label("Réarmer les alarmes", systemImage: "arrow.counterclockwise")
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(14)
                                }
                                Divider().overlay(Color.white.opacity(0.06))
                            }
                            Button(role: .destructive) {
                                deleted = true
                                store.removeAlarm(fight.id)
                                dismiss()
                            } label: {
                                Label("Supprimer l'alarme", systemImage: "trash")
                                    .foregroundStyle(.red)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(14)
                            }
                        }
                        .font(.subheadline.weight(.semibold))
                        .dingCard(cornerRadius: 16)
                        .padding(.top, 8)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
            .background(Color(white: 0.03).ignoresSafeArea())
            .navigationTitle(fight.label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") { dismiss() }.bold()
                }
            }
            .onAppear {
                guard !loaded else { return }
                loaded = true
                selection = store.triggers(for: fight.id)
            }
            .onDisappear(perform: commit)
        }
    }

    private func commit() {
        guard loaded, !deleted, canSetAlarm, selection != store.triggers(for: fight.id) else { return }
        store.setTriggers(selection, fight: fight, event: detail.summary)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(fight.fighters.enumerated()), id: \.element.id) { index, fighter in
                if index == 1 {
                    Text("VS")
                        .font(.headline.weight(.black))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 34)
                }
                fighterColumn(fighter)
            }
        }
        .padding(.top, 8)
    }

    private func fighterColumn(_ fighter: Fighter) -> some View {
        let favorite = store.isFavorite(fighter.id)
        return VStack(spacing: 4) {
            FighterAvatar(fighter: fighter, size: 84)
                .overlay(alignment: .bottomTrailing) {
                    Button {
                        store.toggleFavorite(fighter)
                    } label: {
                        Image(systemName: favorite ? "star.fill" : "star")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(favorite ? Color.black : .white)
                            .frame(width: 28, height: 28)
                            .background(Circle().fill(favorite ? Color.gold : Color(white: 0.2)))
                            .overlay(Circle().strokeBorder(.black, lineWidth: 2))
                    }
                    .accessibilityLabel(favorite ? "Retirer des favoris" : "Ajouter aux favoris")
                }
            Text(fighter.name.split(separator: " ").first.map(String.init) ?? "")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            Text(fighter.lastName.uppercased())
                .font(.system(size: 20, weight: .heavy).width(.condensed))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text([fighter.record, fighter.country].compactMap { $0 }.joined(separator: " · "))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func infoLine(position: Int, start: Date?) -> some View {
        HStack(spacing: 8) {
            if fight.isMainEvent { Pill(text: "MAIN EVENT", color: .gold) }
            if fight.isTitleFight { Pill(text: "TITRE", color: .gold) }
            Text("\(fight.segmentName) · \(position + 1)/\(detail.activeFights.count)")
                .lineLimit(1)
                .foregroundStyle(.secondary)
            Spacer()
            switch fight.state {
            case .live:
                LiveBadge(text: fight.round.map { "R\($0)" } ?? "LIVE")
            case .scheduled:
                if let start {
                    Text("Début ≈ \(start.dingTime)").fontWeight(.semibold).monospacedDigit()
                }
            default:
                EmptyView()
            }
        }
        .font(.caption)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 4)
    }

    // MARK: - Timeline of triggers

    private func timelineRow(_ kind: TriggerKind, position: Int, starts: [String: Date], alarm: FightAlarm?,
                             first: Bool, last: Bool) -> some View {
        let available: Bool = {
            switch kind {
            case .fightsBefore(let n): return position - n >= 0
            case .endOfPrevious: return position > 0
            case .startOfFight: return true
            }
        }()
        let selected = selection.contains(kind)
        let trigger = alarm?.triggers.first { $0.kind == kind }
        let fired = trigger?.firedAt
        let estimate = TriggerLogic.estimatedDate(of: kind, fightId: fight.id, in: detail, starts: starts)
        let referenceFight: Fight? = {
            if case .fightsBefore(let n) = kind, position - n >= 0 { return detail.activeFights[position - n] }
            if kind == .endOfPrevious, position > 0 { return detail.activeFights[position - 1] }
            return nil
        }()
        let caption: String = {
            if !available { return "Pas assez de combats avant" }
            switch kind {
            case .fightsBefore: return "Début de \(referenceFight?.label ?? "—")"
            case .endOfPrevious: return "Fin de \(referenceFight?.label ?? "—")"
            case .startOfFight: return "Les combattants sont dans la cage"
            }
        }()
        let line = Color.white.opacity(0.12)

        return Button {
            withAnimation(.snappy(duration: 0.2)) {
                if selected { selection.remove(kind) } else { selection.insert(kind) }
            }
        } label: {
            HStack(spacing: 12) {
                VStack(spacing: 0) {
                    Rectangle().fill(first ? .clear : line).frame(width: 2).frame(maxHeight: .infinity)
                    ZStack {
                        Circle()
                            .fill(selected ? Color.ding : Color(white: 0.09))
                        Circle()
                            .strokeBorder(selected ? Color.ding : Color.white.opacity(0.25), lineWidth: 2)
                        Image(systemName: selected ? "checkmark" : kind.symbol)
                            .font(.system(size: selected ? 12 : 11, weight: .bold))
                            .foregroundStyle(selected ? Color.white : Color.white.opacity(0.5))
                    }
                    .frame(width: 28, height: 28)
                    Rectangle().fill(last ? .clear : line).frame(width: 2).frame(maxHeight: .infinity)
                }
                .frame(width: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(kind.timelineTitle)
                        .font(.subheadline.weight(selected ? .bold : .semibold))
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.vertical, 12)

                Spacer(minLength: 4)

                VStack(alignment: .trailing, spacing: 2) {
                    if let fired, selected {
                        Text("✓ \(fired.dingTime)")
                            .font(.subheadline.weight(.bold).monospacedDigit())
                            .foregroundStyle(.green)
                        Text("a sonné").font(.caption2).foregroundStyle(.secondary)
                    } else if available, let estimate {
                        Text("≈ \(estimate.dingTime)")
                            .font(.subheadline.weight(.bold).monospacedDigit())
                            .foregroundStyle(selected ? .white : .secondary)
                        if selected, let backup = trigger?.backupDate {
                            Label(backup.dingTime, systemImage: "shield.lefthalf.filled")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .fixedSize(horizontal: false, vertical: true)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!available)
        .opacity(available ? 1 : 0.35)
        .sensoryFeedback(.selection, trigger: selected)
    }
}

#Preview {
    Color.black.sheet(isPresented: .constant(true)) {
        FightAlarmSheet(fight: PreviewData.detail.fights[PreviewData.detail.fights.count - 1], detail: PreviewData.detail)
    }
    .environment(PreviewData.store)
    .preferredColorScheme(.dark)
}
