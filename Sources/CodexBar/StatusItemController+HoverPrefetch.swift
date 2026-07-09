import AppKit
import CodexBarCore

/// Starts a usage prefetch as soon as the pointer hovers a status item so the data refresh
/// is already in flight by the time the user clicks to open the menu. The menu-open refresh
/// (`scheduleOpenMenuRefresh`) intentionally waits 1.2s because AppKit menu tracking is modal;
/// hovering happens before tracking starts, so the prefetch can begin immediately.
@MainActor
final class StatusItemHoverPrefetchTracker: NSResponder {
    private weak var button: NSStatusBarButton?
    private var trackingArea: NSTrackingArea?
    private let onHover: @MainActor () -> Void

    init(button: NSStatusBarButton, onHover: @escaping @MainActor () -> Void) {
        self.onHover = onHover
        self.button = button
        super.init()
        // `.activeAlways` because the status bar window is never key; `.inVisibleRect` keeps the
        // tracking rect in sync with the variable-length button without manual updates.
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil)
        button.addTrackingArea(area)
        self.trackingArea = area
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func invalidate() {
        if let trackingArea, let button {
            button.removeTrackingArea(trackingArea)
        }
        self.trackingArea = nil
        self.button = nil
    }

    override func mouseEntered(with event: NSEvent) {
        self.onHover()
    }
}

/// Controller-owned hover-prefetch state, grouped so `StatusItemController` carries one property.
struct StatusItemHoverPrefetchState {
    var mergedTracker: StatusItemHoverPrefetchTracker?
    var providerTrackers: [UsageProvider: StatusItemHoverPrefetchTracker] = [:]
    var tasks: [UsageProvider: Task<Void, Never>] = [:]
    var completedAt: [UsageProvider: Date] = [:]
}

extension StatusItemController {
    /// Generous bound on hover → click → 1.2s delayed open-refresh; a completed prefetch older
    /// than this no longer stands in for the menu-open refresh.
    static let hoverPrefetchFreshnessWindow: TimeInterval = 30

    /// `provider == nil` targets the merged status item (prefetches all enabled providers).
    func installStatusItemHoverPrefetchTracker(on item: NSStatusItem, provider: UsageProvider?) {
        // Retire the previous tracker first so a buttonless item can never leave a stale one behind.
        if let provider {
            self.removeStatusItemHoverPrefetchTracker(for: provider)
        } else {
            self.statusItemHoverPrefetch.mergedTracker?.invalidate()
            self.statusItemHoverPrefetch.mergedTracker = nil
        }
        guard let button = item.button else { return }
        let tracker = StatusItemHoverPrefetchTracker(button: button) { [weak self] in
            self?.handleStatusItemHoverPrefetch(for: provider)
        }
        if let provider {
            self.statusItemHoverPrefetch.providerTrackers[provider] = tracker
        } else {
            self.statusItemHoverPrefetch.mergedTracker = tracker
        }
    }

    func removeStatusItemHoverPrefetchTracker(for provider: UsageProvider) {
        self.statusItemHoverPrefetch.providerTrackers.removeValue(forKey: provider)?.invalidate()
    }

    func cancelStatusItemHoverPrefetchTasks() {
        for task in self.statusItemHoverPrefetch.tasks.values {
            task.cancel()
        }
        self.statusItemHoverPrefetch.tasks.removeAll(keepingCapacity: false)
    }

    func removeAllStatusItemHoverPrefetchTrackers() {
        self.statusItemHoverPrefetch.mergedTracker?.invalidate()
        self.statusItemHoverPrefetch.mergedTracker = nil
        for tracker in self.statusItemHoverPrefetch.providerTrackers.values {
            tracker.invalidate()
        }
        self.statusItemHoverPrefetch.providerTrackers.removeAll(keepingCapacity: false)
        self.cancelStatusItemHoverPrefetchTasks()
        self.statusItemHoverPrefetch.completedAt.removeAll(keepingCapacity: false)
    }

    /// Hover prefetch is deliberately usage-only: the OpenAI dashboard scrape stays deferred until
    /// the menu closes (see `deferOpenAIDashboardRefreshUntilMenuCloses`), matching the menu-open
    /// refresh path. While a prefetch is in flight, `refreshProvider` coalescing makes the later
    /// menu-open refresh wait for it; once it completes, the recorded completion date lets
    /// `scheduleOpenMenuRefresh` skip the provider instead of refreshing it a second time.
    func handleStatusItemHoverPrefetch(for provider: UsageProvider?) {
        guard self.isMenuRefreshEnabled,
              self.settings.refreshAllProvidersOnMenuOpen,
              !self.hasPreparedForAppShutdown,
              self.openMenus.isEmpty
        else { return }
        let enabledProviders = self.store.enabledProvidersForBackgroundWork()
        let providers: [UsageProvider] = if let provider {
            enabledProviders.contains(provider) ? [provider] : []
        } else {
            enabledProviders
        }
        // One task per provider (concurrent, mirroring the refresh-all menu-open path) so that in
        // split-icon mode hovering icon B is not suppressed by icon A's still-running prefetch.
        // Providers with a still-fresh completed prefetch are skipped so pointer re-entry doesn't
        // repeat the refresh; failed fetches fall outside the fresh set and get their retry.
        let freshProviders = self.recentlyHoverPrefetchedProviders()
        for provider in providers {
            if self.statusItemHoverPrefetch.tasks[provider] != nil || freshProviders.contains(provider) {
                self.menuLogger.debug(
                    "hoverPrefetch: skip provider=\(provider.rawValue) " +
                        "inFlight=\(self.statusItemHoverPrefetch.tasks[provider] != nil) " +
                        "fresh=\(freshProviders.contains(provider))")
                continue
            }
            self.menuLogger.debug("hoverPrefetch: start provider=\(provider.rawValue)")
            self.statusItemHoverPrefetch.tasks[provider] = Task { @MainActor [weak self] in
                guard let self else { return }
                await ProviderInteractionContext.$current.withValue(.background) {
                    await self.store.refreshProvider(provider, coalesceIfRefreshing: true)
                }
                if !Task.isCancelled {
                    self.statusItemHoverPrefetch.completedAt[provider] = Date()
                    self.statusItemHoverPrefetch.tasks[provider] = nil
                    self.menuLogger.debug("hoverPrefetch: completed provider=\(provider.rawValue)")
                }
            }
        }
    }

    /// Providers whose hover prefetch finished so recently that the menu-open refresh-all pass
    /// would only repeat it. Failed fetches are excluded so they still get their retry on open.
    func recentlyHoverPrefetchedProviders(now: Date = Date()) -> Set<UsageProvider> {
        Set(self.statusItemHoverPrefetch.completedAt.compactMap { provider, completedAt in
            guard now.timeIntervalSince(completedAt) < Self.hoverPrefetchFreshnessWindow else { return nil }
            guard !self.store.needsUsageRefreshRetry(for: provider) else { return nil }
            return provider
        })
    }
}
