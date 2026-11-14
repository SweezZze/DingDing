import SwiftUI

@main
struct DingDingApp: App {
    @State private var store = AppStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .tint(.ding)
                .preferredColorScheme(.dark)
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            switch phase {
            case .active:
                store.appIsActive = true
                WatchService.shared.resumeIfNeeded(store: store)
                WatchService.shared.autoStartIfNeeded(store: store)
                WatchService.shared.refreshActivities(store: store)
                Task {
                    await store.refreshAll()
                    WatchService.shared.autoStartIfNeeded(store: store)
                    WatchService.shared.refreshActivities(store: store)
                    store.scheduleReconcile()
                }
                Task {
                    await AlarmScheduler.requestAuthorization()
                    await AppExpiry.scheduleReminders()
                }
            case .background:
                store.appIsActive = false
                store.save()
                store.scheduleReconcile()
            default:
                break
            }
        }
    }
}

extension Color {
    static let ding = Color(red: 0.93, green: 0.16, blue: 0.22)
    static let gold = Color(red: 0.98, green: 0.76, blue: 0.22)
    static let cardBackground = Color(white: 0.11)
}
