import Foundation
import UserNotifications

/// Free Apple accounts sign apps for 7 days. Reads the expiry date from the embedded
/// provisioning profile and reminds the user before it happens.
enum AppExpiry {
    static let date: Date? = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .isoLatin1),
              let keyRange = text.range(of: "<key>ExpirationDate</key>"),
              let open = text.range(of: "<date>", range: keyRange.upperBound..<text.endIndex),
              let close = text.range(of: "</date>", range: open.upperBound..<text.endIndex) else { return nil }
        return ISO8601DateFormatter().date(from: String(text[open.upperBound..<close.lowerBound]))
    }()

    /// Schedules reminders 24 h and 3 h before expiry (replaces previous ones).
    @MainActor
    static func scheduleReminders() async {
        guard let date else { return }
        let center = UNUserNotificationCenter.current()
        guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
        center.removePendingNotificationRequests(withIdentifiers: ["expiry-24h", "expiry-3h"])
        for (id, offset) in [("expiry-24h", 24.0), ("expiry-3h", 3.0)] {
            let fire = date.addingTimeInterval(-offset * 3600)
            guard fire > Date() else { continue }
            let content = UNMutableNotificationContent()
            content.title = "DingDing expire bientôt"
            content.body = "Allume le Mac et connecte l'iPhone au même Wi-Fi : il réinstalle DingDing tout seul (expire \(date.formatted(date: .abbreviated, time: .shortened)))."
            content.sound = .default
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: fire.timeIntervalSinceNow, repeats: false)
            try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
        }
    }
}
