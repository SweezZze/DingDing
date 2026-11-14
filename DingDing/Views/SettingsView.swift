import AlarmKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppStore.self) private var store
    @State private var testScheduled = false

    var body: some View {
        @Bindable var store = store
        NavigationStack {
            Form {
                Section {
                    Toggle(isOn: $store.settings.antiSpoiler) {
                        Label("Mode anti-spoiler", systemImage: "eye.slash")
                    }
                } footer: {
                    Text("Cache les vainqueurs et les méthodes de victoire. Touche l'œil sur un événement pour les révéler.")
                }

                Section("Organisations") {
                    ForEach(League.allCases) { league in
                        Toggle(league.displayName, isOn: Binding(
                            get: { store.settings.leagues.contains(league) },
                            set: { on in
                                if on { store.settings.leagues.insert(league) } else { store.settings.leagues.remove(league) }
                                Task { await store.refreshAll() }
                            }
                        ))
                    }
                }

                Section {
                    ForEach(TriggerKind.all) { kind in
                        Toggle(kind.title, isOn: Binding(
                            get: { store.settings.favoriteTriggers.contains(kind) },
                            set: { on in
                                if on { store.settings.favoriteTriggers.append(kind) } else { store.settings.favoriteTriggers.removeAll { $0 == kind } }
                            }
                        ))
                    }
                } header: {
                    Text("Alarmes automatiques des favoris")
                } footer: {
                    Text("S'applique aux nouveaux combats de tes combattants favoris.")
                }

                Section {
                    Toggle("Alarme de secours", isOn: $store.settings.backupEnabled)
                    if store.settings.backupEnabled {
                        Stepper("\(store.settings.backupMarginMinutes) min avant l'heure estimée", value: $store.settings.backupMarginMinutes, in: 0...45, step: 5)
                    }
                } header: {
                    Text("Sécurité")
                } footer: {
                    Text("Si iOS coupe DingDing pendant la nuit, l'alarme de secours sonne à l'heure estimée (un peu en avance). Tant que la veille tourne, elle est repoussée automatiquement et ne sonne pas pour rien.")
                }

                Section("Alarmes iOS") {
                    HStack {
                        Text("Autorisation")
                        Spacer()
                        Text(authText).foregroundStyle(AlarmScheduler.isAuthorized ? .green : .orange)
                    }
                    if !AlarmScheduler.isAuthorized {
                        Button("Ouvrir les réglages iOS") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        }
                    }
                    Button {
                        Task {
                            let ok = await AlarmScheduler.schedule(at: Date().addingTimeInterval(10), title: "Test DingDing 🔔", fightLabel: "Test", isBackup: false) != nil
                            testScheduled = ok
                        }
                    } label: {
                        Label("Tester une alarme (dans 10 s)", systemImage: "alarm")
                    }
                    if testScheduled {
                        Text("Verrouille l'iPhone : l'alarme va sonner.").font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section {
                    if let sim = store.simulation {
                        Text(sim.template.summary.name).font(.subheadline)
                        Button("Arrêter la simulation", role: .destructive) { store.stopSimulation() }
                    } else {
                        Button {
                            Task { await store.startSimulation() }
                        } label: {
                            Label("Simuler un événement en accéléré", systemImage: "play.circle")
                        }
                        .disabled(store.isLoading)
                    }
                } header: {
                    Text("Tester sans attendre un vrai événement")
                } footer: {
                    Text("Rejoue la dernière soirée UFC : 45 s avant le début, puis 30 s par combat. Règle une alarme sur un combat de la simulation (onglet Combats) puis verrouille l'iPhone : la veille démarre toute seule.")
                }

                Section {
                    NavigationLink("Journal") { LogView() }
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")
                    LabeledContent("Données", value: "ESPN (non officiel)")
                }
            }
            .navigationTitle("Réglages")
        }
    }

    private var authText: String {
        switch AlarmScheduler.authorizationState {
        case .authorized: "Autorisées"
        case .denied: "Refusées"
        case .notDetermined: "Pas encore demandée"
        @unknown default: "?"
        }
    }
}

struct LogView: View {
    @State private var lines: [String] = []

    var body: some View {
        List(lines, id: \.self) { line in
            Text(line).font(.caption.monospaced())
        }
        .navigationTitle("Journal")
        .toolbar {
            Button("Vider", role: .destructive) {
                Log.clear()
                lines = []
            }
        }
        .onAppear { lines = Log.lines }
        .refreshable { lines = Log.lines }
    }
}

#Preview {
    SettingsView()
        .environment(PreviewData.store)
        .preferredColorScheme(.dark)
}
