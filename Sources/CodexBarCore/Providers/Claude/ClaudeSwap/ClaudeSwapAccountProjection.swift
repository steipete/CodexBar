import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Projects parsed schema-v1 list rows (`cswap --list --json`, `tcr list --json`)
/// into the provider-neutral account snapshot consumed by menus. Identity uses the
/// source-issued numeric slot (`claude-swap:<slot>`, `tcr:<slot>`), never email or
/// credential-derived values.
public enum ClaudeSwapAccountProjection {
    public static let sourceName = ClaudeSwapAccountSource.claudeSwap.label
    public static let sourceLabel = ClaudeSwapAccountSource.claudeSwap.label
    static let fiveHourWindowMinutes = 5 * 60
    static let sevenDayWindowMinutes = 7 * 24 * 60
    static let exhaustedUsedPercent = 100.0
    static let unavailableUsageNote = "Usage unavailable."

    public static func shouldPresentAccounts(accountCount: Int, showSingleAccount: Bool) -> Bool {
        accountCount >= (showSingleAccount ? 1 : 2)
    }

    public static func accountSnapshots(
        from list: ClaudeSwapAccountList,
        source: ClaudeSwapAccountSource = .claudeSwap,
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
        let duplicateEmails = self.duplicateEmails(in: ordered)
        let labels = self.displayLabels(for: ordered, duplicateEmails: duplicateEmails)
        return zip(ordered, labels).map { row, label in
            let id = ProviderAccountIdentity(source: source.label, opaqueID: String(row.number))
            let projected = self.usageSnapshot(
                for: row,
                source: source,
                previous: previousByID[id],
                now: now)
            return ProviderAccountUsageSnapshot(
                id: id,
                provider: .claude,
                displayLabel: self.decoratedLabel(label, row: row),
                accountEmail: row.email.isEmpty ? nil : row.email,
                historyAccountKey: self.historyAccountKey(for: row, source: source),
                isActive: row.isActive,
                canActivate: list.supportsAccountSwitching && self.canActivate(row),
                usesLastKnownUsage: projected.usesLastKnownUsage,
                snapshot: projected.snapshot,
                error: self.errorText(for: row, source: source, usage: projected, now: now),
                sourceLabel: source.label)
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

    /// claude-swap holds `disabled` slots out of its own rotation while keeping
    /// them fully managed. Mirror its marker so a disabled account reads the same
    /// in CodexBar as it does in `cswap list`.
    static func decoratedLabel(_ label: String, row: ClaudeSwapAccountRow) -> String {
        row.isDisabled ? "\(label) (disabled)" : label
    }

    static func displayLabel(for row: ClaudeSwapAccountRow, duplicateEmails: Set<String> = []) -> String {
        if let alias = self.alias(from: row) {
            return alias
        }
        if row.email.isEmpty {
            return "Account \(row.number)"
        }
        guard duplicateEmails.contains(self.normalizedEmail(row.email)) else {
            return row.email
        }
        if !row.organizationName.isEmpty {
            return "\(row.email) · \(row.organizationName)"
        }
        return "\(row.email) · Account \(row.number)"
    }

    private static func displayLabels(for rows: [ClaudeSwapAccountRow], duplicateEmails: Set<String>) -> [String] {
        let candidates = rows.map { self.displayLabel(for: $0, duplicateEmails: duplicateEmails) }
        var collisionCounts: [String: Int] = [:]
        for (row, label) in zip(rows, candidates) {
            guard duplicateEmails.contains(self.normalizedEmail(row.email)),
                  self.alias(from: row) == nil else { continue }
            collisionCounts[label.lowercased(), default: 0] += 1
        }
        return zip(rows, candidates).map { row, label in
            guard duplicateEmails.contains(self.normalizedEmail(row.email)),
                  self.alias(from: row) == nil,
                  collisionCounts[label.lowercased(), default: 0] > 1
            else {
                return label
            }
            return "\(label) · Account \(row.number)"
        }
    }

    private static func alias(from row: ClaudeSwapAccountRow) -> String? {
        guard let alias = row.alias?.trimmingCharacters(in: .whitespacesAndNewlines), !alias.isEmpty else {
            return nil
        }
        return alias
    }

    private static func duplicateEmails(in rows: [ClaudeSwapAccountRow]) -> Set<String> {
        var counts: [String: Int] = [:]
        for email in rows.map(\.email) {
            let normalized = self.normalizedEmail(email)
            guard !normalized.isEmpty else { continue }
            counts[normalized, default: 0] += 1
        }
        return Set(counts.compactMap { $0.value > 1 ? $0.key : nil })
    }

    private static func normalizedEmail(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private enum ProjectedUsage {
        case none
        case live(UsageSnapshot)
        case lastKnown(UsageSnapshot)

        var snapshot: UsageSnapshot? {
            switch self {
            case .none: nil
            case let .live(snapshot), let .lastKnown(snapshot): snapshot
            }
        }

        var usesLastKnownUsage: Bool {
            if case .lastKnown = self { return true }
            return false
        }
    }

    private static func usageSnapshot(
        for row: ClaudeSwapAccountRow,
        source: ClaudeSwapAccountSource,
        previous: ProviderAccountUsageSnapshot?,
        now: Date) -> ProjectedUsage
    {
        switch row.usageStatus {
        case .ok, .unavailable:
            // claude-swap serves a per-account cache, so an `ok` row can carry a
            // measurement fetched minutes ago. Prefer its own fetch time over `now`.
            if let projected = self.snapshot(
                from: row.measurement,
                row: row,
                source: source,
                updatedAt: row.usageFetchedAt ?? now)
            {
                if row.usageStatus == .ok {
                    return .live(projected)
                }
                if let pruned = self.prunedAtLimitSnapshot(
                    projected,
                    identity: projected.identity ?? self.identitySnapshot(for: row, source: source),
                    now: now)
                {
                    return .live(pruned)
                }
            }
            guard row.usageStatus == .unavailable else { return .none }
            if let reported = self.lastGoodSnapshot(for: row, source: source) {
                return .lastKnown(reported)
            }
            if let retained = self.retainedAtLimitSnapshot(previous, matching: row, source: source, now: now) {
                // Retaining a fallback must not make it eligible for the age-less icon.
                return previous?.usesLastKnownUsage == true ? .lastKnown(retained) : .live(retained)
            }
            return .none
        case .tokenExpired, .reloginRequired, .apiKey, .keychainUnavailable, .noCredentials,
             .foreignCredential, .unknown:
            guard let reported = self.lastGoodSnapshot(for: row, source: source) else { return .none }
            return .lastKnown(reported)
        }
    }

    private static func lastGoodSnapshot(
        for row: ClaudeSwapAccountRow,
        source: ClaudeSwapAccountSource) -> UsageSnapshot?
    {
        guard let lastGood = row.lastGoodUsage else { return nil }
        return self.snapshot(
            from: lastGood.measurement,
            row: row,
            source: source,
            updatedAt: lastGood.fetchedAt)
    }

    private static func retainedAtLimitSnapshot(
        _ previous: ProviderAccountUsageSnapshot?,
        matching row: ClaudeSwapAccountRow,
        source: ClaudeSwapAccountSource,
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
        return self.prunedAtLimitSnapshot(snapshot, identity: self.identitySnapshot(for: row, source: source), now: now)
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

    private static func snapshot(
        from measurement: ClaudeSwapUsageMeasurement,
        row: ClaudeSwapAccountRow,
        source: ClaudeSwapAccountSource,
        updatedAt: Date) -> UsageSnapshot?
    {
        let primary = measurement.fiveHour.map { window in
            RateWindow(
                usedPercent: window.usedPercent,
                windowMinutes: self.fiveHourWindowMinutes,
                resetsAt: window.resetsAt,
                resetDescription: nil)
        }
        let secondary = measurement.sevenDay.map { window in
            RateWindow(
                usedPercent: window.usedPercent,
                windowMinutes: self.sevenDayWindowMinutes,
                resetsAt: window.resetsAt,
                resetDescription: nil)
        }
        let scoped = self.scopedRateWindows(measurement.scoped)
        // Pay-as-you-go spend uses the shared cost row beside the 5h/7d bars.
        let providerCost = measurement.spend.map { spend in
            ProviderCostSnapshot(
                used: spend.used,
                limit: spend.limit,
                currencyCode: spend.currencyCode,
                resetsAt: spend.resetsAt,
                updatedAt: updatedAt)
        }
        guard primary != nil || secondary != nil || !scoped.isEmpty || providerCost != nil else { return nil }
        return UsageSnapshot(
            primary: primary,
            secondary: secondary,
            extraRateWindows: scoped.isEmpty ? nil : scoped,
            providerCost: providerCost,
            updatedAt: updatedAt,
            identity: self.identitySnapshot(for: row, source: source))
    }

    private static func historyAccountKey(for row: ClaudeSwapAccountRow, source: ClaudeSwapAccountSource) -> String? {
        let email = self.normalizedEmail(row.email)
        let organization = row.organizationUuid.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !email.isEmpty, source == .claudeSwap || !organization.isEmpty else { return nil }
        let pair = try? JSONEncoder().encode([email, organization])
        return pair.map { "__claude_swap__:" + SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
    }

    private static func identitySnapshot(
        for row: ClaudeSwapAccountRow,
        source: ClaudeSwapAccountSource) -> ProviderIdentitySnapshot
    {
        ProviderIdentitySnapshot(
            providerID: .claude,
            accountEmail: row.email.isEmpty ? nil : row.email,
            accountOrganization: nil,
            loginMethod: source.label,
            accountID: "\(source.label):\(row.number)")
    }

    private static func scopedRateWindows(_ windows: [ClaudeSwapScopedUsageWindow]) -> [NamedRateWindow] {
        ClaudeScopedWeeklyLimitMapper.extraRateWindows(from: windows.map { window in
            ClaudeScopedWeeklyLimitMapper.Limit(
                kind: "weekly_scoped",
                group: "weekly",
                percent: window.usedPercent,
                resetsAt: window.resetsAt,
                modelID: nil,
                modelName: window.name)
        })
    }

    private static func errorText(
        for row: ClaudeSwapAccountRow,
        source: ClaudeSwapAccountSource,
        usage: ProjectedUsage,
        now: Date) -> String?
    {
        let tool = source.label
        return switch row.usageStatus {
        case .ok:
            usage.snapshot == nil ? "No usage windows reported." : nil
        case .tokenExpired:
            "Token expired. Switch to this account in \(tool) to refresh it."
        case .reloginRequired:
            "Re-login required. Re-authenticate this account in \(tool)."
        case .apiKey:
            "API-key account; subscription usage is unavailable."
        case .keychainUnavailable:
            "\(tool) could not read the active account's Keychain entry."
        case .noCredentials:
            "No stored credentials for this account slot."
        case .foreignCredential:
            "\(tool) reports the live credential belongs to a different account. " +
                "Re-authenticate this account in \(tool) to restore its saved login."
        case .unavailable:
            usage.usesLastKnownUsage
                ? self.unavailableUsageNote
                : (self.atLimitNote(from: usage.snapshot, now: now) ?? self.unavailableUsageNote)
        case let .unknown(raw):
            "Unrecognized \(tool) status: \(raw)"
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
        if row.isActive { return row.usageStatus == .foreignCredential }
        return switch row.usageStatus {
        case .ok, .apiKey, .unavailable, .foreignCredential:
            true
        case .tokenExpired, .reloginRequired, .keychainUnavailable, .noCredentials, .unknown:
            false
        }
    }
}
