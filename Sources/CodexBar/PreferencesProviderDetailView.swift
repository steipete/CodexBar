import CodexBarCore
import SwiftUI

enum ProviderMetricInlinePresentation: Equatable {
    case progress
    case status(String)
}

@MainActor
struct ProviderDetailView<SupplementaryContent: View>: View {
    let provider: UsageProvider
    @Bindable var store: UsageStore
    @Binding var isEnabled: Bool
    let subtitle: String
    let model: UsageMenuCardView.Model
    let settingsPickers: [ProviderSettingsPickerDescriptor]
    let settingsToggles: [ProviderSettingsToggleDescriptor]
    let settingsFields: [ProviderSettingsFieldDescriptor]
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
        settingsPickers: [ProviderSettingsPickerDescriptor],
        settingsToggles: [ProviderSettingsToggleDescriptor],
        settingsFields: [ProviderSettingsFieldDescriptor],
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
        self.settingsPickers = settingsPickers
        self.settingsToggles = settingsToggles
        self.settingsFields = settingsFields
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
        guard provider == .openrouter || provider == .mimo || provider == .moonshot || provider == .poe else {
            return (label: L("Plan"), value: rawPlan)
        }

        let prefix = "Balance:"
        if rawPlan.hasPrefix(prefix) {
            let valueStart = rawPlan.index(rawPlan.startIndex, offsetBy: prefix.count)
            let trimmedValue = rawPlan[valueStart...].trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedValue.isEmpty {
                return (label: L("Balance"), value: trimmedValue)
            }
        }
        if provider == .mimo {
            return (label: L("Plan"), value: rawPlan)
        }
        return (label: L("Balance"), value: rawPlan)
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
                    model: self.model)
            }

            Section {
                ProviderMetricsInlineView(
                    provider: self.provider,
                    model: self.model,
                    isEnabled: self.isEnabled)
            } header: {
                Text(L("Usage"))
            }

            if let errorDisplay {
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

            if !self.settingsPickers.isEmpty || !self.settingsActions.isEmpty {
                Section {
                    ForEach(self.settingsPickers) { picker in
                        ProviderSettingsPickerRowView(picker: picker)
                    }
                    ForEach(self.settingsActions) { descriptor in
                        ProviderSettingsActionsRowView(descriptor: descriptor)
                    }
                } header: {
                    Text(L("Settings"))
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

            if let organizations = self.settingsOrganizations {
                ProviderSettingsOrganizationsRowView(descriptor: organizations)
            }

            if self.showsSupplementarySettingsContent {
                self.supplementarySettingsContent
            }

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
    }
}

@MainActor
private struct ProviderDetailHeaderRow: View {
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
private struct ProviderDetailInfoRows: View {
    let provider: UsageProvider
    @Bindable var store: UsageStore
    let isEnabled: Bool
    let model: UsageMenuCardView.Model

    var body: some View {
        ProviderDetailInfoRow(label: L("Source"), value: self.store.sourceLabel(for: self.provider))
        ProviderDetailInfoRow(label: L("Version"), value: self.store.version(for: self.provider) ?? L("not detected"))
        ProviderDetailInfoRow(label: L("Updated"), value: self.updatedText)

        if let status = self.store.status(for: self.provider) {
            ProviderDetailInfoRow(label: L("Status"), value: status.description ?? status.indicator.label)
        }

        if !self.model.email.isEmpty {
            ProviderDetailInfoRow(label: L("Account"), value: self.model.email)
        }

        if self.provider == .kiro,
           let authMethod = self.store.snapshot(for: self.provider)?.loginMethod(for: .kiro),
           !authMethod.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            ProviderDetailInfoRow(label: L("Auth"), value: authMethod)
        }

        if let planRow = ProviderDetailView<EmptyView>.planRow(
            provider: self.provider,
            planText: self.model.planText)
        {
            ProviderDetailInfoRow(label: planRow.label, value: planRow.value)
        }
    }

    private var updatedText: String {
        if let updated = self.store.snapshot(for: self.provider)?.updatedAt {
            return UsageFormatter.updatedString(from: updated)
        }
        if self.store.refreshingProviders.contains(self.provider) {
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
    let isEnabled: Bool

    var body: some View {
        let hasMetrics = !self.model.metrics.isEmpty
        let hasUsageNotes = !self.model.usageNotes.isEmpty
        let hasCredits = self.model.creditsText != nil
        let hasProviderCost = self.model.providerCost != nil
        let hasTokenUsage = self.model.tokenUsage != nil
        let hasResetCredits = self.model.codexResetCredits != nil

        if !hasMetrics, !hasUsageNotes, !hasProviderCost, !hasCredits, !hasTokenUsage, !hasResetCredits {
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

            if hasUsageNotes {
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

            if let credits = self.model.creditsText {
                ProviderDetailInfoRow(label: L("Credits"), value: credits)
            }

            if let resetCredits = self.model.codexResetCredits {
                ProviderCodexResetCreditsInlineRow(presentation: resetCredits)
            }

            if let providerCost = self.model.providerCost {
                ProviderMetricInlineCostRow(
                    section: providerCost,
                    progressColor: self.model.progressColor)
            }

            if let tokenUsage = self.model.tokenUsage {
                ProviderMetricInlineTextRow(title: L("Cost"), value: tokenUsage.sessionLine)
                ProviderMetricInlineTextRow(title: "", value: tokenUsage.monthLine)
            }
        }
    }

    private var placeholderText: String {
        if !self.isEnabled {
            return L("Disabled — no recent data")
        }
        return self.model.placeholder.map(L) ?? L("No usage yet")
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
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(self.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(self.metric.percentLabel)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                UsageProgressBar(
                    percent: self.metric.percent,
                    tint: self.progressColor,
                    accessibilityLabel: self.metric.percentStyle.accessibilityLabel,
                    pacePercent: self.metric.pacePercent,
                    paceOnTop: self.metric.paceOnTop,
                    warningMarkerPercents: self.metric.warningMarkerPercents)
                    .frame(maxWidth: .infinity)

                let hasLeftDetail = self.metric.detailLeftText?.isEmpty == false
                let hasRightDetail = self.metric.detailRightText?.isEmpty == false
                let resetText = self.metric.resetText ?? ""
                if hasLeftDetail || hasRightDetail || !resetText.isEmpty {
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
                        } else if !resetText.isEmpty {
                            Text(resetText)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if hasRightDetail, !resetText.isEmpty {
                    Text(resetText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
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

private struct ProviderCodexResetCreditsInlineRow: View {
    let presentation: CodexResetCreditsPresentation

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
