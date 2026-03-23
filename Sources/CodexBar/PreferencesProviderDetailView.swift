import CodexBarCore
import SwiftUI

@MainActor
struct ProviderDetailView: View {
    let provider: UsageProvider
    @Bindable var store: UsageStore
    @Bindable var settings: SettingsStore
    @Binding var isEnabled: Bool
    let subtitle: String
    let model: UsageMenuCardView.Model
    let settingsPickers: [ProviderSettingsPickerDescriptor]
    let settingsToggles: [ProviderSettingsToggleDescriptor]
    let settingsFields: [ProviderSettingsFieldDescriptor]
    let settingsTokenAccounts: ProviderSettingsTokenAccountsDescriptor?
    let errorDisplay: ProviderErrorDisplay?
    @Binding var isErrorExpanded: Bool
    let onCopyError: (String) -> Void
    let onRefresh: () -> Void

    /// Width of the scroll view’s content column (drives Codex token switcher — must not use `detailMaxWidth` there).
    @State private var measuredDetailContentWidth: CGFloat = 0

    static func metricTitle(provider: UsageProvider, metric: UsageMenuCardView.Model.Metric) -> String {
        UsageMenuCardView.popupMetricTitle(provider: provider, metric: metric)
    }

    static func planRow(provider: UsageProvider, planText: String?) -> (label: String, value: String)? {
        guard let rawPlan = planText?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawPlan.isEmpty
        else {
            return nil
        }
        guard provider == .openrouter else {
            return (label: "Plan", value: rawPlan)
        }

        let prefix = "Balance:"
        if rawPlan.hasPrefix(prefix) {
            let valueStart = rawPlan.index(rawPlan.startIndex, offsetBy: prefix.count)
            let trimmedValue = rawPlan[valueStart...].trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedValue.isEmpty {
                return (label: "Balance", value: trimmedValue)
            }
        }
        return (label: "Balance", value: rawPlan)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                let labelWidth = self.detailLabelWidth
                ProviderDetailHeaderView(
                    provider: self.provider,
                    store: self.store,
                    isEnabled: self.$isEnabled,
                    subtitle: self.subtitle,
                    model: self.model,
                    labelWidth: labelWidth,
                    hideAccountAndPlan: self.codexHidesHeaderAccountAndPlan,
                    onRefresh: self.onRefresh)

                // Multi-account toggles rendered ABOVE the Accounts section so that
                // expanding/collapsing accounts never shifts the toggle's scroll position.
                if !self.codexEarlyToggles.isEmpty {
                    ProviderSettingsSection(title: "Multi-Account") {
                        ForEach(self.codexEarlyToggles) { toggle in
                            if toggle.isVisible?() ?? true {
                                ProviderSettingsToggleRowView(toggle: toggle)
                                    .id(toggle.id)
                            }
                        }
                    }
                }

                // Accounts section: always in the view tree to prevent ScrollView
                // from resetting scroll position when the section appears/disappears.
                if let tokenAccounts = self.settingsTokenAccounts {
                    let accountsVisible = tokenAccounts.isVisible?() ?? true
                    ProviderSettingsSection(title: "Accounts") {
                        ProviderSettingsTokenAccountsRowView(descriptor: tokenAccounts)
                    }
                    .frame(maxHeight: accountsVisible ? nil : 0)
                    .opacity(accountsVisible ? 1 : 0)
                    .clipped()
                    .allowsHitTesting(accountsVisible)
                    .accessibilityHidden(!accountsVisible)
                }

                Group {
                    if self.provider == .codex, self.codexShowsUsageAccountSwitcher {
                        let accounts = self.settings.tokenAccounts(for: .codex)
                        let defaultLabel = CodexProviderImplementation()
                            .tokenAccountDefaultLabel(settings: self.settings)
                        let displaySelection = self.settings.displayTokenAccountActiveIndex(for: .codex)
                        ProviderMetricsInlineView(
                            provider: self.provider,
                            model: self.model,
                            isEnabled: self.isEnabled,
                            labelWidth: labelWidth,
                            accountSwitcher: {
                                let identity = self.codexUsageAccountSwitcherIdentity
                                let widthKey = String(Int(self.codexAccountSwitcherLayoutWidth))
                                let switcherID = "\(identity)-\(widthKey)"
                                TokenAccountSwitcherRepresentable(
                                    accounts: accounts,
                                    defaultAccountLabel: defaultLabel,
                                    selectedIndex: displaySelection,
                                    width: self.codexAccountSwitcherLayoutWidth,
                                    onSelect: { index in
                                        self.settings.setActiveTokenAccountIndex(index, for: .codex)
                                        Task { @MainActor in
                                            await ProviderInteractionContext.$current.withValue(.userInitiated) {
                                                await self.store.refreshProvider(.codex, allowDisabled: true)
                                            }
                                        }
                                    })
                                    .id(switcherID)
                                    .frame(height: TokenAccountSwitcherView.preferredHeight(
                                        accounts: accounts,
                                        defaultAccountLabel: defaultLabel))
                            })
                    } else {
                        ProviderMetricsInlineView(
                            provider: self.provider,
                            model: self.model,
                            isEnabled: self.isEnabled,
                            labelWidth: labelWidth)
                    }
                }

                if let tokenUsage = self.model.tokenUsage {
                    ProviderCostSettingsSection(
                        accountLabel: self.costSectionAccountLabel,
                        tokenUsage: tokenUsage)
                }

                if let errorDisplay {
                    ProviderErrorView(
                        title: "Last \(self.store.metadata(for: self.provider).displayName) fetch failed:",
                        display: errorDisplay,
                        isExpanded: self.$isErrorExpanded,
                        onCopy: { self.onCopyError(errorDisplay.full) })
                }

                if self.hasSettings {
                    ProviderSettingsSection(title: "Settings") {
                        ForEach(self.settingsSectionPickers) { picker in
                            ProviderSettingsPickerRowView(picker: picker)
                        }
                        ForEach(self.settingsFields) { field in
                            ProviderSettingsFieldRowView(field: field)
                        }
                    }
                }

                if self.hasOptionsSection {
                    ProviderSettingsSection(title: "Options") {
                        ForEach(self.optionsSectionPickers) { picker in
                            ProviderSettingsPickerRowView(picker: picker)
                        }
                        ForEach(self.optionsSectionToggles) { toggle in
                            if toggle.isVisible?() ?? true {
                                ProviderSettingsToggleRowView(toggle: toggle)
                                    .id(toggle.id)
                            }
                        }
                        if self.provider == .codex {
                            Text(self.codexOptionsFooterExplanation)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.top, 4)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: DetailContentWidthPreference.self,
                        value: proxy.size.width)
                })
            .onPreferenceChange(DetailContentWidthPreference.self) { width in
                guard width > 1 else { return }
                if abs(width - self.measuredDetailContentWidth) > 0.5 {
                    self.measuredDetailContentWidth = width
                }
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var settingsSectionPickers: [ProviderSettingsPickerDescriptor] {
        self.settingsPickers.filter { $0.section == .settings }
    }

    private var optionsSectionPickers: [ProviderSettingsPickerDescriptor] {
        self.settingsPickers.filter { $0.section == .options }
    }

    private var hasSettings: Bool {
        !self.settingsSectionPickers.isEmpty ||
            !self.settingsFields.isEmpty
    }

    private var hasOptionsSection: Bool {
        !self.optionsSectionToggles.isEmpty || !self.optionsSectionPickers.isEmpty
    }

    private static let earlyToggleIDs: Set<String> = [
        "codex-multiple-accounts",
        "codex-explicit-accounts-only",
        "codex-openai-web-dashboard",
    ]

    private var codexEarlyToggles: [ProviderSettingsToggleDescriptor] {
        guard self.provider == .codex else { return [] }
        return self.settingsToggles.filter { Self.earlyToggleIDs.contains($0.id) }
    }

    private var optionsSectionToggles: [ProviderSettingsToggleDescriptor] {
        if self.provider == .codex {
            return self.settingsToggles.filter { !Self.earlyToggleIDs.contains($0.id) }
        }
        return self.settingsToggles
    }

    private var codexOptionsFooterExplanation: String {
        if self.settings.codexExplicitAccountsOnly {
            return """
            CodexBar accounts only is on: ~/.codex is not used as an implicit account. \
            Add identities under Accounts (OAuth, API key, or manual CODEX_HOME path). \
            Use "Default" on each row to choose which one drives the menu bar.
            """
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespaces)
        }
        return """
        The primary account is whichever identity Codex has configured in ~/.codex on this Mac. \
        Other rows in Accounts are separate credentials/folders. \
        Use "Default" on each row to choose which one CodexBar shows in the menu bar.
        """
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    /// When Codex has more than one selectable account, summary email/plan reflect only the active fetch — hide to
    /// avoid confusion.
    private var codexHidesHeaderAccountAndPlan: Bool {
        guard self.provider == .codex else { return false }
        guard self.settings.codexMultipleAccountsEnabled else { return false }
        let hasPrimary = !self.settings.codexExplicitAccountsOnly &&
            CodexProviderImplementation().tokenAccountDefaultLabel(settings: self.settings) != nil
        let addedCount = self.settings.tokenAccounts(for: .codex).count
        if self.settings.codexExplicitAccountsOnly {
            return addedCount >= 2
        }
        return (hasPrimary ? 1 : 0) + addedCount >= 2
    }

    /// Same rule as the menu-bar token switcher: default ~/.codex + ≥1 added account, or 2+ added accounts.
    private var codexShowsUsageAccountSwitcher: Bool {
        guard self.provider == .codex else { return false }
        guard self.settings.codexMultipleAccountsEnabled else { return false }
        let accounts = self.settings.tokenAccounts(for: .codex)
        if self.settings.codexExplicitAccountsOnly {
            return accounts.count >= 2
        }
        let defaultLabel = CodexProviderImplementation().tokenAccountDefaultLabel(settings: self.settings)
        return (accounts.count >= 1 && defaultLabel != nil) || accounts.count > 1
    }

    private var codexUsageAccountSwitcherIdentity: String {
        let accounts = self.settings.tokenAccounts(for: .codex)
        let ids = accounts.map(\.id.uuidString).sorted().joined(separator: ",")
        let display = self.settings.displayTokenAccountActiveIndex(for: .codex)
        return "\(self.settings.configRevision)-\(ids)-\(display)"
    }

    /// `TokenAccountSwitcherView` uses a fixed AppKit width; it must match the providers pane column (~400pt), not
    /// `detailMaxWidth` (640).
    private var codexAccountSwitcherLayoutWidth: CGFloat {
        let measured = self.measuredDetailContentWidth
        let column = measured > 1 ? measured : 400
        return max(220, column - 16)
    }

    /// Display name for the account whose usage/cost is shown (token selection or primary or menu card email).
    private var costSectionAccountLabel: String? {
        let provider = self.provider
        if TokenAccountSupportCatalog.support(for: provider) != nil {
            let accounts = self.settings.tokenAccounts(for: provider)
            if self.settings.isDefaultTokenAccountActive(for: provider) || accounts.isEmpty {
                if let custom = self.settings.providerConfig(for: provider)?.defaultAccountLabel?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                    !custom.isEmpty
                {
                    return custom
                }
                return ProviderCatalog.implementation(for: provider)?
                    .tokenAccountDefaultLabel(settings: self.settings)
            }
            let raw = self.settings.tokenAccountsData(for: provider)?.activeIndex ?? -1
            let index = min(max(raw < 0 ? 0 : raw, 0), max(0, accounts.count - 1))
            guard index < accounts.count else { return nil }
            return accounts[index].displayName
        }
        let email = self.model.email.trimmingCharacters(in: .whitespacesAndNewlines)
        return email.isEmpty ? nil : email
    }

    private var detailLabelWidth: CGFloat {
        var infoLabels = ["State", "Source", "Version", "Updated"]
        if self.store.status(for: self.provider) != nil {
            infoLabels.append("Status")
        }
        let hideAccountPlan = self.codexHidesHeaderAccountAndPlan
        if !hideAccountPlan, !self.model.email.isEmpty {
            infoLabels.append("Account")
        }
        if !hideAccountPlan, let planRow = Self.planRow(provider: self.provider, planText: self.model.planText) {
            infoLabels.append(planRow.label)
        }

        var metricLabels = self.model.metrics.map { metric in
            Self.metricTitle(provider: self.provider, metric: metric)
        }
        if self.model.creditsText != nil {
            metricLabels.append("Credits")
        }
        if let providerCost = self.model.providerCost {
            metricLabels.append(providerCost.title)
        }
        if self.model.tokenUsage != nil {
            metricLabels.append("Cost")
        }

        let infoWidth = ProviderSettingsMetrics.labelWidth(
            for: infoLabels,
            font: ProviderSettingsMetrics.infoLabelFont())
        let metricWidth = ProviderSettingsMetrics.labelWidth(
            for: metricLabels,
            font: ProviderSettingsMetrics.metricLabelFont())
        return max(infoWidth, metricWidth)
    }
}

private enum DetailContentWidthPreference: PreferenceKey {
    static var defaultValue: CGFloat {
        0
    }

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if next > 0 {
            value = next
        }
    }
}

@MainActor
private struct ProviderDetailHeaderView: View {
    let provider: UsageProvider
    @Bindable var store: UsageStore
    @Binding var isEnabled: Bool
    let subtitle: String
    let model: UsageMenuCardView.Model
    let labelWidth: CGFloat
    let hideAccountAndPlan: Bool
    let onRefresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                ProviderDetailBrandIcon(provider: self.provider)

                VStack(alignment: .leading, spacing: 4) {
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
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Refresh")

                Toggle("", isOn: self.$isEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }

            ProviderDetailInfoGrid(
                provider: self.provider,
                store: self.store,
                isEnabled: self.isEnabled,
                model: self.model,
                labelWidth: self.labelWidth,
                hideAccountAndPlan: self.hideAccountAndPlan)
        }
    }

    private var detailSubtitle: String {
        let lines = self.subtitle.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count >= 2 else { return self.subtitle }
        let first = lines[0]
        let rest = lines.dropFirst().joined(separator: "\n")
        let tail = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        if tail.isEmpty { return String(first) }
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
private struct ProviderDetailInfoGrid: View {
    let provider: UsageProvider
    @Bindable var store: UsageStore
    let isEnabled: Bool
    let model: UsageMenuCardView.Model
    let labelWidth: CGFloat
    let hideAccountAndPlan: Bool

    var body: some View {
        let status = self.store.status(for: self.provider)
        let source = self.store.sourceLabel(for: self.provider)
        let version = self.store.version(for: self.provider) ?? "not detected"
        let updated = self.updatedText
        let email = self.model.email
        let enabledText = self.isEnabled ? "Enabled" : "Disabled"

        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            ProviderDetailInfoRow(label: "State", value: enabledText, labelWidth: self.labelWidth)
            ProviderDetailInfoRow(label: "Source", value: source, labelWidth: self.labelWidth)
            ProviderDetailInfoRow(label: "Version", value: version, labelWidth: self.labelWidth)
            ProviderDetailInfoRow(label: "Updated", value: updated, labelWidth: self.labelWidth)

            if let status {
                ProviderDetailInfoRow(
                    label: "Status",
                    value: status.description ?? status.indicator.label,
                    labelWidth: self.labelWidth)
            }

            if !self.hideAccountAndPlan, !email.isEmpty {
                ProviderDetailInfoRow(label: "Account", value: email, labelWidth: self.labelWidth)
            }

            if !self.hideAccountAndPlan,
               let planRow = ProviderDetailView.planRow(provider: self.provider, planText: self.model.planText)
            {
                ProviderDetailInfoRow(label: planRow.label, value: planRow.value, labelWidth: self.labelWidth)
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }

    private var updatedText: String {
        if let updated = self.store.snapshot(for: self.provider)?.updatedAt {
            return UsageFormatter.updatedString(from: updated)
        }
        if self.store.refreshingProviders.contains(self.provider) {
            return "Refreshing"
        }
        return "Not fetched yet"
    }
}

private struct ProviderDetailInfoRow: View {
    let label: String
    let value: String
    let labelWidth: CGFloat

    var body: some View {
        GridRow {
            Text(self.label)
                .frame(width: self.labelWidth, alignment: .leading)
            Text(self.value)
                .lineLimit(2)
        }
    }
}

@MainActor
struct ProviderMetricsInlineView<AccountSwitcher: View>: View {
    let provider: UsageProvider
    let model: UsageMenuCardView.Model
    let isEnabled: Bool
    let labelWidth: CGFloat
    @ViewBuilder private var accountSwitcher: AccountSwitcher

    init(
        provider: UsageProvider,
        model: UsageMenuCardView.Model,
        isEnabled: Bool,
        labelWidth: CGFloat,
        @ViewBuilder accountSwitcher: () -> AccountSwitcher)
    {
        self.provider = provider
        self.model = model
        self.isEnabled = isEnabled
        self.labelWidth = labelWidth
        self.accountSwitcher = accountSwitcher()
    }

    var body: some View {
        let hasMetrics = !self.model.metrics.isEmpty
        let hasUsageNotes = !self.model.usageNotes.isEmpty
        let hasCredits = self.model.creditsText != nil
        let hasProviderCost = self.model.providerCost != nil
        let hasTokenUsage = self.model.tokenUsage != nil
        let hasUsageRows = hasMetrics || hasUsageNotes || hasProviderCost || hasCredits
        ProviderSettingsSection(
            title: "Usage",
            titleTrailingNote: self.provider == .codex
                ? "(Cost only available for API configured accounts)"
                : nil,
            spacing: 8,
            verticalPadding: 6,
            horizontalPadding: 0)
        {
            self.accountSwitcher
            if !hasUsageRows, !hasTokenUsage {
                Text(self.placeholderText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(self.model.metrics, id: \.id) { metric in
                    ProviderMetricInlineRow(
                        metric: metric,
                        title: ProviderDetailView.metricTitle(provider: self.provider, metric: metric),
                        progressColor: self.model.progressColor,
                        labelWidth: self.labelWidth)
                }

                if hasUsageNotes {
                    ProviderUsageNotesInlineView(
                        notes: self.model.usageNotes,
                        labelWidth: self.labelWidth,
                        alignsWithMetricContent: hasMetrics)
                }

                if let credits = self.model.creditsText {
                    ProviderMetricInlineTextRow(
                        title: "Credits",
                        value: credits,
                        labelWidth: self.labelWidth)
                }

                if let providerCost = self.model.providerCost {
                    ProviderMetricInlineCostRow(
                        section: providerCost,
                        progressColor: self.model.progressColor,
                        labelWidth: self.labelWidth)
                }
            }
        }
    }

    private var placeholderText: String {
        if !self.isEnabled {
            return "Disabled — no recent data"
        }
        return self.model.placeholder ?? "No usage yet"
    }
}

extension ProviderMetricsInlineView where AccountSwitcher == EmptyView {
    init(provider: UsageProvider, model: UsageMenuCardView.Model, isEnabled: Bool, labelWidth: CGFloat) {
        self.init(
            provider: provider,
            model: model,
            isEnabled: isEnabled,
            labelWidth: labelWidth,
            accountSwitcher: { EmptyView() })
    }
}

@MainActor
private struct ProviderCostSettingsSection: View {
    let accountLabel: String?
    let tokenUsage: UsageMenuCardView.Model.TokenUsageSection

    var body: some View {
        ProviderSettingsSection(
            title: "Cost",
            spacing: 8,
            verticalPadding: 6,
            horizontalPadding: 0)
        {
            VStack(alignment: .leading, spacing: 6) {
                if let accountLabel, !accountLabel.isEmpty {
                    Text("Account: \(accountLabel)")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Text(self.tokenUsage.sessionLine)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text(self.tokenUsage.monthLine)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if let hint = self.tokenUsage.hintLine, !hint.isEmpty {
                    Text(hint)
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                }
                if let error = self.tokenUsage.errorLine, !error.isEmpty {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2)
        }
    }
}

private struct ProviderMetricInlineRow: View {
    let metric: UsageMenuCardView.Model.Metric
    let title: String
    let progressColor: Color
    let labelWidth: CGFloat

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(self.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .frame(width: self.labelWidth, alignment: .leading)

            VStack(alignment: .leading, spacing: 4) {
                UsageProgressBar(
                    percent: self.metric.percent,
                    tint: self.progressColor,
                    accessibilityLabel: self.metric.percentStyle.accessibilityLabel,
                    pacePercent: self.metric.pacePercent,
                    paceOnTop: self.metric.paceOnTop)
                    .frame(minWidth: ProviderSettingsMetrics.metricBarWidth, maxWidth: .infinity)

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(self.metric.percentLabel)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Spacer(minLength: 8)
                    if let resetText = self.metric.resetText, !resetText.isEmpty {
                        Text(resetText)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                let hasLeftDetail = self.metric.detailLeftText?.isEmpty == false
                let hasRightDetail = self.metric.detailRightText?.isEmpty == false
                if hasLeftDetail || hasRightDetail {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        if let leftDetail = self.metric.detailLeftText, !leftDetail.isEmpty {
                            Text(leftDetail)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        if let rightDetail = self.metric.detailRightText, !rightDetail.isEmpty {
                            Text(rightDetail)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if let detail = self.detailText, !detail.isEmpty {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
    }

    private var detailText: String? {
        guard let detailText = self.metric.detailText, !detailText.isEmpty else { return nil }
        return detailText
    }
}

private struct ProviderUsageNotesInlineView: View {
    let notes: [String]
    let labelWidth: CGFloat
    let alignsWithMetricContent: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if self.alignsWithMetricContent {
                Spacer()
                    .frame(width: self.labelWidth)
            }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(self.notes.enumerated()), id: \.offset) { _, note in
                    Text(note)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
    }
}

private struct ProviderMetricInlineTextRow: View {
    let title: String
    let value: String
    let labelWidth: CGFloat

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(self.title)
                .font(.subheadline.weight(.semibold))
                .frame(width: self.labelWidth, alignment: .leading)

            Text(self.value)
                .font(.footnote)
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)
        }
        .padding(.vertical, 1)
    }
}

private struct ProviderMetricInlineCostRow: View {
    let section: UsageMenuCardView.Model.ProviderCostSection
    let progressColor: Color
    let labelWidth: CGFloat

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(self.section.title)
                .font(.subheadline.weight(.semibold))
                .frame(width: self.labelWidth, alignment: .leading)

            VStack(alignment: .leading, spacing: 4) {
                UsageProgressBar(
                    percent: self.section.percentUsed,
                    tint: self.progressColor,
                    accessibilityLabel: "Usage used")
                    .frame(minWidth: ProviderSettingsMetrics.metricBarWidth, maxWidth: .infinity)

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(String(format: "%.0f%% used", self.section.percentUsed))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Spacer(minLength: 8)
                    Text(self.section.spendLine)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}
