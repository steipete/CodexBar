import AppIntents
import CodexBarCore
import SwiftUI
import WidgetKit

struct CodexBarAccountUsageWidget: Widget {
    private let kind = "CodexBarAccountUsageWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: self.kind,
            intent: AccountUsageSelectionIntent.self,
            provider: CodexBarAccountTimelineProvider())
        { entry in
            CodexBarAccountUsageWidgetView(entry: entry)
        }
        .configurationDisplayName("CodexBar Account Usage")
        .description("Usage limits and reset countdowns for one saved account.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct AccountUsageSelectionIntent: AppIntent, WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Account Usage"
    static let description = IntentDescription("Select the provider and account to display in the widget.")

    /// Provider-specific by design: keep the same initial provider as the established Usage widget intent.
    @Parameter(title: "Provider", default: .codex)
    var provider: ProviderChoice

    @Parameter(title: "Account")
    var account: WidgetAccountEntity?

    init() {
        self.provider = .codex
    }
}

struct CodexBarAccountWidgetEntry: TimelineEntry {
    let usageEntry: CodexBarWidgetEntry
    let accountID: String?

    var date: Date {
        self.usageEntry.date
    }

    var accountLabel: String? {
        let provider = self.usageEntry.provider.instanceID
        guard let accountID, self.usageEntry.snapshot.enabledProviders.contains(provider) else { return nil }
        // Saved intent labels may predate privacy changes; only the current snapshot may supply identity.
        return self.usageEntry.snapshot.account(id: accountID, provider: provider)?.label
    }
}

struct CodexBarAccountTimelineProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> CodexBarAccountWidgetEntry {
        let now = Date()
        let usage = WidgetSnapshot.ProviderEntry(
            // Provider-specific by design: gallery previews use the established synthetic Codex quota fixture.
            provider: .codex,
            updatedAt: now,
            primary: RateWindow(usedPercent: 35, windowMinutes: 300, resetsAt: nil, resetDescription: "Resets in 4h"),
            secondary: RateWindow(
                usedPercent: 60,
                windowMinutes: 10080,
                resetsAt: nil,
                resetDescription: "Resets in 3d"),
            tertiary: nil,
            creditsRemaining: nil,
            codeReviewRemainingPercent: nil,
            tokenUsage: nil,
            dailyUsage: [])
        return Self.makeEntry(
            snapshot: WidgetSnapshot(
                entries: [],
                // Provider-specific by design: this preview account and its provider belong to the same fixture.
                accounts: [.init(id: "preview", provider: .codex, label: "Personal", usage: usage)],
                enabledProviders: [.codex],
                generatedAt: now),
            provider: .codex,
            accountID: "preview",
            now: now)
    }

    func snapshot(
        for configuration: AccountUsageSelectionIntent,
        in context: Context) async -> CodexBarAccountWidgetEntry
    {
        if context.isPreview, configuration.account == nil {
            return self.placeholder(in: context)
        }
        return Self.makeEntry(
            snapshot: WidgetSnapshotStore.load() ?? WidgetPreviewData.emptySnapshot(),
            provider: configuration.provider.provider,
            accountID: configuration.account?.id,
            now: Date())
    }

    func timeline(
        for configuration: AccountUsageSelectionIntent,
        in context: Context) async -> Timeline<CodexBarAccountWidgetEntry>
    {
        let entry = Self.makeEntry(
            snapshot: WidgetSnapshotStore.load() ?? WidgetPreviewData.emptySnapshot(),
            provider: configuration.provider.provider,
            accountID: configuration.account?.id,
            now: Date())
        let refresh = BurnDownRefreshSchedule.nextRefresh(
            snapshot: entry.usageEntry.snapshot,
            provider: entry.usageEntry.provider,
            now: entry.date)
        return Timeline(entries: [entry], policy: .after(refresh))
    }

    static func makeEntry(
        snapshot: WidgetSnapshot,
        provider: UsageProvider,
        accountID: String?,
        now: Date) -> CodexBarAccountWidgetEntry
    {
        let selected: WidgetSnapshot = if let accountID {
            snapshot.selectingAccount(accountID, for: provider)
        } else {
            // An unconfigured account widget must not inherit the provider's active account.
            WidgetSnapshot(
                entries: [],
                accounts: snapshot.accounts,
                enabledProviders: snapshot.enabledProviders,
                usageBarsShowUsed: snapshot.usageBarsShowUsed,
                generatedAt: snapshot.generatedAt)
        }
        return CodexBarAccountWidgetEntry(
            usageEntry: CodexBarWidgetEntry(date: now, provider: provider, snapshot: selected),
            accountID: accountID)
    }
}

struct CodexBarAccountUsageWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: CodexBarAccountWidgetEntry

    var body: some View {
        if self.entry.accountID == nil {
            self.notice(
                title: "Choose an account",
                message: "Enable account widgets in CodexBar → Settings → Menu → Widgets. "
                    + "Then edit this widget to choose an account.")
        } else if let usage = self.entry.usageEntry.snapshot.entries.first(where: {
            $0.provider == self.entry.usageEntry.provider.instanceID
        }) {
            UsageTile(entry: usage, size: WidgetTileSize(family: self.family)) {
                VStack(alignment: .leading, spacing: 3) {
                    TileHeader(
                        provider: usage.provider,
                        updatedAt: usage.updatedAt,
                        size: WidgetTileSize(family: self.family))
                    if let label = self.entry.accountLabel {
                        Text(label)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .containerBackground(.fill.tertiary, for: .widget)
            .environment(\.widgetUsageShowsUsed, self.entry.usageEntry.snapshot.usageBarsShowUsed)
        } else {
            self.notice(
                title: "Account unavailable",
                message: "Open CodexBar to refresh, or edit this widget to choose another account.")
        }
    }

    private func notice(title: String, message: String) -> some View {
        let provider = self.entry.usageEntry.provider
        let providerName = ProviderDefaults.metadata[provider]?.displayName ?? provider.rawValue.capitalized
        return VStack(alignment: .leading, spacing: 6) {
            Text(self.entry.accountLabel.map { "\(providerName) · \($0)" } ?? providerName)
                .font(.body)
                .fontWeight(.semibold)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(title)
                .font(.caption)
                .fontWeight(.semibold)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .containerBackground(.fill.tertiary, for: .widget)
    }
}
