import CodexBarCore
import Foundation

struct ProviderUsageItemID: Hashable, Sendable {
    private static let metricPrefix = "metric:"
    private static let detailSectionPrefix = "detailSection:"

    let rawValue: String

    var metricID: String? {
        self.rawValue.hasPrefix(Self.metricPrefix) ? String(self.rawValue.dropFirst(Self.metricPrefix.count)) : nil
    }

    var detailSectionTitle: String? {
        self.rawValue.hasPrefix(Self.detailSectionPrefix)
            ? String(self.rawValue.dropFirst(Self.detailSectionPrefix.count)) : nil
    }

    static let credits = Self(rawValue: "section:credits")
    static let codexResetCredits = Self(rawValue: "section:codex-reset-credits")
    static let claudeResetCredits = Self(rawValue: "section:claude-reset-credits")
    static let claudeExtraUsage = Self(rawValue: "section:claude-extra-usage")
    static let subscription = Self(rawValue: "section:subscription")

    static func metric(_ metricID: String) -> Self {
        if metricID == "claude-extra-usage" { return .claudeExtraUsage }
        return Self(rawValue: "\(self.metricPrefix)\(metricID)")
    }

    static func detailSection(_ rawTitle: String) -> Self {
        Self(rawValue: "\(self.detailSectionPrefix)\(rawTitle)")
    }
}

struct ProviderUsageItemDescriptor: Identifiable, Equatable, Sendable {
    let id: ProviderUsageItemID
    let title: String
    var requiresOptionalUsage: Bool = false
}

extension ProviderUsageItemID {
    @MainActor
    func requiresOptionalUsage(for provider: UsageProvider) -> Bool {
        // Provider-specific by design: Codex extra limits and Claude Extra usage/Routines follow global gates.
        if self == .credits || (provider == .claude && self == .claudeExtraUsage) {
            return true
        }
        if let metricID = self.metricID {
            // CodexAdditionalRateLimitMapper assigns the codex- prefix to optional extra limits.
            // A Codex "monthly" metric can be a real 30-day quota (always visible) or the synthetic
            // credit-limit lane (globally gated); usageItemDescriptors resolves that from the window.
            // The ID-level rule stays conservative for hidden placeholders, which lack window data.
            return (provider == .codex && (metricID.hasPrefix("codex-") || metricID == "monthly"))
                || (provider == .claude && metricID == "claude-routines")
        }
        guard let rawTitle = self.detailSectionTitle else { return false }
        let policy = ProviderDescriptorRegistry.descriptor(for: provider).presentation.optionalDetails
        return policy.hidesAllWithoutOptionalUsage || policy.hiddenTitlesWithoutOptionalUsage.contains(rawTitle)
    }

    /// Label used when the provider is not reporting the item right now, so the settings row still
    /// names something recognizable instead of falling back to a raw storage key.
    func unreportedTitle(for provider: UsageProvider) -> String {
        switch self {
        case .credits: return L("Credits")
        case .codexResetCredits, .claudeResetCredits: return L("Limit Reset Credits")
        case .claudeExtraUsage: return L("Extra usage")
        case .subscription: return L("Plan renewal / expiry")
        default:
            if let detailSectionTitle {
                return L(detailSectionTitle)
            }
            guard let metricID = self.metricID else { return self.rawValue }
            if metricID == "claude-routines" {
                return L("Daily Routines")
            }

            let providerPrefix = "\(provider.rawValue)-"
            let displayID = metricID.hasPrefix(providerPrefix)
                ? String(metricID.dropFirst(providerPrefix.count))
                : metricID
            return displayID
                .split(separator: "-")
                .map { component in
                    component.prefix(1).uppercased() + component.dropFirst()
                }
                .joined(separator: " ")
        }
    }
}

extension UsageMenuCardView.Model {
    var quotaSubscriptionNotes: [String] {
        // Provider-specific by design: Codex and Claude place their plan dates beside quota windows.
        self.provider == .codex || self.provider == .claude ? self.subscriptionNotes : []
    }

    var supplementalUsageNotes: [String] {
        self.usageNotes.filter { !self.quotaSubscriptionNotes.contains($0) }
    }

    @MainActor
    var usageItemDescriptors: [ProviderUsageItemDescriptor] {
        var descriptors = self.metrics.map { metric in
            let itemID = ProviderUsageItemID.metric(metric.id)
            // Provider-specific by design: the synthetic Codex credit lane is globally gated, while a
            // real 30-day quota window keeps showing while the global switch is off.
            let requiresOptionalUsage = self.provider == .codex && metric.id == "monthly"
                ? metric.isSyntheticCreditLane
                : itemID.requiresOptionalUsage(for: self.provider)
            return ProviderUsageItemDescriptor(
                id: itemID,
                title: UsageMenuCardView.popupMetricTitle(provider: self.provider, metric: metric),
                requiresOptionalUsage: requiresOptionalUsage)
        }
        if !self.quotaSubscriptionNotes.isEmpty {
            descriptors.append(.init(id: .subscription, title: L("Plan renewal / expiry")))
        }
        // Provider-specific by design: Codex reset credits are a non-metric section with their own visibility choice.
        if self.provider == .codex, self.limitResetCredits != nil {
            descriptors.append(ProviderUsageItemDescriptor(
                id: .codexResetCredits,
                title: L("Limit Reset Credits")))
        }
        if self.provider == .claude, self.limitResetCredits != nil {
            descriptors.append(.init(id: .claudeResetCredits, title: L("Limit Reset Credits")))
        }
        if self.creditsText != nil {
            descriptors.append(ProviderUsageItemDescriptor(
                id: .credits,
                title: L("Credits"),
                requiresOptionalUsage: true))
        }
        let costSummaryTitles = ProviderDescriptorRegistry
            .descriptor(for: self.provider).presentation.optionalDetails.costSummaryTitles
        descriptors.append(contentsOf: zip(self.providerDetails, self.providerDetailRawTitles)
            .compactMap { section, rawTitle in
                guard let rawTitle, let title = section.title, !costSummaryTitles.contains(rawTitle) else { return nil }
                let itemID = ProviderUsageItemID.detailSection(rawTitle)
                return ProviderUsageItemDescriptor(
                    id: itemID,
                    title: title,
                    requiresOptionalUsage: itemID.requiresOptionalUsage(for: self.provider))
            })

        // Provider-specific by design: Claude cloud credits keep their detail-section ID outside the generic list.
        if let cloudCredits = self.cloudCredits {
            descriptors.append(ProviderUsageItemDescriptor(
                id: .detailSection(ClaudeCloudCreditsSnapshot.detailTitle),
                title: cloudCredits.title,
                requiresOptionalUsage: true))
        }

        if self.provider == .claude, let cost = self.providerCost,
           cost.title == L("Extra usage") || cost.title == L("Credits")
        {
            descriptors.append(.init(id: .claudeExtraUsage, title: cost.title, requiresOptionalUsage: true))
        }

        var seen = Set<ProviderUsageItemID>()
        return descriptors.filter { seen.insert($0.id).inserted }
    }

    /// `usageItemDescriptors` plus a row for every hidden item the provider stopped reporting.
    ///
    /// A partial refresh, an outage, or a plan change can drop a lane the user hid earlier. Without
    /// these placeholders its checkbox disappears while the selection stays stored, so the only way
    /// back is Restore Defaults, which also discards every other choice.
    @MainActor
    func usageItemDescriptors(includingHidden hiddenItemIDs: Set<ProviderUsageItemID>, hidePersonalInfo: Bool = false)
        -> [ProviderUsageItemDescriptor]
    {
        var descriptors = self.usageItemDescriptors
        guard !hiddenItemIDs.isEmpty else { return descriptors }

        let reported = Set(descriptors.map(\.id))
        for itemID in hiddenItemIDs.subtracting(reported).sorted(by: { $0.rawValue < $1.rawValue }) {
            let rawTitle = itemID.unreportedTitle(for: self.provider)
            let title = PersonalInfoRedactor.redactEmails(in: rawTitle, isEnabled: hidePersonalInfo) ?? rawTitle
            descriptors.append(ProviderUsageItemDescriptor(
                id: itemID,
                title: L("%@ (unavailable)", title),
                requiresOptionalUsage: itemID.requiresOptionalUsage(for: self.provider)))
        }
        return descriptors
    }

    func applyingUsageItemVisibility(hiddenItemIDs: Set<ProviderUsageItemID>) -> Self {
        guard !hiddenItemIDs.isEmpty else { return self }
        var projected = self
        projected.metrics.removeAll { hiddenItemIDs.contains(.metric($0.id)) }
        if hiddenItemIDs.contains(.credits) {
            projected.creditsText = nil
            projected.creditsRemaining = nil
            projected.creditsProgressPercent = nil
            projected.creditsScaleText = nil
            projected.creditsHintText = nil
            projected.creditsHintCopyText = nil
        }
        // Provider-specific by design: Claude Extra usage excludes Admin API spend; reset choices stay provider-owned.
        if hiddenItemIDs.contains(.claudeExtraUsage), self.provider == .claude, let cost = self.providerCost,
           cost.title == L("Extra usage") || cost.title == L("Credits")
        {
            projected.providerCost = nil
        }
        if hiddenItemIDs.contains(.subscription), !self.quotaSubscriptionNotes.isEmpty {
            projected.usageNotes.removeAll { self.subscriptionNotes.contains($0) }
            projected.subscriptionNotes = []
        }
        if (self.provider == .codex && hiddenItemIDs.contains(.codexResetCredits)) ||
            (self.provider == .claude && hiddenItemIDs.contains(.claudeResetCredits))
        {
            projected.limitResetCredits = nil
        }
        let hiddenTitles = Set(hiddenItemIDs.compactMap(\.detailSectionTitle))
        if hiddenTitles.contains(ClaudeCloudCreditsSnapshot.detailTitle) {
            projected.cloudCredits = nil
        }
        if !hiddenTitles.isEmpty {
            let kept = self.providerDetails.enumerated().compactMap { index, section
                -> (section: ProviderDetailSection, rawTitle: String?)? in
                let rawTitle = self.providerDetailRawTitles.indices.contains(index)
                    ? self.providerDetailRawTitles[index] : nil
                guard rawTitle.map({ !hiddenTitles.contains($0) }) ?? true else { return nil }
                return (section, rawTitle)
            }
            projected.providerDetails = kept.map(\.section)
            projected.providerDetailRawTitles = kept.map(\.rawTitle)
        }
        return projected
    }
}

extension SettingsStore {
    func hiddenUsageItemIDs(for provider: UsageProvider) -> Set<ProviderUsageItemID> {
        if let storedIDs = self.providerConfig(for: provider)?.hiddenUsageItemIDs {
            return Set(storedIDs.map(ProviderUsageItemID.init(rawValue:)))
        }

        var hiddenIDs = Set<ProviderUsageItemID>()
        // Provider-specific by design: migrate the legacy Codex Spark and Claude Daily Routines visibility toggles.
        if provider == .codex, !self.codexSparkUsageVisible {
            hiddenIDs.insert(.metric("codex-spark"))
            hiddenIDs.insert(.metric("codex-spark-weekly"))
        }
        if provider == .claude, !self.claudeDailyRoutinesUsageVisible {
            hiddenIDs.insert(.metric("claude-routines"))
        }
        return hiddenIDs
    }

    func isUsageItemVisible(_ itemID: ProviderUsageItemID, for provider: UsageProvider) -> Bool {
        !self.hiddenUsageItemIDs(for: provider).contains(itemID)
    }

    func setUsageItemVisible(
        _ isVisible: Bool,
        itemID: ProviderUsageItemID,
        for provider: UsageProvider)
    {
        var hiddenIDs = self.hiddenUsageItemIDs(for: provider)
        let changed = if isVisible {
            hiddenIDs.remove(itemID) != nil
        } else {
            hiddenIDs.insert(itemID).inserted
        }
        guard changed else { return }

        self.persistHiddenUsageItemIDs(hiddenIDs, for: provider)
        self.updateLegacyUsageVisibility(provider: provider, hiddenItemIDs: hiddenIDs)
    }

    func restoreDefaultUsageItemVisibility(for provider: UsageProvider) {
        guard !self.hiddenUsageItemIDs(for: provider).isEmpty ||
            self.providerConfig(for: provider)?.hiddenUsageItemIDs == nil
        else { return }

        self.persistHiddenUsageItemIDs([], for: provider)
        self.updateLegacyUsageVisibility(provider: provider, hiddenItemIDs: [])
    }

    private func persistHiddenUsageItemIDs(
        _ hiddenItemIDs: Set<ProviderUsageItemID>,
        for provider: UsageProvider)
    {
        let rawIDs = hiddenItemIDs.map(\.rawValue).sorted()
        self.updateProviderConfig(provider: provider, affectsBackgroundWork: false) { entry in
            entry.hiddenUsageItemIDs = rawIDs
        }
    }

    private func updateLegacyUsageVisibility(
        provider: UsageProvider,
        hiddenItemIDs: Set<ProviderUsageItemID>)
    {
        // Provider-specific by design: keep legacy toggles synchronized so downgrades preserve the closest behavior.
        if provider == .codex {
            let sparkIDs: Set<ProviderUsageItemID> = [
                .metric("codex-spark"),
                .metric("codex-spark-weekly"),
            ]
            self.codexSparkUsageVisible = !sparkIDs.isSubset(of: hiddenItemIDs)
        }
        if provider == .claude {
            self.claudeDailyRoutinesUsageVisible = !hiddenItemIDs.contains(.metric("claude-routines"))
        }
    }
}
