import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct SpendDashboardUnavailableProviderTests {
    @Test(arguments: [UsageProvider.deepseek, .xai])
    func `settled unavailable analytics do not fetch again between refresh ticks`(_ provider: UsageProvider) async {
        let (settings, store) = Self.makeStore(provider)
        defer { store._test_providerRefreshOverride = nil }
        var fetches = 0
        store._test_providerRefreshOverride = { requested in
            #expect(requested == provider)
            fetches += 1
            let snapshot = UsageSnapshot(primary: nil, secondary: nil, updatedAt: Date())
            store._setSnapshotForTesting(snapshot, provider: provider)
            store.publishProviderDerivedTokenSnapshot(from: snapshot, for: provider)
        }

        var settledRevisions: [UInt64]?
        for _ in 0..<3 {
            await store.refreshProvider(provider)
            let request = await SpendDashboardSource.makeRequest(
                settings: settings,
                store: store,
                mode: .refreshMissing)
            #expect(request.capturedInputs.isEmpty)
            #expect(request.unavailableSourceIDs == [provider.rawValue])
            #expect(request.confirmedEmptySourceIDs.isEmpty)
            if let settledRevisions {
                #expect(request.configuration.sourcePublicationRevisions == settledRevisions)
            }
            settledRevisions = request.configuration.sourcePublicationRevisions
        }
        #expect(fetches == 3)
    }

    @Test(arguments: [UsageProvider.deepseek, .xai])
    func `cached unavailable analytics settle the current scope`(_ provider: UsageProvider) async {
        let (settings, store) = Self.makeStore(provider)
        defer { store._test_providerRefreshOverride = nil }
        var fetches = 0
        store._test_providerRefreshOverride = { _ in fetches += 1 }
        store.installProviderDerivedTokenSnapshot(
            from: UsageSnapshot(primary: nil, secondary: nil, updatedAt: Date()), for: provider)
        let request = await SpendDashboardSource.makeRequest(settings: settings, store: store, mode: .refreshMissing)
        #expect(request.unavailableSourceIDs == [provider.rawValue])
        #expect(request.confirmedEmptySourceIDs.isEmpty)
        #expect(fetches == 0)
    }

    @Test
    func `switching DeepSeek token accounts invalidates settled unavailable analytics`() async {
        let provider = UsageProvider.deepseek
        let (settings, store) = Self.makeStore(provider)
        defer { store._test_providerRefreshOverride = nil }
        settings.addTokenAccount(provider: provider, label: "First", token: "synthetic-first-key")
        settings.addTokenAccount(provider: provider, label: "Second", token: "synthetic-second-key")
        #expect(settings.tokenAccounts(for: provider).count == 2)
        settings.setActiveTokenAccountIndex(0, for: provider)
        store.publishProviderDerivedTokenSnapshot(
            from: UsageSnapshot(primary: nil, secondary: nil, updatedAt: Date()), for: provider)
        var fetches = 0
        store._test_providerRefreshOverride = { _ in fetches += 1 }
        _ = await SpendDashboardSource.makeRequest(settings: settings, store: store, mode: .refreshMissing)
        #expect(fetches == 0)
        settings.setActiveTokenAccountIndex(1, for: provider)
        _ = await SpendDashboardSource.makeRequest(settings: settings, store: store, mode: .refreshMissing)
        #expect(fetches == 1)
    }

    @Test
    func `switching xAI teams invalidates settled unavailable analytics`() async {
        let (settings, store) = Self.makeStore(.xai)
        defer { store._test_providerRefreshOverride = nil }
        settings.updateProviderConfig(provider: .xai) { $0.workspaceID = "synthetic-first-team" }
        store.publishProviderDerivedTokenSnapshot(
            from: UsageSnapshot(primary: nil, secondary: nil, updatedAt: Date()), for: .xai)
        var fetches = 0
        store._test_providerRefreshOverride = { _ in fetches += 1 }
        _ = await SpendDashboardSource.makeRequest(settings: settings, store: store, mode: .refreshMissing)
        #expect(fetches == 0)
        settings.updateProviderConfig(provider: .xai) { $0.workspaceID = "synthetic-second-team" }
        _ = await SpendDashboardSource.makeRequest(settings: settings, store: store, mode: .refreshMissing)
        #expect(fetches == 1)
    }

    @Test(arguments: [UsageProvider.deepseek, .xai])
    func `missing failed changed and forced requests still fetch`(_ provider: UsageProvider) async {
        let (settings, store) = Self.makeStore(provider)
        defer { store._test_providerRefreshOverride = nil }
        var fetches = 0
        store._test_providerRefreshOverride = { _ in
            fetches += 1
            store.publishProviderDerivedTokenSnapshot(
                from: UsageSnapshot(primary: nil, secondary: nil, updatedAt: Date()), for: provider)
        }
        // No successful provider snapshot yet.
        _ = await SpendDashboardSource.makeRequest(settings: settings, store: store, mode: .refreshMissing)
        #expect(fetches == 1)
        settings.updateProviderConfig(provider: provider) { $0.apiKey = "synthetic-replacement-key" }
        _ = await SpendDashboardSource.makeRequest(settings: settings, store: store, mode: .refreshMissing)
        #expect(fetches == 2)
        // Failed provider refreshes discard their derived publication.
        store.clearProviderDerivedTokenSnapshot(for: provider)
        _ = await SpendDashboardSource.makeRequest(settings: settings, store: store, mode: .refreshMissing)
        #expect(fetches == 3)
        _ = await SpendDashboardSource.makeRequest(settings: settings, store: store, mode: .forceRefresh)
        #expect(fetches == 4)
    }

    private static func makeStore(_ provider: UsageProvider) -> (SettingsStore, UsageStore) {
        let settings = testSettingsStore(
            suiteName: "SpendDashboardUnavailableProviderTests-\(provider.rawValue)",
            userDefaults: InMemoryUserDefaults())
        settings.costUsageEnabled = true
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        enableTestProviders([provider], settings: settings)
        return (settings, UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:]))
    }
}
