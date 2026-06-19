import CodexBarCore
import Dispatch
import Foundation

@MainActor
struct MemoryPressureCacheTrimSummary: Equatable {
    var menuCardHeights = 0
    var menuWidths = 0
    var mergedSwitcherSelections = 0
    var recycledMenuCardViews = 0
    var openAIWebDebugLines = 0

    var total: Int {
        self.menuCardHeights +
            self.menuWidths +
            self.mergedSwitcherSelections +
            self.recycledMenuCardViews +
            self.openAIWebDebugLines
    }

    var metadata: [String: String] {
        [
            "menuCardHeights": "\(self.menuCardHeights)",
            "menuWidths": "\(self.menuWidths)",
            "mergedSwitcherSelections": "\(self.mergedSwitcherSelections)",
            "recycledMenuCardViews": "\(self.recycledMenuCardViews)",
            "openAIWebDebugLines": "\(self.openAIWebDebugLines)",
            "total": "\(self.total)",
        ]
    }

    mutating func merge(_ other: MemoryPressureCacheTrimSummary) {
        self.menuCardHeights += other.menuCardHeights
        self.menuWidths += other.menuWidths
        self.mergedSwitcherSelections += other.mergedSwitcherSelections
        self.recycledMenuCardViews += other.recycledMenuCardViews
        self.openAIWebDebugLines += other.openAIWebDebugLines
    }
}

@MainActor
final class MemoryPressureMonitor {
    typealias CacheTrimHandler = @MainActor () -> MemoryPressureCacheTrimSummary

    private let logger = CodexBarLog.logger(LogCategories.memoryPressure)
    private let releaseFreeMallocPages: @Sendable () -> Void
    private let trimAppCaches: CacheTrimHandler
    private var source: DispatchSourceMemoryPressure?

    init(
        trimAppCaches: @escaping CacheTrimHandler = { MemoryPressureCacheTrimSummary() },
        releaseFreeMallocPages: @escaping @Sendable () -> Void = {
            MemoryPressureRelief.releaseFreeMallocPages()
        })
    {
        self.trimAppCaches = trimAppCaches
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
        let trimSummary = self.trimAppCaches()
        if trimSummary.total > 0 {
            self.logger.info("Trimmed app caches for memory pressure", metadata: trimSummary.metadata)
        }
        let releaseFreeMallocPages = self.releaseFreeMallocPages
        Task.detached(priority: .utility) {
            releaseFreeMallocPages()
        }
    }
}
