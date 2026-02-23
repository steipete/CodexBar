import CodexBarCore
import SwiftUI

@MainActor
struct ProviderDetailView: View {
    let provider: UsageProvider
    @Bindable var store: UsageStore
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
                    onRefresh: self.onRefresh)

                ProviderMetricsInlineView(
                    provider: self.provider,
                    model: self.model,
                    isEnabled: self.isEnabled,
                    labelWidth: labelWidth)

                if let errorDisplay {
                    ProviderErrorView(
                        title: "Last \(self.store.metadata(for: self.provider).displayName) fetch failed:",
                        display: errorDisplay,
                        isExpanded: self.$isErrorExpanded,
                        onCopy: { self.onCopyError(errorDisplay.full) })
                }

                if self.hasSettings {
                    ProviderSettingsSection(title: "Settings") {
                        ForEach(self.settingsPickers) { picker in
                            ProviderSettingsPickerRowView(picker: picker)
                        }
                        if let tokenAccounts = self.settingsTokenAccounts,
                           tokenAccounts.isVisible?() ?? true
                        {
                            ProviderSettingsTokenAccountsRowView(descriptor: tokenAccounts)
                        }
                        ForEach(self.settingsFields) { field in
                            ProviderSettingsFieldRowView(field: field)
                        }
                    }
                }

                if !self.settingsToggles.isEmpty {
                    ProviderSettingsSection(title: "Options") {
                        ForEach(self.settingsToggles) { toggle in
                            ProviderSettingsToggleRowView(toggle: toggle)
                        }
                    }
                }
            }
            .frame(maxWidth: ProviderSettingsMetrics.detailMaxWidth, alignment: .leading)
            .padding(.vertical, 12)
            .padding(.horizontal, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var hasSettings: Bool {
        !self.settingsPickers.isEmpty ||
            !self.settingsFields.isEmpty ||
            self.settingsTokenAccounts != nil
    }

    private var detailLabelWidth: CGFloat {
        var infoLabels = ["State", "Source", "Version", "Updated"]
        if self.store.status(for: self.provider) != nil {
            infoLabels.append("Status")
        }
        if !self.model.email.isEmpty {
            infoLabels.append("Account")
        }
        if let planRow = Self.planRow(provider: self.provider, planText: self.model.planText) {
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

@MainActor
private struct ProviderDetailHeaderView: View {
    let provider: UsageProvider
    @Bindable var store: UsageStore
    @Binding var isEnabled: Bool
    let subtitle: String
    let model: UsageMenuCardView.Model
    let labelWidth: CGFloat
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
                labelWidth: self.labelWidth)
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

            if !email.isEmpty {
                ProviderDetailInfoRow(label: "Account", value: email, labelWidth: self.labelWidth)
            }

            if let planRow = ProviderDetailView.planRow(provider: self.provider, planText: self.model.planText) {
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
struct ProviderMetricsInlineView: View {
    let provider: UsageProvider
    let model: UsageMenuCardView.Model
    let isEnabled: Bool
    let labelWidth: CGFloat

    var body: some View {
        let hasMetrics = !self.model.metrics.isEmpty
        let hasUsageNotes = !self.model.usageNotes.isEmpty
        let hasCredits = self.model.creditsText != nil
        let hasProviderCost = self.model.providerCost != nil
        let hasTokenUsage = self.model.tokenUsage != nil
        ProviderSettingsSection(
            title: "Usage",
            spacing: 8,
            verticalPadding: 6,
            horizontalPadding: 0)
        {
            if !hasMetrics, !hasUsageNotes, !hasProviderCost, !hasCredits, !hasTokenUsage {
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

                if let tokenUsage = self.model.tokenUsage {
                    ProviderMetricInlineTextRow(
                        title: "Cost",
                        value: tokenUsage.sessionLine,
                        labelWidth: self.labelWidth)
                    ProviderMetricInlineTextRow(
                        title: "",
                        value: tokenUsage.monthLine,
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
