import Charts
import SwiftUI

struct ProviderDetailView: View {
    let entry: WidgetSnapshot.ProviderEntry
    @Environment(SnapshotSyncCoordinator.self) private var coordinator
    @State private var liveActivityOn = false

    private var liveActivitiesEnabled: Bool {
        UserDefaults(suiteName: MobileAppGroup.identifier)?
            .object(forKey: SettingsKeys.liveActivitiesEnabled) as? Bool ?? false
    }

    /// Freshest entry from the coordinator (so the screen updates live), falling back to the passed-in one.
    private var current: WidgetSnapshot.ProviderEntry {
        self.coordinator.snapshot?.entries.first { $0.provider == self.entry.provider } ?? self.entry
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                self.header
                self.windowsSection
                self.costSection
                self.dailyChartSection
                if self.liveActivitiesEnabled { self.liveActivitySection }
            }
            .padding(16)
        }
        .background(BackdropView())
        .navigationTitle(self.current.provider.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { self.liveActivityOn = LiveActivityController.shared.isRunning(for: self.entry.provider) }
    }

    private var header: some View {
        HStack(spacing: 14) {
            ProviderIconView(provider: self.current.provider, size: 56)
            VStack(alignment: .leading, spacing: 4) {
                Text(self.current.provider.displayName)
                    .font(.title2.weight(.semibold))
                Text("Updated \(UsageFormat.relative(self.current.updatedAt))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .glassCard()
    }

    @ViewBuilder
    private var windowsSection: some View {
        let rows = self.current.displayRows
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                SectionLabel("Usage windows")
                ForEach(rows) { row in UsageRowView(row: row) }
                if let credits = self.current.creditsRemaining {
                    Divider()
                    LabeledContent("Credits remaining") {
                        Text(String(format: "%.0f", credits)).monospacedDigit()
                    }
                }
                if let review = self.current.codeReviewRemainingPercent {
                    LabeledContent("Code review") {
                        Text(UsageFormat.percent(review)).monospacedDigit()
                    }
                }
            }
            .padding(16)
            .glassCard()
        }
    }

    @ViewBuilder
    private var costSection: some View {
        if let token = self.current.tokenUsage {
            VStack(alignment: .leading, spacing: 12) {
                SectionLabel("Cost & tokens")
                HStack {
                    self.statTile(
                        title: token.sessionLabel,
                        value: UsageFormat.currency(token.sessionCostUSD, code: token.currencyCode)
                            ?? UsageFormat.tokens(token.sessionTokens) ?? "—")
                    self.statTile(
                        title: token.last30DaysLabel,
                        value: UsageFormat.currency(token.last30DaysCostUSD, code: token.currencyCode)
                            ?? UsageFormat.tokens(token.last30DaysTokens) ?? "—")
                }
            }
            .padding(16)
            .glassCard()
        }
    }

    @ViewBuilder
    private var dailyChartSection: some View {
        let points = self.current.dailyUsage.filter { ($0.costUSD ?? 0) > 0 || ($0.totalTokens ?? 0) > 0 }
        if points.count > 1 {
            VStack(alignment: .leading, spacing: 12) {
                SectionLabel("Daily activity")
                Chart(points) { point in
                    BarMark(
                        x: .value("Day", point.dayKey),
                        y: .value("Cost", point.costUSD ?? Double(point.totalTokens ?? 0)))
                    .foregroundStyle(Color(hex: self.current.provider.accentHex).gradient)
                    .cornerRadius(3)
                }
                .chartXAxis(.hidden)
                .frame(height: 120)
            }
            .padding(16)
            .glassCard()
        }
    }

    private var liveActivitySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("Live Activity")
            Text("Pin \(self.current.provider.displayName) usage to your Lock Screen and Dynamic Island.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Show Live Activity", isOn: self.$liveActivityOn)
                .onChange(of: self.liveActivityOn) { _, isOn in
                    let entry = self.current
                    Task {
                        if isOn {
                            LiveActivityController.shared.start(for: entry)
                        } else {
                            await LiveActivityController.shared.stop(for: entry.provider)
                        }
                    }
                }
        }
        .padding(16)
        .glassCard()
    }

    private func statTile(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 12))
    }
}

struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(self.text.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
