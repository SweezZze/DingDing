import Foundation

/// Small in-app journal (Réglages → Journal) to understand what happened during the night.
@MainActor
enum Log {
    private static let key = "dingding.log"
    private static let maxLines = 300

    static func add(_ message: String) {
        let stamp = Date().formatted(.dateTime.day().month(.twoDigits).hour().minute().second())
        var lines = UserDefaults.standard.stringArray(forKey: key) ?? []
        lines.append("\(stamp)  \(message)")
        if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
        UserDefaults.standard.set(lines, forKey: key)
        print("[DingDing] \(message)")
    }

    static var lines: [String] { (UserDefaults.standard.stringArray(forKey: key) ?? []).reversed() }

    static func clear() { UserDefaults.standard.removeObject(forKey: key) }
}
