import Foundation

/// Projects parsed `cswap --list --json` rows into the provider-neutral
/// account snapshot consumed by menus. Identity uses the source-issued numeric
/// slot (`claude-swap:<slot>`), never email or credential-derived values.
public enum ClaudeSwapAccountProjection {
    public static let sourceName = "claude-swap"
    public static let sourceLabel = "claude-swap"
    static let fiveHourWindowMinutes = 5 * 60
    static let sevenDayWindowMinutes = 7 * 24 * 60

    public static func accountSnapshots(
        from list: ClaudeSwapAccountList,
        now: Date = Date()) -> [ProviderAccountUsageSnapshot]
    {
        let ordered = list.accounts.sorted { lhs, rhs in
            if lhs.isActive != rhs.isActive { return lhs.isActive }
            return lhs.number < rhs.number
        }
        return ordered.map { row in
            ProviderAccountUsageSnapshot(
                id: ProviderAccountIdentity(source: self.sourceName, opaqueID: String(row.number)),
                provider: .claude,
                displayLabel: self.displayLabel(for: row),
                isActive: row.isActive,
                canActivate: !row.isActive && self.canActivate(row),
                snapshot: self.usageSnapshot(for: row, now: now),
                error: self.errorText(for: row),
                sourceLabel: self.sourceLabel)
        }
    }

    public static func displayError(
        accountError: String?,
        adapterError: String?,
        switchError: String? = nil) -> String?
    {
        switchError.map { "Account switch failed: \($0)" }
            ?? accountError
            ?? adapterError.map { "Showing the last successful update: \($0)" }
    }

    static func displayLabel(for row: ClaudeSwapAccountRow) -> String {
        row.email.isEmpty ? "Account \(row.number)" : row.email
    }

    private static func usageSnapshot(for row: ClaudeSwapAccountRow, now: Date) -> UsageSnapshot? {
        guard row.usageStatus == .ok else { return nil }
        let primary = row.fiveHour.map { window in
            RateWindow(
                usedPercent: window.usedPercent,
                windowMinutes: self.fiveHourWindowMinutes,
                resetsAt: window.resetsAt,
                resetDescription: nil)
        }
        let secondary = row.sevenDay.map { window in
            RateWindow(
                usedPercent: window.usedPercent,
                windowMinutes: self.sevenDayWindowMinutes,
                resetsAt: window.resetsAt,
                resetDescription: nil)
        }
        guard primary != nil || secondary != nil else { return nil }
        return UsageSnapshot(
            primary: primary,
            secondary: secondary,
            updatedAt: now,
            identity: ProviderIdentitySnapshot(
                providerID: .claude,
                accountEmail: self.displayLabel(for: row),
                accountOrganization: nil,
                loginMethod: self.sourceLabel))
    }

    private static func errorText(for row: ClaudeSwapAccountRow) -> String? {
        switch row.usageStatus {
        case .ok:
            row.fiveHour == nil && row.sevenDay == nil ? "No usage windows reported." : nil
        case .tokenExpired:
            "Token expired. Switch to this account in claude-swap to refresh it."
        case .apiKey:
            "API-key account; subscription usage is unavailable."
        case .keychainUnavailable:
            "claude-swap could not read the active account's Keychain entry."
        case .noCredentials:
            "No stored credentials for this account slot."
        case .unavailable:
            "Usage fetch failed."
        case let .unknown(raw):
            "Unrecognized claude-swap status: \(raw)"
        }
    }

    private static func canActivate(_ row: ClaudeSwapAccountRow) -> Bool {
        switch row.usageStatus {
        case .ok, .apiKey, .unavailable:
            true
        case .tokenExpired, .keychainUnavailable, .noCredentials, .unknown:
            false
        }
    }
}
