import SwiftUI

struct ContentView: View {
    @Environment(AppStore.self) private var store
    @State private var tab = ContentView.initialTab

    private static var initialTab: Int {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-tab"), i + 1 < args.count { return Int(args[i + 1]) ?? 0 }
        #endif
        return 0
    }

    var body: some View {
        TabView(selection: $tab) {
            Tab("Combats", systemImage: "figure.boxing", value: 0) {
                EventsView()
            }
            Tab("Alarmes", systemImage: "alarm.waves.left.and.right", value: 1) {
                AlarmsView()
            }
            .badge(store.alarms.values.reduce(0) { $0 + $1.pendingTriggers.count })
            Tab("Favoris", systemImage: "star", value: 2) {
                FavoritesView()
            }
            Tab("Réglages", systemImage: "gearshape", value: 3) {
                SettingsView()
            }
        }
    }
}

#Preview {
    ContentView()
        .environment(PreviewData.store)
        .tint(.ding)
        .preferredColorScheme(.dark)
}
