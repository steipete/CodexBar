import CodexBarCore
import Dispatch
import Foundation

@MainActor
final class MemoryPressureMonitor {
    private let logger = CodexBarLog.logger(LogCategories.memoryPressure)
    private let releaseFreeMallocPages: @Sendable () -> Void
    private var source: DispatchSourceMemoryPressure?

    init(releaseFreeMallocPages: @escaping @Sendable () -> Void = {
        MemoryPressureRelief.releaseFreeMallocPages()
    }) {
        self.releaseFreeMallocPages = releaseFreeMallocPages
    }

    func start() {
        guard self.source == nil else { return }

        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .global(qos: .utility))
        source.setEventHandler { [weak self, weak source] in
            let event = source?.data ?? []
            let isWarning = event.contains(.warning)
            let isCritical = event.contains(.critical)
            Task { @MainActor [weak self] in
                self?.handleMemoryPressure(isWarning: isWarning, isCritical: isCritical)
            }
        }
        self.source = source
        source.resume()
    }

    func stop() {
        self.source?.cancel()
        self.source = nil
    }

    deinit {
        self.source?.cancel()
    }

    #if DEBUG
    func handleMemoryPressureForTesting(isWarning: Bool, isCritical: Bool) {
        self.handleMemoryPressure(isWarning: isWarning, isCritical: isCritical)
    }
    #endif

    private func handleMemoryPressure(isWarning: Bool, isCritical: Bool) {
        let level = if isCritical {
            "critical"
        } else if isWarning {
            "warning"
        } else {
            "normal"
        }
        self.logger.warning("System memory pressure", metadata: ["level": level])
        #if DEBUG
        let cachedWebViewsBefore = OpenAIDashboardFetcher.cachedWebViewCountForTesting()
        #endif
        OpenAIDashboardFetcher.evictIdleCachedWebViews()
        #if DEBUG
        let cachedWebViewsAfter = OpenAIDashboardFetcher.cachedWebViewCountForTesting()
        self.logger.info(
            "Memory pressure OpenAI webview cache",
            metadata: [
                "before": "\(cachedWebViewsBefore)",
                "after": "\(cachedWebViewsAfter)",
                "evicted": "\(max(0, cachedWebViewsBefore - cachedWebViewsAfter))",
            ])
        #endif
        let releaseFreeMallocPages = self.releaseFreeMallocPages
        Task.detached(priority: .utility) {
            releaseFreeMallocPages()
        }
    }
}
