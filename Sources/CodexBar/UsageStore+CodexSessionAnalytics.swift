import CodexBarCore
import Foundation

extension UsageStore {
    func codexSessionAnalyticsSnapshot() -> CodexSessionAnalyticsSnapshot? {
        self.codexSessionAnalytics
    }

    func lastCodexSessionAnalyticsError() -> String? {
        self.codexSessionAnalyticsError
    }

    func requestCodexSessionAnalyticsRefreshIfStale(reason _: String) {
        self.refreshCodexSessionAnalyticsIfNeeded()
    }

    func refreshCodexSessionAnalyticsIfNeeded(force: Bool = false) {
        let now = Date()
        if !force,
           let lastRefreshAt = self.lastCodexSessionAnalyticsRefreshAt,
           now.timeIntervalSince(lastRefreshAt) < self.codexSessionAnalyticsTTL
        {
            return
        }

        self.lastCodexSessionAnalyticsRefreshAt = now

        do {
            let snapshot = try self.codexSessionAnalyticsLoader.loadSnapshot(now: now)
            self.codexSessionAnalytics = snapshot
            self.codexSessionAnalyticsError = nil
        } catch {
            self.codexSessionAnalytics = nil
            self.codexSessionAnalyticsError = error.localizedDescription
        }
    }
}
