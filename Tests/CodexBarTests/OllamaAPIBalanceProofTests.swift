import AppKit
import SwiftUI
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct OllamaAPIBalanceProofTests {
    @Test
    func `render synthetic API balance card`() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["CODEXBAR_OLLAMA_API_PROOF_PATH"] else { return }
        try #require(environment["CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS"] == "1")
        let now = try #require(ISO8601DateFormatter().date(from: "2026-10-09T12:00:00Z"))
        let before = environment["CODEXBAR_OLLAMA_API_PROOF_BEFORE"] == "1"
        let transport = ProviderHTTPTransportHandler { request in
            let body = request.url?.path == "/api/tags" ? #"{"models":[]}"# : OllamaAPIBalanceTests.fixture
            let response = try #require(HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil))
            return (Data(body.utf8), response)
        }
        let snapshot: UsageSnapshot
        if before {
            snapshot = try await OllamaAPIUsageFetcher.fetchUsage(
                apiKey: "fixture-key", transport: transport, now: now).toUsageSnapshot()
        } else {
            let runtime = try ProviderPluginRuntime(bundledPlugin: "ollama-api", transport: transport)
            snapshot = try await runtime.fetchUsage(secrets: ["OLLAMA_API_KEY": "fixture-key"], now: now)
        }
        let model = try UsageMenuCardView.Model.make(.init(
            provider: .ollama,
            metadata: #require(ProviderDefaults.metadata[.ollama]),
            snapshot: snapshot,
            credits: nil,
            creditsError: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: true,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            sourceLabel: "api",
            hidePersonalInfo: true,
            now: now))
        let settings = testSettingsStore(suiteName: #function, userDefaults: InMemoryUserDefaults())
        settings.ollamaUsageDataSource = .api
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        let context = ProviderSettingsContext(
            provider: .ollama,
            settings: settings,
            store: store,
            statusText: { _ in nil },
            setStatusText: { _, _ in },
            lastAppActiveRunAt: { _ in nil },
            setLastAppActiveRunAt: { _, _ in },
            requestConfirmation: { _ in })
        let picker = try #require(OllamaProviderImplementation().settingsPickers(context: context)
            .first { $0.id == "ollama-usage-source" })
        let hosting = NSHostingView(rootView: VStack(spacing: 12) {
            Text("Ollama · Synthetic API balance fixture").font(.headline)
            UsageMenuCardView(model: model, width: 360)
            Form {
                ProviderSettingsPickerRowView(picker: picker)
            }.formStyle(.grouped).frame(height: 140)
        }.padding(.top, 16).frame(width: 540)
            .environment(\.locale, Locale(identifier: "en_US_POSIX"))
            .environment(\.colorScheme, .light)
            .background(Color(nsColor: .windowBackgroundColor)))
        hosting.appearance = NSAppearance(named: .aqua)
        try #require(MenuLayoutScreenshotRenderTests.pngDataWithWindow(hosting: hosting))
            .write(to: URL(fileURLWithPath: path))
    }
}
