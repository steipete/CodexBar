import Foundation

/// Projects parsed `cswap --list --json` rows into the provider-neutral
/// account snapshot consumed by menus. Identity uses the source-issued numeric
/// slot (`claude-swap:<slot>`), never email or credential-derived values.
public enum ClaudeSwapAccountProjection {
    public static let sourceName = "claude-swap"
    public static let sourceLabel = "claude-swap"
    static let fiveHourWindowMinutes = 5 * 60
    static let sevenDayWindowMinutes = 7 * 24 * 60
    static let exhaustedUsedPercent = 100.0
    static let deferredPollingNote = "Polling deferred until a limit resets."

    public static func shouldPresentAccounts(accountCount: Int, showSingleAccount: Bool) -> Bool {
        accountCount >= (showSingleAccount ? 1 : 2)
    }

    public static func accountSnapshots(
        from list: ClaudeSwapAccountList,
        previousAccounts: [ProviderAccountUsageSnapshot] = [],
        now: Date = Date()) -> [ProviderAccountUsageSnapshot]
    {
        let previousByID = Dictionary(
            previousAccounts.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first })
        let ordered = list.accounts.sorted { lhs, rhs in
            if lhs.isActive != rhs.isActive {
                return lhs.isActive
            }
            return lhs.number < rhs.number
        }
        return ordered.map { row in
            let id = ProviderAccountIdentity(source: self.sourceName, opaqueID: String(row.number))
            let snapshot = self.usageSnapshot(
                for: row,
                previous: previousByID[id],
                now: now)
            return ProviderAccountUsageSnapshot(
                id: id,
                provider: .claude,
                displayLabel: self.displayLabel(for: row),
                isActive: row.isActive,
                canActivate: !row.isActive && self.canActivate(row),
                snapshot: snapshot,
                error: self.errorText(for: row, snapshot: snapshot, now: now),
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

    private static func usageSnapshot(
        for row: ClaudeSwapAccountRow,
        previous: ProviderAccountUsageSnapshot?,
        now: Date) -> UsageSnapshot?
    {
        switch row.usageStatus {
        case .ok, .unavailable:
            if let projected = self.projectedUsageSnapshot(for: row, now: now) {
                if row.usageStatus == .ok {
                    return projected
                }
                if let pruned = self.prunedAtLimitSnapshot(
                    projected,
                    identity: projected.identity ?? self.identitySnapshot(for: row),
                    now: now)
                {
                    return pruned
                }
            }
            guard row.usageStatus == .unavailable else { return nil }
            return self.retainedAtLimitSnapshot(previous, matching: row, now: now)
        case .tokenExpired, .reloginRequired, .apiKey, .keychainUnavailable, .noCredentials, .unknown:
            return nil
        }
    }

    private static func retainedAtLimitSnapshot(
        _ previous: ProviderAccountUsageSnapshot?,
        matching row: ClaudeSwapAccountRow,
        now: Date) -> UsageSnapshot?
    {
        guard let previous, let snapshot = previous.snapshot else { return nil }
        let previousFingerprint = ClaudeSwapRetainedUsageStore.fingerprint(from: previous)
        let rowFingerprint = ClaudeSwapRetainedUsageStore.fingerprint(
            email: row.email,
            slot: String(row.number))
        guard let previousFingerprint, let rowFingerprint, previousFingerprint == rowFingerprint else {
            return nil
        }
        return self.prunedAtLimitSnapshot(snapshot, identity: self.identitySnapshot(for: row), now: now)
    }

    /// Drops windows whose reset is in the past so a mixed snapshot cannot keep showing
    /// an already-reset lane as "Resets now" just because a sibling is still exhausted.
    private static func prunedAtLimitSnapshot(
        _ snapshot: UsageSnapshot,
        identity: ProviderIdentitySnapshot?,
        now: Date) -> UsageSnapshot?
    {
        let primary = self.unexpiredWindow(snapshot.primary, now: now)
        let secondary = self.unexpiredWindow(snapshot.secondary, now: now)
        let extra = (snapshot.extraRateWindows ?? []).compactMap { named -> NamedRateWindow? in
            guard let window = self.unexpiredWindow(named.window, now: now) else { return nil }
            return NamedRateWindow(
                id: named.id,
                title: named.title,
                window: window,
                usageKnown: named.usageKnown)
        }
        let remaining = [primary, secondary].compactMap(\.self) + extra.map(\.window)
        guard remaining.contains(where: { $0.usedPercent >= self.exhaustedUsedPercent }) else {
            return nil
        }
        return UsageSnapshot(
            primary: primary,
            secondary: secondary,
            extraRateWindows: extra.isEmpty ? nil : extra,
            updatedAt: snapshot.updatedAt,
            identity: identity,
            dataConfidence: snapshot.dataConfidence)
    }

    private static func unexpiredWindow(_ window: RateWindow?, now: Date) -> RateWindow? {
        guard let window else { return nil }
        guard let resetsAt = window.resetsAt, resetsAt > now else { return nil }
        return window
    }

    private static func projectedUsageSnapshot(for row: ClaudeSwapAccountRow, now: Date) -> UsageSnapshot? {
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
        let scoped = self.scopedRateWindows(for: row)
        guard primary != nil || secondary != nil || !scoped.isEmpty else { return nil }
        return UsageSnapshot(
            primary: primary,
            secondary: secondary,
            extraRateWindows: scoped.isEmpty ? nil : scoped,
            updatedAt: now,
            identity: self.identitySnapshot(for: row))
    }

    private static func identitySnapshot(for row: ClaudeSwapAccountRow) -> ProviderIdentitySnapshot {
        ProviderIdentitySnapshot(
            providerID: .claude,
            accountEmail: self.displayLabel(for: row),
            accountOrganization: nil,
            loginMethod: self.sourceLabel)
    }

    private static func scopedRateWindows(for row: ClaudeSwapAccountRow) -> [NamedRateWindow] {
        ClaudeScopedWeeklyLimitMapper.extraRateWindows(from: row.scoped.map { window in
            ClaudeScopedWeeklyLimitMapper.Limit(
                kind: "weekly_scoped",
                group: "weekly",
                percent: window.usedPercent,
                resetsAt: window.resetsAt,
                modelID: nil,
                modelName: window.name)
        })
    }

    private static func errorText(for row: ClaudeSwapAccountRow, snapshot: UsageSnapshot?, now: Date) -> String? {
        switch row.usageStatus {
        case .ok:
            snapshot == nil ? "No usage windows reported." : nil
        case .tokenExpired:
            "Token expired. Switch to this account in claude-swap to refresh it."
        case .reloginRequired:
            "Re-login required. Re-authenticate this account in claude-swap."
        case .apiKey:
            "API-key account; subscription usage is unavailable."
        case .keychainUnavailable:
            "claude-swap could not read the active account's Keychain entry."
        case .noCredentials:
            "No stored credentials for this account slot."
        case .unavailable:
            self.atLimitNote(from: snapshot, now: now) ?? self.deferredPollingNote
        case let .unknown(raw):
            "Unrecognized claude-swap status: \(raw)"
        }
    }

    private static func atLimitNote(from snapshot: UsageSnapshot?, now: Date) -> String? {
        guard let snapshot else { return nil }
        var parts: [String] = []
        if let primary = snapshot.primary {
            self.appendLimit(named: "Session", window: primary, now: now, to: &parts)
        }
        if let secondary = snapshot.secondary {
            self.appendLimit(named: "Weekly", window: secondary, now: now, to: &parts)
        }
        for extra in snapshot.extraRateWindows ?? [] {
            self.appendLimit(named: self.scopedLimitName(extra.title), window: extra.window, now: now, to: &parts)
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " ")
    }

    private static func appendLimit(
        named name: String,
        window: RateWindow,
        now: Date,
        to parts: inout [String])
    {
        guard window.usedPercent >= self.exhaustedUsedPercent else { return }
        if let reset = UsageFormatter.resetLine(for: window, style: .countdown, now: now) {
            parts.append("\(name) limit reached. \(reset).")
        } else {
            parts.append("\(name) limit reached.")
        }
    }

    private static func scopedLimitName(_ title: String) -> String {
        let suffix = " only"
        guard title.hasSuffix(suffix) else { return title }
        return String(title.dropLast(suffix.count))
    }

    private static func canActivate(_ row: ClaudeSwapAccountRow) -> Bool {
        switch row.usageStatus {
        case .ok, .apiKey, .unavailable:
            true
        case .tokenExpired, .reloginRequired, .keychainUnavailable, .noCredentials, .unknown:
            false
        }
    }
}
