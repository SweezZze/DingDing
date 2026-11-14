import SwiftUI

struct FighterAvatar: View {
    var fighter: Fighter?
    var size: CGFloat = 44
    var dimmed = false

    var body: some View {
        ZStack {
            Circle().fill(Color(white: 0.18))
            if let url = fighter?.headshotURL {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill().offset(y: size * 0.08)
                    } else {
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .saturation(dimmed ? 0 : 1)
        .opacity(dimmed ? 0.55 : 1)
    }

    private var placeholder: some View {
        Image(systemName: "person.fill")
            .font(.system(size: size * 0.45))
            .foregroundStyle(.secondary)
    }
}

struct LeagueBadge: View {
    var league: League
    var body: some View {
        Text(league.displayName)
            .font(.caption2.weight(.heavy))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(league == .ufc ? Color.ding : Color.blue, in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(.white)
    }
}

struct LiveBadge: View {
    var text = "LIVE"
    @State private var pulse = false
    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(.white).frame(width: 6, height: 6).opacity(pulse ? 0.3 : 1)
            Text(text).font(.caption2.weight(.heavy))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color.ding, in: Capsule())
        .foregroundStyle(.white)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.8).repeatForever()) { pulse = true }
        }
    }
}

struct Pill: View {
    var text: String
    var color: Color = .secondary
    var body: some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize()
    }
}

extension Date {
    /// "sam. 15 nov. · 03:00"
    var dingDayTime: String {
        formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
    }

    var dingTime: String {
        formatted(date: .omitted, time: .shortened)
    }

    /// "dans 3 h 20" / "il y a 5 min"
    var dingRelative: String {
        formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
    }
}

// MARK: - Cards & shared pieces

extension View {
    /// Dark rounded card, Apple Sports style.
    func dingCard(cornerRadius: CGFloat = 20, tint: Color? = nil) -> some View {
        background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color(white: 0.09))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(LinearGradient(colors: [(tint ?? .clear).opacity(0.18), .clear], startPoint: .topLeading, endPoint: .bottomTrailing))
                )
        )
        .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder((tint ?? .white).opacity(tint == nil ? 0.06 : 0.25)))
    }
}

/// "MAIN CARD                03:00"
struct SectionHeader: View {
    var title: String
    var trailing: String?

    var body: some View {
        HStack {
            Text(title.uppercased())
                .font(.caption.weight(.heavy))
                .tracking(0.8)
            Spacer()
            if let trailing {
                Text(trailing).font(.caption.weight(.semibold).monospacedDigit())
            }
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.top, 14)
    }
}

/// The two fighters' faces, slightly overlapping.
struct PairAvatars: View {
    var fighters: [Fighter]
    var size: CGFloat = 34

    var body: some View {
        HStack(spacing: -size * 0.28) {
            FighterAvatar(fighter: fighters.first, size: size)
                .overlay(Circle().strokeBorder(Color(white: 0.09), lineWidth: 2))
            FighterAvatar(fighter: fighters.dropFirst().first, size: size)
                .overlay(Circle().strokeBorder(Color(white: 0.09), lineWidth: 2))
        }
    }
}

extension TriggerKind {
    /// Title in the alarm sheet timeline (short enough for one line).
    var timelineTitle: String {
        switch self {
        case .fightsBefore(1): "Combat d'avant"
        case .fightsBefore(let n): "\(n) combats avant"
        case .endOfPrevious: "Walkouts"
        case .startOfFight: "Début de mon combat"
        }
    }

    var symbol: String {
        switch self {
        case .fightsBefore(let n): "\(n).circle.fill"
        case .endOfPrevious: "figure.walk"
        case .startOfFight: "bell.and.waves.left.and.right.fill"
        }
    }
}

/// "dans 10 h 32", "dans 12 min", "imminent"
func shortCountdown(to date: Date) -> String {
    let minutes = Int(date.timeIntervalSinceNow / 60)
    if minutes <= 0 { return "imminent" }
    if minutes < 60 { return "dans \(minutes) min" }
    let hours = minutes / 60
    if hours < 24 { return "dans \(hours) h \(String(format: "%02d", minutes % 60))" }
    return "dans \(hours / 24) j"
}
