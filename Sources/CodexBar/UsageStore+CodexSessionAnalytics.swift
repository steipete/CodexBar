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
        let windowSize = self.settings.codexSessionAnalyticsWindowSize
        let bucketRefreshAt = self.lastCodexSessionAnalyticsRefreshAtByWindow[windowSize]
        let lastRefreshAt = bucketRefreshAt ?? self.lastCodexSessionAnalyticsRefreshAt
        if !force,
           let lastRefreshAt,
           now.timeIntervalSince(lastRefreshAt) < self.codexSessionAnalyticsTTL
        {
            if bucketRefreshAt == nil {
                if let snapshot = self.codexSessionAnalytics {
                    self.codexSessionAnalyticsCacheByWindow[windowSize] = snapshot
                }
                if let error = self.codexSessionAnalyticsError {
                    self.codexSessionAnalyticsErrorCacheByWindow[windowSize] = error
                }
                self.lastCodexSessionAnalyticsRefreshAtByWindow[windowSize] = lastRefreshAt
            }

            self.codexSessionAnalytics = self.codexSessionAnalyticsCacheByWindow[windowSize]
            self.codexSessionAnalyticsError = self.codexSessionAnalyticsErrorCacheByWindow[windowSize]
            self.lastCodexSessionAnalyticsRefreshAt = lastRefreshAt
            return
        }

        self.lastCodexSessionAnalyticsRefreshAt = now
        self.lastCodexSessionAnalyticsRefreshAtByWindow[windowSize] = now

        do {
            let snapshot = try self.codexSessionAnalyticsLoader.loadSnapshot(
                maxSessions: windowSize,
                now: now)
            self.codexSessionAnalytics = snapshot
            self.codexSessionAnalyticsError = nil
            if let snapshot {
                self.codexSessionAnalyticsCacheByWindow[windowSize] = snapshot
            } else {
                self.codexSessionAnalyticsCacheByWindow.removeValue(forKey: windowSize)
            }
            self.codexSessionAnalyticsErrorCacheByWindow.removeValue(forKey: windowSize)
        } catch {
            self.codexSessionAnalytics = nil
            self.codexSessionAnalyticsError = error.localizedDescription
            self.codexSessionAnalyticsCacheByWindow.removeValue(forKey: windowSize)
            self.codexSessionAnalyticsErrorCacheByWindow[windowSize] = error.localizedDescription
        }
    }
}
