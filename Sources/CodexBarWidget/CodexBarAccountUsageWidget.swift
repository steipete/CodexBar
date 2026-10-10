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
        .configurationDisplayName(Text(W("CodexBar Account Usage")))
        .description(Text(W("Usage limits and reset countdowns for one saved account.")))
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
                accounts: [.init(id: "preview", provider: .codex, label: W("Personal"), usage: usage)],
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
                accountOverflowCounts: snapshot.accountOverflowCounts,
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
                title: W("Choose an account"),
                message: W(
                    "Enable account widgets in CodexBar → Settings → Menu → Widgets. "
                        + "Then edit this widget to choose an account."))
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
                title: W("Account unavailable"),
                message: W("Open CodexBar to refresh, or edit this widget to choose another account."))
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

struct CodexBarAccountsWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: "CodexBarAccountsWidget",
            intent: ProviderSelectionIntent.self,
            provider: CodexBarTimelineProvider())
        { entry in
            CodexBarAccountsWidgetView(entry: entry)
        }
        .configurationDisplayName(Text(W("%@ %@", "CodexBar", W("Accounts"))))
        .description(Text(W("Account Usage")))
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

struct WidgetAccountsOverview {
    struct Row: Identifiable {
        let account: WidgetSnapshot.AccountEntry
        let quota: WidgetTileLane?

        var id: String {
            self.account.id
        }
    }

    let rows: [Row]
    let overflowCount: Int

    static func make(entry: CodexBarWidgetEntry, family: WidgetFamily) -> Self {
        let snapshot = entry.snapshot
        let provider = entry.provider.instanceID
        guard snapshot.enabledProviders.contains(provider) else { return Self(rows: [], overflowCount: 0) }
        let accounts = snapshot.accounts.filter {
            snapshot.account(id: $0.id, provider: provider) != nil
                && ($0.usage == nil || $0.usage?.provider == provider)
        }
        let candidates: [Row] = accounts.map { account in
            let lanes = account.usage.map { WidgetTileLane.lanes(for: $0) } ?? []
            let quota = WidgetTilePlan.make(
                lanes: lanes.filter { $0.remainingPercent?.isFinite != false }, maxSecondaryLanes: 0).hero
            return Row(account: account, quota: quota)
        }
        let ordered = candidates.sorted {
            let left = $0.quota?.remainingPercent ?? Double.infinity
            let right = $1.quota?.remainingPercent ?? Double.infinity
            return left < right
        }
        let rows = Array(ordered.prefix(family == .systemLarge ? 8 : 4))
        return Self(
            rows: rows,
            overflowCount: ordered.count - rows.count + max(0, snapshot.accountOverflowCounts[provider.rawValue] ?? 0))
    }
}

struct CodexBarAccountsWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: CodexBarWidgetEntry

    var body: some View {
        AccountsOverviewTile(entry: self.entry, family: self.family)
            .containerBackground(.fill.tertiary, for: .widget)
    }
}

struct AccountsOverviewTile: View {
    let entry: CodexBarWidgetEntry
    let family: WidgetFamily

    var body: some View {
        let overview = WidgetAccountsOverview.make(entry: self.entry, family: self.family)
        VStack(alignment: .leading, spacing: self.family == .systemLarge ? 8 : 4) {
            TileHeader(
                provider: self.entry.provider.instanceID,
                updatedAt: overview.rows.compactMap { $0.account.usage?.updatedAt }.min()
                    ?? self.entry.snapshot.generatedAt,
                size: .medium)
            if overview.rows.isEmpty {
                WidgetEmptyState(message: W("Open CodexBar"))
            }
            ForEach(overview.rows) { row in
                self.accountRow(row)
            }
            if overview.overflowCount > 0 {
                Text(W("+%@ more", String(overview.overflowCount)))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func accountRow(_ row: WidgetAccountsOverview.Row) -> some View {
        let remaining = row.quota?.remainingPercent
        let showsUsed = self.entry.snapshot.usageBarsShowUsed
        let displayed = WidgetUsageDisplay.percent(fromRemaining: remaining, showUsed: showsUsed)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                // The writer owns privacy labels; never recover identity from the saved intent or provider entry.
                Text(row.account.label)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                if let quota = row.quota, remaining != nil {
                    Text(W("%@ %@", W(quota.title), W(
                        showsUsed ? "%@ used" : "%@ left",
                        WidgetFormat.percent(displayed))))
                        .font(.caption2.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(QuotaSeverity.isLow(remaining: remaining) ? Color.red : Color.primary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                } else {
                    Text(W("Account unavailable"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if self.family == .systemLarge, remaining != nil {
                QuotaBar(percent: displayed, color: WidgetColors.color(for: self.entry.provider.instanceID), height: 3)
            }
        }
    }
}
