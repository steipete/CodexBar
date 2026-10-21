import CodexBarCore
import Foundation

/// Snapshot-only ordering shared by Auto windows and the unified highest-usage icon.
enum AutomaticQuotaSelection {
    struct Candidate {
        let window: RateWindow
        let paceSlot: ProviderPaceSlot?
    }

    struct Selection {
        let candidate: Candidate
        let eta: TimeInterval?
        var window: RateWindow {
            self.candidate.window
        }
    }

    static func select(
        candidates: [Candidate],
        provider: UsageProvider,
        now: Date,
        dataConfidence: UsageDataConfidence = .unknown) -> Selection?
    {
        candidates.compactMap {
            self.selection(candidate: $0, provider: provider, now: now, dataConfidence: dataConfidence)
        }.reduce(nil) { best, candidate in
            guard let best else { return candidate }
            return self.precedes(best, candidate) ? candidate : best
        }
    }

    static func candidates(windows: [RateWindow], snapshot: UsageSnapshot) -> [Candidate] {
        windows.map { window in
            Candidate(window: window, paceSlot: self.paceSlot(for: window, in: snapshot))
        }
    }

    static func candidates(snapshot: UsageSnapshot) -> [Candidate] {
        [
            snapshot.primary.map { Candidate(window: $0, paceSlot: .primary) },
            snapshot.secondary.map { Candidate(window: $0, paceSlot: .secondary) },
            snapshot.tertiary.map { Candidate(window: $0, paceSlot: .tertiary) },
        ].compactMap(\.self)
    }

    static func paceSlot(for window: RateWindow, in snapshot: UsageSnapshot) -> ProviderPaceSlot? {
        let matches = self.candidates(snapshot: snapshot).filter { $0.window == window }
        return matches.count == 1 ? matches.first?.paceSlot : nil
    }

    static func selection(
        candidate: Candidate,
        provider: UsageProvider,
        now: Date,
        dataConfidence: UsageDataConfidence) -> Selection?
    {
        let window = candidate.window
        guard !window.isSyntheticPlaceholder, window.usedPercent.isFinite, window.usedPercent >= 0 else { return nil }
        let capability = ProviderDescriptorRegistry.descriptor(for: provider).pace
        let supportsLanePace = candidate.paceSlot.map {
            capability.resolvedKind(slot: $0, window: window, now: now) != nil
        } ?? capability.supportsResetWindowPace(window: window, now: now)
        var eta: TimeInterval?
        if capability.allowsPace(dataConfidence: dataConfidence), supportsLanePace, window.windowMinutes != nil,
           let pace = UsagePace.weekly(window: capability.resolvedResetWindowForPace(window), now: now),
           pace.expectedUsedPercent >= 3, let seconds = pace.etaSeconds, seconds.isFinite, seconds > 0,
           let reset = window.resetsAt, seconds < reset.timeIntervalSince(now)
        {
            eta = seconds
        }
        return Selection(candidate: candidate, eta: eta)
    }

    static func precedes(_ lhs: Selection, _ rhs: Selection) -> Bool {
        if (lhs.window.usedPercent >= 100) != (rhs.window.usedPercent >= 100) {
            return lhs.window.usedPercent < 100
        }
        if (lhs.eta != nil) != (rhs.eta != nil) {
            return lhs.eta == nil
        }
        if let left = lhs.eta, let right = rhs.eta, left != right {
            return left > right
        }
        return lhs.window.usedPercent < rhs.window.usedPercent
    }
}
