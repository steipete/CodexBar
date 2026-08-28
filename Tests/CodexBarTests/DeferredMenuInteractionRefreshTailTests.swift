import AppKit
import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct DeferredMenuInteractionRefreshTailTests {
    @Test
    func `repeated scheduling during forced enrichment produces one deferred refresh`() async {
        let settings = testSettingsStore(
            suiteName: "DeferredMenuInteractionRefreshTailTests-forced-tail")
        settings.providerDetectionCompleted = true
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        settings.costUsageEnabled = true
        settings.openAIWebAccessEnabled = false
        settings.codexCookieSource = .off
        for provider in UsageProvider.allCases {
            guard let metadata = ProviderRegistry.shared.metadata[provider] else { continue }
            settings.setProviderEnabled(
                provider: provider,
                metadata: metadata,
                enabled: provider == .codex)
        }

        let isolatedRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-deferred-refresh-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let environment = [
            "HOME": isolatedRoot.path,
            "CODEX_HOME": isolatedRoot.appendingPathComponent(".codex", isDirectory: true).path,
        ]
        let fetcher = UsageFetcher(environment: environment)
        let store = UsageStore(
            fetcher: fetcher,
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: environment)
        let tokenTail = DeferredMenuRefreshTokenTailBlocker()
        var providerRefreshCount = 0
        store._test_providerRefreshOverride = { provider in
            guard provider == .codex else { return }
            providerRefreshCount += 1
        }
        store._test_codexCreditsLoaderOverride = {
            CreditsSnapshot(remaining: 25, events: [], updatedAt: Date())
        }
        store._test_tokenUsageRefreshOverride = { provider, force in
            guard provider == .codex, force else { return }
            await tokenTail.run()
        }
        defer {
            store._test_providerRefreshOverride = nil
            store._test_codexCreditsLoaderOverride = nil
            store._test_tokenUsageRefreshOverride = nil
        }

        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: testStatusBar(),
            menuCardRenderingEnabled: false,
            menuRefreshEnabled: false)
        defer {
            controller.cancelDeferredMenuInteractionRefreshTask()
            controller.releaseStatusItemsForTesting()
        }
        var deferredRefreshCount = 0
        controller.onDeferredMenuInteractionRefreshForTesting = {
            deferredRefreshCount += 1
        }

        await store.refresh(enrichmentMode: .forcedBackground)
        let enrichmentTask = store.forcedRefreshEnrichmentTask
        let didStartTail = await tokenTail.waitUntilStarted()
        #expect(didStartTail)
        guard didStartTail else {
            store.cancelForcedRefreshEnrichment()
            await enrichmentTask?.value
            return
        }
        #expect(providerRefreshCount == 1)
        #expect(store.hasForcedRefreshEnrichmentInFlight)

        // The follow-up automatic refresh should not start another token-cost tail.
        settings.costUsageEnabled = false
        controller.deferMenuInteractionRefreshIfNeeded(providers: [.codex])
        for _ in 0..<3 {
            controller.scheduleDeferredMenuInteractionRefreshIfNeeded(delay: .zero)
            try? await Task.sleep(for: .milliseconds(30))
        }

        #expect(deferredRefreshCount == 0)
        #expect(providerRefreshCount == 1)
        #expect(controller.deferredMenuInteractionRefreshProviders == [.codex])
        #expect(controller.deferredMenuInteractionRefreshTask != nil)

        await tokenTail.release()
        await enrichmentTask?.value
        controller.scheduleDeferredMenuInteractionRefreshIfNeeded(delay: .zero)

        let completedExactlyOnce = await Self.waitUntil {
            deferredRefreshCount == 1 &&
                providerRefreshCount == 2 &&
                !controller.deferredMenuInteractionRefreshPending
        }
        #expect(completedExactlyOnce)
        #expect(deferredRefreshCount == 1)
        #expect(providerRefreshCount == 2)
        #expect(controller.deferredMenuInteractionRefreshProviders.isEmpty)
    }

    private static func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @escaping @MainActor () -> Bool) async -> Bool
    {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now >= deadline {
                return false
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }
}

private actor DeferredMenuRefreshTokenTailBlocker {
    private var started = 0
    private var released = false
    private var waiter: (id: UUID, continuation: CheckedContinuation<Void, Never>)?

    func run() async {
        let id = UUID()
        self.started += 1
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if self.released || Task.isCancelled {
                    continuation.resume()
                } else {
                    self.waiter = (id: id, continuation: continuation)
                }
            }
        } onCancel: {
            Task { await self.cancel(id: id) }
        }
    }

    func waitUntilStarted(timeout: Duration = .seconds(2)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while self.started == 0 {
            if ContinuousClock.now >= deadline {
                return false
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    func release() {
        self.released = true
        self.waiter?.continuation.resume()
        self.waiter = nil
    }

    private func cancel(id: UUID) {
        guard self.waiter?.id == id else { return }
        self.waiter?.continuation.resume()
        self.waiter = nil
    }
}
