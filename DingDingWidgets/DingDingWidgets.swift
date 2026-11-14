import ActivityKit
import AlarmKit
import SwiftUI
import WidgetKit

private let ding = Color(red: 0.93, green: 0.16, blue: 0.22)
private let gold = Color(red: 0.98, green: 0.76, blue: 0.22)

@main
struct DingDingWidgetsBundle: WidgetBundle {
    var body: some Widget {
        CardLiveActivity()
        AlarmLiveActivity()
    }
}

// MARK: - Progress of the night (lock screen + Dynamic Island)

struct CardLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CardActivityAttributes.self) { context in
            LockScreenCardView(attributes: context.attributes, state: context.state)
                .activityBackgroundTint(Color.black.opacity(0.85))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 4) {
                        Image(systemName: "bell.fill").foregroundStyle(ding)
                        Text(context.attributes.eventName).font(.caption.weight(.bold)).lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("\(context.state.done)/\(context.state.total)")
                        .font(.caption.monospacedDigit().weight(.bold))
                        .foregroundStyle(.secondary)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 2) {
                        Text(context.state.currentFight ?? context.state.status)
                            .font(.headline)
                            .lineLimit(1)
                        if context.state.currentFight != nil {
                            Text(context.state.status).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    AlarmLine(state: context.state)
                }
            } compactLeading: {
                Image(systemName: "bell.fill").foregroundStyle(ding)
            } compactTrailing: {
                if let n = context.state.fightsBeforeAlarm {
                    Text(n == 0 ? "!" : "\(n)")
                        .font(.caption.weight(.heavy).monospacedDigit())
                        .foregroundStyle(n == 0 ? ding : .white)
                } else {
                    Text("\(context.state.done)/\(context.state.total)").font(.caption2.monospacedDigit())
                }
            } minimal: {
                Image(systemName: "bell.fill").foregroundStyle(ding)
            }
            .keylineTint(ding)
        }
    }
}

struct LockScreenCardView: View {
    var attributes: CardActivityAttributes
    var state: CardActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(attributes.league)
                    .font(.caption2.weight(.heavy))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(ding, in: RoundedRectangle(cornerRadius: 3))
                Text(attributes.eventName).font(.subheadline.weight(.bold)).lineLimit(1)
                Spacer()
                if state.stale {
                    Image(systemName: "wifi.exclamationmark").foregroundStyle(.orange)
                }
                Text("\(state.done)/\(state.total)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: Double(state.done), total: Double(max(state.total, 1)))
                .tint(ding)
            HStack {
                if state.currentFight != nil {
                    Circle().fill(ding).frame(width: 7, height: 7)
                }
                Text(state.currentFight ?? state.status).font(.headline).lineLimit(1)
                if state.currentFight != nil {
                    Text(state.status).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
            }
            AlarmLine(state: state)
        }
        .padding(14)
        .foregroundStyle(.white)
    }
}

struct AlarmLine: View {
    var state: CardActivityAttributes.ContentState

    var body: some View {
        if let next = state.nextAlarm {
            HStack(spacing: 6) {
                Image(systemName: "alarm.fill").foregroundStyle(gold)
                Text(next).font(.caption.weight(.semibold)).lineLimit(1)
                Spacer()
                if let n = state.fightsBeforeAlarm {
                    Text(n == 0 ? "au prochain combat" : "dans \(n) combat\(n > 1 ? "s" : "")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let date = state.estimatedAlarm {
                    Text("≈ \(date, style: .time)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        } else {
            Label("Toutes les alarmes ont sonné", systemImage: "checkmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Presentation of DingDing's AlarmKit alarms

struct AlarmLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AlarmAttributes<DingAlarmMetadata>.self) { context in
            HStack(spacing: 12) {
                Image(systemName: "bell.and.waves.left.and.right.fill")
                    .font(.title)
                    .foregroundStyle(ding)
                VStack(alignment: .leading) {
                    Text(context.attributes.metadata?.reason ?? "DingDing").font(.headline)
                    Text(context.attributes.metadata?.fightLabel ?? "").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding()
            .foregroundStyle(.white)
            .activityBackgroundTint(.black)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.center) {
                    Text(context.attributes.metadata?.reason ?? "DingDing").font(.headline)
                }
            } compactLeading: {
                Image(systemName: "bell.fill").foregroundStyle(ding)
            } compactTrailing: {
                Text(context.attributes.metadata?.fightLabel ?? "").font(.caption2).lineLimit(1)
            } minimal: {
                Image(systemName: "bell.fill").foregroundStyle(ding)
            }
        }
    }
}

#Preview("Écran verrouillé", as: .content, using: CardActivityAttributes(eventId: "preview", eventName: "UFC 334", league: "UFC")) {
    CardLiveActivity()
} contentStates: {
    CardActivityAttributes.ContentState(currentFight: "Holland vs Medić", status: "Round 2", done: 9, total: 13,
                                        nextAlarm: "Combat d'avant · Hokit vs Gane", fightsBeforeAlarm: 2,
                                        estimatedAlarm: Date().addingTimeInterval(2400), stale: false)
}
