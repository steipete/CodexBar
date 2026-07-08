import ActivityKit
import SwiftUI
import WidgetKit

/// Live Activity presentation for provider usage — Lock Screen banner + Dynamic Island.
struct UsageLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: UsageActivityAttributes.self) { context in
            LiveActivityLockScreenView(state: context.state)
                .padding(16)
                .activityBackgroundTint(Color.black.opacity(0.35))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.state.providerDisplayName, systemImage: "cpu")
                        .font(.caption.weight(.semibold))
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(UsageFormat.percent(context.state.remainingPercent))
                        .font(.title3.weight(.bold).monospacedDigit())
                        .foregroundStyle(UsageTone.color(remainingPercent: context.state.remainingPercent))
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 4) {
                        Gauge(value: context.state.remainingPercent / 100) {
                            Text(context.state.windowLabel)
                        }
                        .gaugeStyle(.accessoryLinearCapacity)
                        .tint(UsageTone.color(remainingPercent: context.state.remainingPercent))
                        if let resetsAt = context.state.resetsAt {
                            Text("Resets \(resetsAt, style: .relative)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } compactLeading: {
                Image(systemName: "cpu")
            } compactTrailing: {
                Text(UsageFormat.percent(context.state.remainingPercent))
                    .monospacedDigit()
                    .foregroundStyle(UsageTone.color(remainingPercent: context.state.remainingPercent))
            } minimal: {
                Text("\(Int(context.state.remainingPercent.rounded()))")
                    .monospacedDigit()
            }
        }
    }
}

struct LiveActivityLockScreenView: View {
    let state: UsageActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(self.state.providerDisplayName)
                    .font(.headline)
                Text(self.state.windowLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let resetsAt = self.state.resetsAt {
                    Text("Resets \(resetsAt, style: .relative)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            UsageRing(remainingPercent: self.state.remainingPercent, lineWidth: 6)
                .frame(width: 52, height: 52)
        }
    }
}
