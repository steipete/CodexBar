import CodexBarCore
import SwiftUI

/// Shown in place of the 3-card row when a card is tapped: one provider's session-usage trend
/// as a compact sparkline, same 26pt row height as `CodexBarTouchBarView`'s cards. Tap again (or
/// wait out the auto-revert in the parent view) to return to the overview.
@MainActor
struct TouchBarUsageGraphView: View {
    let provider: UsageProvider
    @Bindable var store: UsageStore

    var body: some View {
        let descriptor = ProviderDescriptorRegistry.descriptor(for: self.provider)
        let accent = Color(
            red: descriptor.branding.color.red,
            green: descriptor.branding.color.green,
            blue: descriptor.branding.color.blue)
        let snapshot = self.store.snapshot(for: self.provider)
        let remaining = 100 - (snapshot?.primary?.usedPercent ?? 100)
        let entries = self.store.planUtilizationHistory(for: self.provider)
            .first { $0.name == .session }?.entries ?? []

        HStack(spacing: 8) {
            Circle()
                .fill(accent)
                .frame(width: 20, height: 20)
                .overlay(
                    Group {
                        if let logo = ProviderBrandIcon.image(for: self.provider) {
                            Image(nsImage: logo)
                                .resizable()
                                .renderingMode(.template)
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 11, height: 11)
                        } else {
                            Text(String(descriptor.metadata.displayName.prefix(1)))
                                .font(.system(size: 10, weight: .bold))
                        }
                    }
                    .foregroundStyle(.white))

            VStack(alignment: .leading, spacing: 1) {
                Text(descriptor.metadata.displayName)
                    .font(.system(size: 9, weight: .bold))
                if let resetsAt = snapshot?.primary?.resetsAt {
                    Text("5h · \(UsageFormatter.resetCountdownDescription(from: resetsAt))")
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                } else {
                    Text("5h")
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                }
            }

            if entries.count > 1 {
                TouchBarSparkline(values: entries.map(\.usedPercent))
                    .stroke(accent, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                    .frame(width: 90, height: 16)
            } else {
                Text("Not enough history yet")
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
                    .frame(width: 90, alignment: .leading)
            }

            Text(UsageFormatter.percentString(remaining))
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(remaining < 10 ? .red : .primary)
                .frame(width: 32, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .frame(height: 26)
    }
}

/// Minimal line-only sparkline — the Touch Bar has no room for axes or labels.
private struct TouchBarSparkline: Shape {
    let values: [Double]

    func path(in rect: CGRect) -> Path {
        guard values.count > 1 else { return Path() }
        let maxValue = max(self.values.max() ?? 1, 1)
        let minValue = min(self.values.min() ?? 0, 0)
        let range = max(maxValue - minValue, 1)

        var path = Path()
        for (index, value) in self.values.enumerated() {
            let x = rect.width * CGFloat(index) / CGFloat(self.values.count - 1)
            let normalized = (value - minValue) / range
            let y = rect.height * (1 - CGFloat(normalized))
            if index == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        return path
    }
}
