import Foundation

extension HookEvent {
    /// Both app publications and headless polls use the same optional quota fields.
    public static func usageUpdated(
        provider: String,
        snapshot: UsageSnapshot,
        account: String?,
        timestamp: Date = Date()) -> HookEvent
    {
        let primary = snapshot.primary.flatMap { $0.isSyntheticPlaceholder ? nil : $0 }
        let secondary = snapshot.secondary.flatMap { $0.isSyntheticPlaceholder ? nil : $0 }
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
            timestamp: timestamp)
    }
}
