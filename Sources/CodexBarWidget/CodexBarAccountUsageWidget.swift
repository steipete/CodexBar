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

struct CodexBarAccountsWidget: Widget {
    private let kind = "CodexBarAccountsWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: self.kind,
            intent: ProviderSelectionIntent.self,
            provider: CodexBarTimelineProvider())
        { entry in
            CodexBarAccountsWidgetView(entry: entry)
        }
        .configurationDisplayName("CodexBar Accounts")
        .description("Usage for multiple accounts of one provider.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

struct CodexBarAccountsWidgetView: View {
    @Environment(\.widgetFamily) private var widgetFamily
    @Environment(\.widgetFamilyOverride) private var familyOverride

    private var family: WidgetFamily {
        self.familyOverride ?? self.widgetFamily
    }

    let entry: CodexBarWidgetEntry

    var accounts: [WidgetSnapshot.AccountEntry] {
        Self.accounts(in: self.entry.snapshot, for: self.entry.provider)
    }

    static func accounts(in snapshot: WidgetSnapshot, for provider: UsageProvider) -> [WidgetSnapshot.AccountEntry] {
        let accounts = snapshot.accounts.filter {
            snapshot.account(id: $0.id, provider: provider.instanceID) != nil
                && ($0.usage == nil || $0.usage?.provider == provider.instanceID)
        }
        return accounts.filter(\.isActive) + accounts.filter { !$0.isActive }
    }

    var body: some View {
        let accounts = self.accounts
        let first = accounts.first
        let pager = WidgetAccountPager.make(
            accounts: accounts,
            selectedID: self.entry.selectedAccountID,
            excludingAccountID: first?.id)
        Group {
            if let first, let usage = first.usage, self.family == .systemLarge || accounts.count == 1 {
                UsageTile(
                    entry: usage,
                    size: WidgetTileSize(family: self.family),
                    accountHistory: WidgetAccountHistory.resolve(
                        in: self.entry.snapshot, for: self.entry.provider, accountID: first.id),
                    companionAccount: pager?.selected,
                    sectionSpacing: 7)
                {
                    if self.family == .systemMedium {
                        TileHeader(
                            provider: usage.provider,
                            updatedAt: usage.updatedAt,
                            size: .medium,
                            accountLabel: first.label,
                            isActiveAccount: first.isActive)
                    } else {
                        VStack(alignment: .leading, spacing: 3) {
                            self.header(pager: pager)
                            AccountUsageLabel(account: first, showsFreshness: true)
                        }
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    self.header(pager: pager)
                    if let first {
                        self.compactAccount(first)
                        if let selected = pager?.selected {
                            self.compactAccount(selected)
                        }
                    } else {
                        WidgetEmptyState(message: "Enable account widgets in CodexBar Settings → Menu → Widgets.")
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(.fill.tertiary, for: .widget)
        .environment(\.widgetUsageShowsUsed, self.entry.snapshot.usageBarsShowUsed)
    }

    private func header(pager: WidgetAccountPager?) -> some View {
        HStack(spacing: 6) {
            ProviderMark(provider: self.entry.provider, isSelected: true, size: 20)
            Text(ProviderDefaults.metadata[self.entry.provider]?.displayName
                ?? self.entry.provider.rawValue.capitalized)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Text("Accounts")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if let pager, pager.isPageable {
                WidgetAccountPagerControls(provider: self.entry.provider, pager: pager)
            }
        }
    }

    private func compactAccount(_ account: WidgetSnapshot.AccountEntry) -> some View {
        let metrics = Self.metrics(for: account.usage)
        return VStack(alignment: .leading, spacing: 3) {
            AccountUsageLabel(account: account, showsFreshness: true)
            if metrics.isEmpty {
                Text("Usage unavailable")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(metrics) { metric in
                        QuotaLaneView(
                            title: WidgetLaneCopy.caption(
                                title: metric.title, showUsed: self.entry.snapshot.usageBarsShowUsed),
                            percent: WidgetUsageDisplay.percent(
                                fromRemaining: metric.percentLeft, showUsed: self.entry.snapshot.usageBarsShowUsed),
                            remainingPercent: metric.percentLeft,
                            color: WidgetColors.color(for: self.entry.provider.instanceID))
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                }
            }
        }
    }

    static func metrics(for usage: WidgetSnapshot.ProviderEntry?) -> [WidgetUsageRow] {
        guard let usage else { return [] }
        return Array(WidgetUsageRow.rows(for: usage).filter { $0.percentLeft != nil }.prefix(2))
    }
}

struct AccountUsageLabel: View {
    let account: WidgetSnapshot.AccountEntry
    var showsFreshness = false

    var body: some View {
        HStack(spacing: 5) {
            Text(self.account.label)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            if self.account.isActive {
                Text("Active")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            Spacer(minLength: 0)
            if self.showsFreshness, let usage = self.account.usage {
                FreshnessLabel(updatedAt: usage.updatedAt)
            }
        }
    }
}

struct AccountUsageCompanion: View {
    @Environment(\.widgetUsageShowsUsed) private var showsUsed
    let account: WidgetSnapshot.AccountEntry
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            AccountUsageLabel(account: self.account)
            if let usage = self.account.usage {
                FreshnessLabel(updatedAt: usage.updatedAt)
                let lanes = WidgetTileLane.lanes(for: usage)
                ForEach(lanes.prefix(2)) { lane in
                    QuotaLaneView(
                        title: WidgetLaneCopy.caption(title: lane.title, showUsed: self.showsUsed),
                        percent: WidgetUsageDisplay.percent(
                            fromRemaining: lane.remainingPercent, showUsed: self.showsUsed),
                        remainingPercent: lane.remainingPercent,
                        color: self.color)
                }
                if lanes.isEmpty {
                    Text("Usage unavailable").font(.caption2).foregroundStyle(.secondary)
                }
            } else {
                Text("Usage unavailable").font(.caption2).foregroundStyle(.secondary)
            }
        }
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
    var history: WidgetAccountHistory?

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
            accountID: accountID,
            history: accountID.flatMap {
                WidgetAccountHistory.resolve(in: snapshot, for: provider, accountID: $0)
            })
    }
}

struct CodexBarAccountUsageWidgetView: View {
    @Environment(\.widgetFamily) private var widgetFamily
    @Environment(\.widgetFamilyOverride) private var familyOverride

    private var family: WidgetFamily {
        self.familyOverride ?? self.widgetFamily
    }

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
            UsageTile(
                entry: usage,
                size: WidgetTileSize(family: self.family),
                accountHistory: self.entry.history,
                sectionSpacing: 7)
            {
                TileHeader(
                    provider: usage.provider,
                    updatedAt: usage.updatedAt,
                    size: WidgetTileSize(family: self.family),
                    accountLabel: self.entry.accountLabel)
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

private struct WidgetAccountPagerControls: View {
    @Environment(\.widgetAccountSelectionOverride) private var selectionOverride
    let provider: UsageProvider
    let pager: WidgetAccountPager

    var body: some View {
        HStack(spacing: 3) {
            self.button(account: self.pager.previous, symbol: "chevron.left")
            Text(self.pager.positionText)
                .font(.caption2.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .fixedSize()
            self.button(account: self.pager.next, symbol: "chevron.right")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Inactive account \(self.pager.positionText)"))
    }

    @ViewBuilder
    private func button(account: WidgetSnapshot.AccountEntry, symbol: String) -> some View {
        if let choice = ProviderChoice(provider: self.provider) {
            Group {
                if let selectionOverride {
                    Button { selectionOverride(self.provider, account.id) } label: { self.glyph(symbol) }
                } else {
                    Button(intent: BrowseWidgetAccountIntent(provider: choice, accountID: account.id)) {
                        self.glyph(symbol)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Show inactive account \(account.label)"))
        }
    }

    private func glyph(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 21, height: 21)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.07)))
    }
}
