#if os(macOS)
import Foundation
import WebKit

@MainActor
protocol OpenAIDashboardWebsiteCacheStore {
    var identifier: UUID? { get }
    var isPersistent: Bool { get }
    func removeData(ofTypes: Set<String>, modifiedSince: Date) async
}

extension WKWebsiteDataStore: OpenAIDashboardWebsiteCacheStore {}

@MainActor
final class OpenAIDashboardCacheMaintenance {
    static let shared = OpenAIDashboardCacheMaintenance()
    private var nextCleanup: [UUID?: Date] = [:]

    func clearIfNeeded(_ store: any OpenAIDashboardWebsiteCacheStore, now: Date = Date()) async {
        guard store.isPersistent, now >= self.nextCleanup[store.identifier, default: .distantPast] else { return }
        // Keep same-day asset reuse; mark before awaiting so overlapping refreshes coalesce.
        self.nextCleanup[store.identifier] = now.addingTimeInterval(24 * 60 * 60)
        await store.removeData(
            ofTypes: [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache],
            modifiedSince: .distantPast)
    }
}
#endif
