import Foundation

extension HookEvent {
    /// Both app publications and headless polls use the same optional quota fields.
    ///
    /// Plan metadata comes only from `UsageSnapshot.planObservation`: the raw identifier and the
    /// source that reported it. Display labels are never promoted to hook metadata, and an absent
    /// observation omits the fields entirely.
    public static func usageUpdated(
        provider: String,
        snapshot: UsageSnapshot,
        account: String?,
        timestamp: Date = Date()) -> HookEvent
    {
        let primary = snapshot.primary.flatMap { $0.isSyntheticPlaceholder ? nil : $0 }
        let secondary = snapshot.secondary.flatMap { $0.isSyntheticPlaceholder ? nil : $0 }
        let planObservation = snapshot.planObservation
        return HookEvent(
            event: .usageUpdated,
            provider: provider,
            account: account,
            usagePercent: primary.map { $0.usedPercent / 100 },
            windowMinutes: primary?.windowMinutes,
            resetAt: primary?.resetsAt,
            secondaryUsagePercent: secondary.map { $0.usedPercent / 100 },
            secondaryWindowMinutes: secondary?.windowMinutes,
            secondaryResetAt: secondary?.resetsAt,
            plan: planObservation?.rawPlan,
            planSource: planObservation?.source,
            planObservedAt: planObservation?.observedAt,
            timestamp: timestamp)
    }
}
