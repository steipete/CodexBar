import Foundation

/// Retains the last confirmed allowance per credential while optional subscription requests fail.
actor CommandCodePlanCache {
    struct Entry: Sendable {
        let plan: CommandCodePlanCatalog.Plan
        let periodEnd: Date
        let storedAt: Date
    }

    /// Distinct credentials retained at once. A rotated session cookie yields a new fingerprint,
    /// so the bound only exists to keep rotations from growing the map without limit.
    private static let capacity = 4

    /// Bounds reuse when no successful lookup confirms the allowance, even with a distant period end.
    private static let maximumUnconfirmedAge: TimeInterval = 24 * 60 * 60

    private struct Observation {
        let entry: Entry?
        let observedAt: Date
    }

    private var observations: [String: Observation] = [:]

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
        let entry = periodEnd.flatMap { end in
            end > now ? Entry(plan: plan, periodEnd: end, storedAt: now) : nil
        }
        self.record(entry: entry, fingerprint: fingerprint, now: now)
    }

    /// Forgets the remembered plan once a lookup proves it wrong: a verified free tier, or a plan
    /// id this build cannot size.
    ///
    /// A verdict older than the entry it would remove is ignored, so a slow response cannot revoke
    /// a plan that a later refresh already confirmed.
    func clear(fingerprint: String, now: Date) {
        self.record(entry: nil, fingerprint: fingerprint, now: now)
    }

    /// The remembered plan for this credential, or nil once it expires.
    ///
    /// An entry recorded after the instant being reported cannot describe that instant, so a
    /// backdated read never sees it.
    func entry(fingerprint: String, now: Date) -> Entry? {
        guard let entry = self.observations[fingerprint]?.entry else { return nil }
        guard entry.storedAt <= now else { return nil }
        guard entry.periodEnd > now,
              now.timeIntervalSince(entry.storedAt) < Self.maximumUnconfirmedAge
        else {
            return nil
        }
        return entry
    }

    private func record(entry: Entry?, fingerprint: String, now: Date) {
        guard self.observations[fingerprint].map({ $0.observedAt <= now }) ?? true else { return }
        // Keep cleared verdicts too: an older response must not resurrect a superseded plan.
        self.observations[fingerprint] = Observation(entry: entry, observedAt: now)
        self.observations = self.observations.filter {
            now.timeIntervalSince($0.value.observedAt) < Self.maximumUnconfirmedAge
        }
        guard self.observations.count > Self.capacity else { return }
        let stale = self.observations
            .sorted { $0.value.observedAt < $1.value.observedAt }
            .prefix(self.observations.count - Self.capacity)
        for (key, _) in stale {
            self.observations[key] = nil
        }
    }
}
