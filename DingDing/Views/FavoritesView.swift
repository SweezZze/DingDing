import SwiftUI

struct FavoritesView: View {
    @Environment(AppStore.self) private var store

    private var favorites: [FavoriteFighter] {
        store.favorites.values.sorted { $0.name < $1.name }
    }

    /// Next scheduled fight of a favourite fighter.
    private func nextFight(of fighterId: String) -> (EventSummary, Fight)? {
        let candidates = store.details.values.flatMap { detail in
            detail.fights.filter { $0.state == .scheduled && $0.fighters.contains { $0.id == fighterId } }.map { (detail.summary, $0) }
        }
        return candidates.min { $0.0.date < $1.0.date }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(favorites) { favorite in
                        HStack(spacing: 12) {
                            FighterAvatar(fighter: Fighter(id: favorite.id, name: favorite.name, shortName: favorite.name, headshotURL: favorite.headshotURL), size: 44)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(favorite.name).font(.headline)
                                if let (event, fight) = nextFight(of: favorite.id) {
                                    Text("\(fight.label) · \(event.shortName)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(event.date.dingDayTime)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                } else {
                                    Text("Pas de combat annoncé").font(.caption).foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                    .onDelete { offsets in
                        for index in offsets { store.removeFavorite(favorites[index].id) }
                    }
                } footer: {
                    if !favorites.isEmpty {
                        Text("Dès qu'un favori est programmé, une alarme « \(store.settings.favoriteTriggers.sorted().map(\.title).joined(separator: ", ")) » est réglée automatiquement (modifiable dans Réglages).")
                    }
                }
            }
            .overlay {
                if favorites.isEmpty {
                    ContentUnavailableView("Aucun favori", systemImage: "star",
                                           description: Text("Touche un combat puis l'étoile sous un combattant : DingDing réglera une alarme à chacun de ses combats."))
                }
            }
            .navigationTitle("Favoris")
        }
    }
}

#Preview {
    FavoritesView()
        .environment(PreviewData.store)
        .preferredColorScheme(.dark)
}
