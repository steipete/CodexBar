import CodexBarCore
import Foundation

struct ProviderUsageItemID: Hashable, Sendable {
    private static let metricPrefix = "metric:"

    let rawValue: String

    static let credits = Self(rawValue: "section:credits")
    static let codexResetCredits = Self(rawValue: "section:codex-reset-credits")

    static func metric(_ metricID: String) -> Self {
        Self(rawValue: "\(self.metricPrefix)\(metricID)")
    }
}

struct ProviderUsageItemDescriptor: Identifiable, Equatable, Sendable {
    let id: ProviderUsageItemID
    let title: String
}

extension ProviderUsageItemID {
    /// Label used when the provider is not reporting the item right now, so the settings row still
    /// names something recognizable instead of falling back to a raw storage key.
    var unreportedTitle: String {
        switch self {
        case .credits: L("Credits")
        case .codexResetCredits: L("Limit Reset Credits")
        default:
            self.rawValue.hasPrefix(Self.metricPrefix)
                ? String(self.rawValue.dropFirst(Self.metricPrefix.count))
                : self.rawValue
        }
    }
}

extension UsageMenuCardView.Model {
    @MainActor
    var usageItemDescriptors: [ProviderUsageItemDescriptor] {
        var descriptors = self.metrics.map { metric in
            ProviderUsageItemDescriptor(
                id: .metric(metric.id),
                title: UsageMenuCardView.popupMetricTitle(provider: self.provider, metric: metric))
        }
        // Provider-specific by design: Codex reset credits are a non-metric section with their own visibility choice.
        if self.provider == .codex {
            descriptors.append(ProviderUsageItemDescriptor(
                id: .codexResetCredits,
                title: L("Limit Reset Credits")))
        }
        if self.creditsText != nil {
            descriptors.append(ProviderUsageItemDescriptor(id: .credits, title: L("Credits")))
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
    func usageItemDescriptors(includingHidden hiddenItemIDs: Set<ProviderUsageItemID>)
        -> [ProviderUsageItemDescriptor]
    {
        var descriptors = self.usageItemDescriptors
        guard !hiddenItemIDs.isEmpty else { return descriptors }

        let reported = Set(descriptors.map(\.id))
        for itemID in hiddenItemIDs.subtracting(reported).sorted(by: { $0.rawValue < $1.rawValue }) {
            descriptors.append(ProviderUsageItemDescriptor(
                id: itemID,
                title: L("%@ (unavailable)", itemID.unreportedTitle)))
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
        if hiddenItemIDs.contains(.codexResetCredits) {
            projected.codexResetCredits = nil
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
