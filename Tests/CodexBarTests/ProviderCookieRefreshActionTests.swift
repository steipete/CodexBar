import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
@Suite(.serialized)
struct ProviderCookieRefreshActionTests {
    @Test
    func `cache backed refresh requires a saved cookie even when another credential succeeds`() async {
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: storage) }
        let outcome = await CookieHeaderCache.withLegacyBaseURLOverrideForTesting(storage) {
            await ProviderCookieRefreshAction.refresh(provider: .opencode) { true }
        }
        #expect(outcome == .failed)
    }

    @Test
    func `Hyper automatic refresh saves its browser session without an API key`() async throws {
        let fixture = try ProviderSettingsDescriptorTests().makeSettingsFixture(suite: #function)
        let implementation = try #require(ProviderCatalog.implementation(for: .hyper))
        let picker = try #require(implementation.settingsPickers(
            context: fixture.settingsContext(provider: .hyper)).first)
        let action = try #require(picker.trailingActions.first)
        #expect(fixture.store.isProviderAvailable(.hyper))
        #expect(picker.binding.wrappedValue == "auto")

        let cookie = "JSESSIONID=fixture-hyper-session"
        let web = try #require(HyperProviderDescriptor.spec.webSource)
        let strategy = ScriptFetchStrategy(
            id: "hyper.js",
            provider: .hyper,
            bundledPlugin: "hyper",
            sourceLabel: "auto",
            transport: ProviderHTTPTransportHandler { request in
                #expect(request.url?.absoluteString == "https://hyper.charm.land/")
                #expect(request.value(forHTTPHeaderField: "Cookie") == cookie)
                #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
                let url = try #require(URL(
                    string: "https://hyper.charm.land/teams/11111111-2222-3333-4444-555555555555/dashboard"))
                let response = try #require(HTTPURLResponse(
                    url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/html"]))
                let html = #"<p>Hypercredits Available</p><p class="text-5xl font-bold">100</p>"#
                return (Data(html.utf8), response)
            },
            cookieImport: { _, domain, batch in
                #expect(domain == "hyper.charm.land")
                return batch == 0 ? [(cookie, "Chrome Default")] : nil
            },
            resolveValues: web.resolveValues,
            isEnabled: { _ in true })
        let context = ProviderFetchContext(
            runtime: .app,
            sourceMode: .auto,
            includeCredits: false,
            webTimeout: 10,
            webDebugDumpHTML: false,
            verbose: false,
            env: [:],
            settings: .init(.init(cookieSource: .auto), for: HyperProviderSettingsKey.self),
            fetcher: UsageFetcher(environment: [:]),
            claudeFetcher: ClaudeUsageFetcher(browserDetection: BrowserDetection()),
            browserDetection: BrowserDetection())
        fixture.store._test_providerRefreshOverride = { provider in
            do {
                let result = try await strategy.fetch(context)
                fixture.store.snapshots[provider.instanceID] = result.usage
                fixture.store.lastSourceLabels[provider.instanceID] = result.sourceLabel
            } catch {
                Issue.record("Unexpected Hyper refresh failure: \(error)")
            }
        }
        defer { fixture.store._test_providerRefreshOverride = nil }
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: storage) }
        await KeychainCacheStore.withServiceOverrideForTesting("hyper-refresh-\(UUID().uuidString)") {
            await CookieHeaderCache.withLegacyBaseURLOverrideForTesting(storage) {
                await action.perform()
                #expect(fixture.store.lastSourceLabels[.hyper] == "web")
                #expect(picker.trailingText?() != L("Failed"))
                #expect(CookieHeaderCache.load(provider: .hyper)?.cookieHeader == cookie)
            }
        }
    }

    @Test
    func `validated nonpersistent plugin refresh succeeds without saving cookies`() async throws {
        let fixture = try ProviderSettingsDescriptorTests().makeSettingsFixture(suite: #function)
        let implementation = try #require(ProviderCatalog.implementation(for: .lithosai))
        let picker = try #require(implementation.settingsPickers(
            context: fixture.settingsContext(provider: .lithosai)).first)
        let action = try #require(picker.trailingActions.first)
        fixture.store._test_providerRefreshOverride = { provider in
            CookieHeaderCache.markNonpersistentRefreshValidated(provider: provider)
            fixture.store.snapshots[provider.instanceID] = UsageSnapshot(
                primary: nil, secondary: nil, updatedAt: Date())
            fixture.store.lastSourceLabels[provider.instanceID] = "web"
        }
        defer { fixture.store._test_providerRefreshOverride = nil }
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: storage) }
        await CookieHeaderCache.withLegacyBaseURLOverrideForTesting(storage) {
            await action.perform()
            #expect(picker.trailingText?() != L("Failed"))
            #expect(CookieHeaderCache.load(provider: .lithosai) == nil)
        }
    }
}
