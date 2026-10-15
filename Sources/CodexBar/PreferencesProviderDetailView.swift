import CodexBarCore
import SwiftUI

enum ProviderMetricInlinePresentation: Equatable {
    case progress
    case status(String)
}

@MainActor
struct ProviderDetailView<SupplementaryContent: View>: View {
    private struct ModelLimitsIdentity: Hashable {
        let id: String
        let scope: ProviderModelRateLimitScope?
    }

    let provider: UsageProvider
    @Bindable var store: UsageStore
    @Binding var isEnabled: Bool
    let subtitle: String
    let model: UsageMenuCardView.Model
    let accountUsageOverview: ProviderAccountUsageOverview?
    let usageItems: [ProviderUsageItemDescriptor]
    let openAIWebDiagnostic: String?
    let settingsPickers: [ProviderSettingsPickerDescriptor]
    let settingsToggles: [ProviderSettingsToggleDescriptor]
    let settingsFields: [ProviderSettingsFieldDescriptor]
    let settingsModelLimits: [ProviderSettingsModelLimitsDescriptor]
    let settingsDirectoryLists: [ProviderSettingsDirectoryListDescriptor]
    let settingsActions: [ProviderSettingsActionsDescriptor]
    let settingsTokenAccounts: ProviderSettingsTokenAccountsDescriptor?
    let settingsOrganizations: ProviderSettingsOrganizationsDescriptor?
    let errorDisplay: ProviderErrorDisplay?
    @Binding var isErrorExpanded: Bool
    let onCopyError: (String) -> Void
    let onRefresh: () -> Void
    let supplementarySettingsContent: SupplementaryContent
    let showsSupplementarySettingsContent: Bool

    init(
        provider: UsageProvider,
        store: UsageStore,
        isEnabled: Binding<Bool>,
        subtitle: String,
        model: UsageMenuCardView.Model,
        accountUsageOverview: ProviderAccountUsageOverview? = nil,
        usageItems: [ProviderUsageItemDescriptor] = [],
        openAIWebDiagnostic: String?,
        settingsPickers: [ProviderSettingsPickerDescriptor],
        settingsToggles: [ProviderSettingsToggleDescriptor],
        settingsFields: [ProviderSettingsFieldDescriptor],
        settingsDirectoryLists: [ProviderSettingsDirectoryListDescriptor] = [],
        settingsModelLimits: [ProviderSettingsModelLimitsDescriptor] = [],
        settingsActions: [ProviderSettingsActionsDescriptor] = [],
        settingsTokenAccounts: ProviderSettingsTokenAccountsDescriptor?,
        settingsOrganizations: ProviderSettingsOrganizationsDescriptor? = nil,
        errorDisplay: ProviderErrorDisplay?,
        isErrorExpanded: Binding<Bool>,
        onCopyError: @escaping (String) -> Void,
        onRefresh: @escaping () -> Void,
        showsSupplementarySettingsContent: Bool = false,
        @ViewBuilder supplementarySettingsContent: () -> SupplementaryContent)
    {
        self.provider = provider
        self.store = store
        self._isEnabled = isEnabled
        self.subtitle = subtitle
        self.model = model
        self.accountUsageOverview = accountUsageOverview
        self.usageItems = usageItems
        self.openAIWebDiagnostic = openAIWebDiagnostic
        self.settingsPickers = settingsPickers
        self.settingsToggles = settingsToggles
        self.settingsFields = settingsFields
        self.settingsDirectoryLists = settingsDirectoryLists
        self.settingsModelLimits = settingsModelLimits
        self.settingsActions = settingsActions
        self.settingsTokenAccounts = settingsTokenAccounts
        self.settingsOrganizations = settingsOrganizations
        self.errorDisplay = errorDisplay
        self._isErrorExpanded = isErrorExpanded
        self.onCopyError = onCopyError
        self.onRefresh = onRefresh
        self.showsSupplementarySettingsContent = showsSupplementarySettingsContent
        self.supplementarySettingsContent = supplementarySettingsContent()
    }

    static func metricTitle(provider: UsageProvider, metric: UsageMenuCardView.Model.Metric) -> String {
        L(UsageMenuCardView.popupMetricTitle(provider: provider, metric: metric))
    }

    static func versionText(provider: UsageProvider, store: UsageStore) -> String? {
        let context = ProviderPresentationContext(
            provider: provider,
            settings: store.settings,
            store: store,
            metadata: store.metadata(for: provider))
        let presentation = ProviderCatalog.implementation(for: provider)?.presentation(context: context)
            ?? ProviderPresentation(detailLine: ProviderPresentation.standardDetailLine)
        guard presentation.showsVersionInSettings else { return nil }
        return store.version(for: provider) ?? L("not detected")
    }

    static func metricInlinePresentation(
        _ metric: UsageMenuCardView.Model.Metric) -> ProviderMetricInlinePresentation
    {
        if let statusText = metric.statusText {
            return .status(statusText)
        }
        return .progress
    }

    static func planRow(provider: UsageProvider, planText: String?) -> (label: String, value: String)? {
        guard let rawPlan = planText?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawPlan.isEmpty
        else {
            return nil
        }
        let presentation = ProviderDescriptorRegistry.descriptor(for: provider).presentation.planRow
        if presentation.stripsBalancePrefix,
           let value = MenuBarDisplayText.prefixedValue(from: rawPlan, prefix: "Balance:")
        {
            return (label: L(presentation.balancePrefixedLabel), value: value)
        }
        return (label: L(presentation.label), value: rawPlan)
    }

    private var menuBarSettingsPickers: [ProviderSettingsPickerDescriptor] {
        self.settingsPickers.filter { $0.placement == .menuBar }
    }

    private var connectionSettingsPickers: [ProviderSettingsPickerDescriptor] {
        self.settingsPickers.filter { $0.placement == .connection }
    }

    var body: some View {
        Form {
            Section {
                ProviderDetailHeaderRow(
                    provider: self.provider,
                    store: self.store,
                    isEnabled: self.$isEnabled,
                    subtitle: self.subtitle,
                    onRefresh: self.onRefresh)

                ProviderDetailInfoRows(
                    provider: self.provider,
                    store: self.store,
                    isEnabled: self.isEnabled,
                    versionText: Self.versionText(provider: self.provider, store: self.store),
                    model: self.model,
                    showsAccountInfo: self.accountUsageOverview == nil)
            }

            if let overview = self.accountUsageOverview {
                ProviderAccountUsageOverviewView(
                    provider: self.provider,
                    overview: overview,
                    isEnabled: self.isEnabled)
                if let tokenUsage = self.model.tokenUsage {
                    Section {
                        ProviderTokenUsageInlineView(provider: self.provider, tokenUsage: tokenUsage)
                    } header: {
                        Text(L(self.store.settings.codexLocalSessionCostLedgerEnabled ? "This Mac" : "Local usage"))
                    } footer: {
                        SettingsSectionFooter(L(self.store.settings.codexLocalSessionCostLedgerEnabled
                                ? "Local usage is shared across accounts on this Mac."
                                : "Local usage comes from the current Codex profile."))
                    }
                }
                if let diagnostic = self.openAIWebDiagnostic {
                    Section {
                        Text(diagnostic).font(.footnote).foregroundStyle(.secondary)
                    } header: {
                        Text(L("OpenAI web extras"))
                    }
                }
            } else {
                Section {
                    ProviderMetricsInlineView(
                        provider: self.provider,
                        model: self.model,
                        openAIWebDiagnostic: self.openAIWebDiagnostic,
                        isEnabled: self.isEnabled,
                        isRefreshing: self.store.refreshingProviders.contains(self.provider.instanceID))
                } header: {
                    Text(L("Usage"))
                }
            }

            if !self.usageItems.isEmpty {
                ProviderUsageItemVisibilitySettingsView(
                    provider: self.provider,
                    settings: self.store.settings,
                    items: self.usageItems)
            }

            if self.accountUsageOverview == nil, let errorDisplay {
                Section {
                    ProviderErrorView(
                        title: String(
                            format: L("last_fetch_failed_with_provider"),
                            self.store.metadata(for: self.provider).displayName),
                        display: errorDisplay,
                        isExpanded: self.$isErrorExpanded,
                        onCopy: { self.onCopyError(errorDisplay.full) })
                }
            }

            ProviderMenuBarPercentWindowSettingsView(
                provider: self.provider,
                settings: self.store.settings)

            if !self.menuBarSettingsPickers.isEmpty {
                Section {
                    ForEach(self.menuBarSettingsPickers) { picker in
                        ProviderSettingsPickerRowView(picker: picker)
                    }
                } header: {
                    Text(L("provider_section_menu_bar"))
                }
            }

            if !self.connectionSettingsPickers.isEmpty || !self.settingsActions.isEmpty {
                Section {
                    ForEach(self.connectionSettingsPickers) { picker in
                        ProviderSettingsPickerRowView(picker: picker)
                    }
                    ForEach(self.settingsActions) { descriptor in
                        ProviderSettingsActionsRowView(descriptor: descriptor)
                    }
                } header: {
                    Text(L("provider_section_connection"))
                }
            }

            if let tokenAccounts = self.settingsTokenAccounts,
               tokenAccounts.isVisible?() ?? true
            {
                ProviderSettingsTokenAccountsRowView(descriptor: tokenAccounts)
            }

            ForEach(self.settingsFields) { field in
                ProviderSettingsFieldRowView(field: field)
            }

            ForEach(self.settingsDirectoryLists) { descriptor in
                ProviderSettingsDirectoryListRowView(descriptor: descriptor)
            }

            ForEach(self.settingsModelLimits) { descriptor in
                ProviderSettingsModelLimitsRowView(descriptor: descriptor)
                    .id(ModelLimitsIdentity(id: descriptor.id, scope: descriptor.scope))
            }

            if let organizations = self.settingsOrganizations {
                ProviderSettingsOrganizationsRowView(descriptor: organizations)
            }

            if self.showsSupplementarySettingsContent {
                self.supplementarySettingsContent
            }

            ProviderAccentColorSettingsView(provider: self.provider, settings: self.store.settings)

            ProviderQuotaWarningSettingsView(provider: self.provider, settings: self.store.settings)

            if !self.settingsToggles.isEmpty {
                Section {
                    ForEach(self.settingsToggles) { toggle in
                        ProviderSettingsToggleRowView(toggle: toggle)
                    }
                } header: {
                    Text(L("Options"))
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

@MainActor
struct ProviderUsageItemVisibilitySettingsView: View {
    let provider: UsageProvider
    @Bindable var settings: SettingsStore
    let items: [ProviderUsageItemDescriptor]

    var body: some View {
        Section {
            ForEach(self.items) { item in
                Toggle(
                    isOn: Binding(
                        get: { self.settings.isUsageItemVisible(item.id, for: self.provider) },
                        set: { isVisible in
                            self.settings.setUsageItemVisible(
                                isVisible,
                                itemID: item.id,
                                for: self.provider)
                        })) {
                    VStack(alignment: .leading) {
                        Text(item.title)
                        if item.requiresOptionalUsage, !self.settings.showOptionalCreditsAndExtraUsage {
                            Text(L("Hidden by the global optional credits, spending & billing setting."))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .toggleStyle(.checkbox)
            }

            Button(L("Restore Defaults")) {
                self.settings.restoreDefaultUsageItemVisibility(for: self.provider)
            }
            .disabled(self.settings.hiddenUsageItemIDs(for: self.provider).isEmpty)
        } header: {
            Text(L("Visible usage items"))
        } footer: {
            SettingsSectionFooter(L(
                "Choose which usage rows appear in this provider's menu, Settings preview, and Overview."))
        }
    }
}

@MainActor
struct ProviderDetailHeaderRow: View {
    let provider: UsageProvider
    @Bindable var store: UsageStore
    @Binding var isEnabled: Bool
    let subtitle: String
    let onRefresh: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ProviderDetailBrandIcon(provider: self.provider)

            VStack(alignment: .leading, spacing: 2) {
                Text(self.store.metadata(for: self.provider).displayName)
                    .font(.title3.weight(.semibold))

                Text(self.detailSubtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            Button {
                self.onRefresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help(L("Refresh"))

            Toggle(L("Enabled"), isOn: self.$isEnabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .padding(.vertical, 2)
    }

    private var detailSubtitle: String {
        let lines = self.subtitle.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count >= 2 else { return self.subtitle }
        let first = lines[0]
        let rest = lines.dropFirst().joined(separator: "\n")
        let tail = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        if tail.isEmpty {
            return String(first)
        }
        return "\(first) • \(tail)"
    }
}

@MainActor
private struct ProviderDetailBrandIcon: View {
    let provider: UsageProvider

    var body: some View {
        if let brand = ProviderBrandIcon.image(for: self.provider) {
            Image(nsImage: brand)
                .resizable()
                .scaledToFit()
                .frame(width: 28, height: 28)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        } else {
            Image(systemName: "circle.dotted")
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }
}

@MainActor
struct ProviderDetailInfoRows: View {
    let provider: UsageProvider
    @Bindable var store: UsageStore
    let isEnabled: Bool
    let versionText: String?
    let model: UsageMenuCardView.Model
    var showsAccountInfo: Bool = true

    var body: some View {
        if self.showsAccountInfo {
            ProviderDetailInfoRow(label: L("Source"), value: self.store.sourceLabel(for: self.provider))
        }
        if let versionText {
            ProviderDetailInfoRow(label: L("Version"), value: versionText)
        }
        if self.showsAccountInfo {
            ProviderDetailInfoRow(label: L("Updated"), value: self.updatedText)
        }

        if let status = self.store.status(for: self.provider) {
            ProviderDetailInfoRow(label: L("Status"), value: status.description ?? status.indicator.label)
        }

        if self.showsAccountInfo, !self.model.email.isEmpty {
            ProviderDetailInfoRow(label: L("Account"), value: self.model.email)
        }

        // Provider-specific by design: Kiro reports an auth method as a separate identity field, not a plan.
        if self.provider == .kiro,
           let authMethod = self.store.snapshot(for: self.provider.instanceID)?.loginMethod(for: .kiro),
           !authMethod.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            ProviderDetailInfoRow(label: L("Auth"), value: authMethod)
        }

        if self.showsAccountInfo, let planRow = ProviderDetailView<EmptyView>.planRow(
            provider: self.provider,
            planText: self.model.planText)
        {
            ProviderDetailInfoRow(label: planRow.label, value: planRow.value)
        }
    }

    private var updatedText: String {
        if let updated = self.store.snapshot(for: self.provider.instanceID)?.updatedAt {
            return UsageFormatter.updatedString(from: updated)
        }
        if self.store.refreshingProviders.contains(self.provider.instanceID) {
            return L("Refreshing")
        }
        if self.store.unavailableMessage(for: self.provider) != nil {
            return L("Unavailable")
        }
        return L("Not fetched yet")
    }
}

private struct ProviderDetailInfoRow: View {
    let label: String
    let value: String

    var body: some View {
        LabeledContent(self.label) {
            Text(self.value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .textSelection(.enabled)
        }
    }
}

@MainActor
struct ProviderMetricsInlineView: View {
    let provider: UsageProvider
    let model: UsageMenuCardView.Model
    let openAIWebDiagnostic: String?
    let isEnabled: Bool
    let isRefreshing: Bool

    struct InfoRow: Identifiable, Equatable {
        enum ID: Hashable {
            case credits
            case openAIWeb
        }

        let id: ID
        let label: String
        let value: String
    }

    struct ContentState: Equatable {
        let hasMetrics: Bool
        let hasUsageNotes: Bool
        let hasProviderCost: Bool
        let hasInfoRows: Bool
        let hasTokenUsage: Bool
        let hasResetCredits: Bool
        let hasCloudCredits: Bool
        let hasProviderDetails: Bool

        init(model: UsageMenuCardView.Model, infoRows: [InfoRow]) {
            self.hasMetrics = !model.metrics.isEmpty
            self.hasUsageNotes = !model.usageNotes.isEmpty
            self.hasProviderCost = model.providerCost?.showsInProviderDetails == true
            self.hasInfoRows = !infoRows.isEmpty
            self.hasTokenUsage = model.tokenUsage != nil
            self.hasResetCredits = model.limitResetCredits != nil
            self.hasCloudCredits = model.cloudCredits != nil
            self.hasProviderDetails = !model.providerDetails.isEmpty
        }

        var showsPlaceholder: Bool {
            !self.hasMetrics &&
                !self.hasUsageNotes &&
                !self.hasProviderCost &&
                !self.hasInfoRows &&
                !self.hasTokenUsage &&
                !self.hasResetCredits &&
                !self.hasCloudCredits &&
                !self.hasProviderDetails
        }
    }

    static func infoRows(
        for model: UsageMenuCardView.Model,
        openAIWebDiagnostic: String?) -> [InfoRow]
    {
        var rows: [InfoRow] = []
        if let credits = model.creditsText {
            rows.append(InfoRow(id: .credits, label: L("Credits"), value: credits))
        }
        if let diagnostic = openAIWebDiagnostic {
            rows.append(InfoRow(id: .openAIWeb, label: L("OpenAI web extras"), value: diagnostic))
        }
        return rows
    }

    var body: some View {
        let infoRows = Self.infoRows(for: self.model, openAIWebDiagnostic: self.openAIWebDiagnostic)
        let contentState = ContentState(model: self.model, infoRows: infoRows)

        if contentState.showsPlaceholder {
            Text(self.placeholderText)
                .font(.footnote)
                .foregroundStyle(.secondary)
        } else {
            ForEach(self.model.metrics, id: \.id) { metric in
                ProviderMetricInlineRow(
                    metric: metric,
                    title: ProviderDetailView<EmptyView>.metricTitle(provider: self.provider, metric: metric),
                    progressColor: self.model.progressColor)
            }

            if contentState.hasUsageNotes {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(self.model.usageNotes.enumerated()), id: \.offset) { _, note in
                        Text(note)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            ForEach(infoRows) { row in
                ProviderDetailInfoRow(label: row.label, value: row.value)
            }

            if let resetCredits = self.model.limitResetCredits {
                ProviderLimitResetCreditsInlineRow(presentation: resetCredits)
            }

            if let cloudCredits = self.model.cloudCredits {
                ProviderMetricInlineTextRow(title: cloudCredits.title, value: cloudCredits.spendLine)
            }

            if let providerCost = self.model.providerCost, providerCost.showsInProviderDetails {
                ProviderMetricInlineCostRow(
                    section: providerCost,
                    progressColor: self.model.progressColor)
            }

            if let tokenUsage = self.model.tokenUsage {
                ProviderTokenUsageInlineView(provider: self.model.provider, tokenUsage: tokenUsage)
            }

            if contentState.hasProviderDetails {
                ProviderDetailSectionsContent(
                    sections: self.model.providerDetails,
                    chartColor: self.model.progressColor)
            }
        }
    }

    private var placeholderText: String {
        Self.placeholderText(
            isEnabled: self.isEnabled,
            isRefreshing: self.isRefreshing,
            modelPlaceholder: self.model.placeholder)
    }

    static func placeholderText(
        isEnabled: Bool,
        isRefreshing: Bool,
        modelPlaceholder: String?) -> String
    {
        if !isEnabled {
            return L("Disabled — no recent data")
        }
        if isRefreshing {
            return L("Refreshing")
        }
        return modelPlaceholder.map(L) ?? L("No usage yet")
    }
}

struct ProviderTokenUsageInlineView: View {
    let provider: UsageProvider
    let tokenUsage: UsageMenuCardView.Model.TokenUsageSection

    var body: some View {
        ProviderMetricInlineTextRow(
            title: UsageMenuCardView.Model.tokenUsageHeader(provider: self.provider),
            value: self.tokenUsage.sessionLine)
        ProviderMetricInlineTextRow(title: "", value: self.tokenUsage.monthLine)
        if ProviderDescriptorRegistry.descriptor(for: self.provider).tokenCost.showsHintInProviderDetails,
           let hint = self.tokenUsage.hintLine, !hint.isEmpty
        {
            ProviderMetricInlineTextRow(title: "", value: hint)
        }
    }
}

private struct ProviderMetricInlineRow: View {
    let metric: UsageMenuCardView.Model.Metric
    let title: String
    let progressColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch ProviderDetailView<EmptyView>.metricInlinePresentation(self.metric) {
            case let .status(statusText):
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(self.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(statusText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            case .progress:
                let presentation = self.metric.linePresentation(title: self.title)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(presentation.titleText)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .layoutPriority(1)
                    Spacer(minLength: 8)
                    if let resetText = presentation.resetText {
                        Text(resetText)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                UsageProgressBar(
                    percent: self.metric.percent,
                    tint: self.progressColor,
                    accessibilityLabel: self.metric.percentStyle.accessibilityLabel,
                    pacePercent: self.metric.pacePercent,
                    paceOnTop: self.metric.paceOnTop,
                    warningMarkerPercents: self.metric.warningMarkerPercents,
                    workdayMarkerPercents: self.metric.workdayMarkerPercents,
                    workdayTickAppearance: self.metric.workdayTickAppearance)
                    .frame(maxWidth: .infinity)

                if let metaText = presentation.metaText {
                    Text(metaText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                if let detail = self.metric.detailText, !detail.isEmpty {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

private struct ProviderLimitResetCreditsInlineRow: View {
    let presentation: LimitResetCreditsPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(L("Limit Reset Credits"))
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                Text(self.presentation.text)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Image(systemName: "clock")
                    .font(.caption2)
                Text(self.presentation.expirySummaryText)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .accessibilityHidden(true)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(self.presentation.accessibilityLabel)
    }
}

private struct ProviderMetricInlineTextRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            if !self.title.isEmpty {
                Text(self.title)
                    .font(.subheadline.weight(.semibold))
            }
            Spacer(minLength: 8)
            Text(self.value)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }
}

private struct ProviderMetricInlineCostRow: View {
    let section: UsageMenuCardView.Model.ProviderCostSection
    let progressColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(self.section.title)
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                if let percentLine = self.section.percentLine {
                    Text(percentLine)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            if let percentUsed = self.section.percentUsed {
                UsageProgressBar(
                    percent: percentUsed,
                    tint: self.progressColor,
                    accessibilityLabel: L("Usage used"))
                    .frame(maxWidth: .infinity)
            }

            Text(self.section.spendLine)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.vertical, 2)
    }
}
