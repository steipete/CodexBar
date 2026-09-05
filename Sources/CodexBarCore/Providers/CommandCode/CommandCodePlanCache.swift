import Foundation

/// Remembers the Command Code subscription plan for the billing period it belongs to.
///
/// The monthly grant size lives only in `/internal/billing/subscriptions`, which the fetcher joins
/// under a short grace so a slow optional request cannot hold the credits result. That grace is
/// lost several times a day in practice. The plan is constant for a whole billing period, so a
/// remembered plan lets a timed-out refresh size the monthly lane from the fresh credits response
/// instead of publishing an unknown grant.
///
/// Entries are in-memory only, scoped to a credential fingerprint so one account can never size
/// another account's lane, dropped at `currentPeriodEnd`, and dropped again once no refresh has
/// confirmed them for a day.
actor CommandCodePlanCache {
    struct Entry: Sendable {
        let plan: CommandCodePlanCatalog.Plan
        let periodEnd: Date
        let storedAt: Date
    }

    /// Distinct credentials retained at once. A rotated session cookie yields a new fingerprint,
    /// so the bound only exists to keep rotations from growing the map without limit.
    private static let capacity = 4

    /// How long an entry survives without a successful lookup confirming it. Successful lookups
    /// dominate in practice, so this bounds retention after the credential goes away - a cleared
    /// cookie cache, a disabled provider - without ever expiring an entry a live account still
    /// refreshes. It also bounds a server-supplied `currentPeriodEnd` far in the future.
    private static let maximumUnconfirmedAge: TimeInterval = 24 * 60 * 60

    private var entries: [String: Entry] = [:]

    /// Remembers a resolved plan whose billing period has a known future end.
    ///
    /// Retention ignores the subscription status, because the live path sizes the lane from any
    /// resolved plan: a trialing, past-due, or cancel-at-period-end account keeps its grant until
    /// the period ends. A subscription without `currentPeriodEnd` is not retained, because an entry
    /// that cannot expire would keep sizing the lane after the grant refills.
    func store(
        plan: CommandCodePlanCatalog.Plan,
        periodEnd: Date?,
        fingerprint: String,
        now: Date)
    {
        guard let periodEnd, periodEnd > now else {
            self.entries[fingerprint] = nil
            return
        }
        self.entries[fingerprint] = Entry(plan: plan, periodEnd: periodEnd, storedAt: now)
        self.prune(now: now)
    }

    /// Forgets the remembered plan once a lookup proves it wrong: a verified free tier, or a plan
    /// id this build cannot size.
    ///
    /// A verdict older than the entry it would remove is ignored, so a slow response cannot revoke
    /// a plan that a later refresh already confirmed.
    func clear(fingerprint: String, now: Date) {
        guard let entry = self.entries[fingerprint], entry.storedAt <= now else { return }
        self.entries[fingerprint] = nil
    }

    /// The remembered plan for this credential, or nil once it expires.
    ///
    /// An entry recorded after the instant being reported cannot describe that instant, so a
    /// backdated read never sees it.
    func entry(fingerprint: String, now: Date) -> Entry? {
        guard let entry = self.entries[fingerprint] else { return nil }
        guard entry.storedAt <= now else { return nil }
        guard entry.periodEnd > now,
              now.timeIntervalSince(entry.storedAt) < Self.maximumUnconfirmedAge
        else {
            self.entries[fingerprint] = nil
            return nil
        }
        return entry
    }

    private func prune(now: Date) {
        self.entries = self.entries.filter { $0.value.periodEnd > now }
        guard self.entries.count > Self.capacity else { return }
        let stale = self.entries
            .sorted { $0.value.storedAt < $1.value.storedAt }
            .prefix(self.entries.count - Self.capacity)
        for (key, _) in stale {
            self.entries[key] = nil
        }
    }
}
