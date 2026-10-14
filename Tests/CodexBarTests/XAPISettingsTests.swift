import AppKit
import Foundation
import SwiftUI
import Testing
@testable import CodexBar
@testable import CodexBarCLI
@testable import CodexBarCore

@MainActor
@Suite(.serialized)
struct XAPISettingsTests {
    @Test
    func `X API registers a web plugin with isolated cookie settings`() throws {
        let descriptor = XAPIProviderDescriptor.descriptor
        #expect(!descriptor.metadata.defaultEnabled)
        #expect(descriptor.metadata.balanceOnly)
        #expect(!descriptor.metadata.widgetSelectable)
        #expect(!descriptor.metadata.burnDownWidgetSelectable)
        #expect(!descriptor.history.supportsPlanUtilization)
        #expect(descriptor.fetchPlan.sourceModes == [.auto, .web])
        #expect(descriptor.metadata.browserCookieOrder == ProviderBrowserCookieDefaults.defaultImportOrder)
        #expect(ProviderSelection(argument: "xapi")?.asList == [.xapi])
        let fixture = try ProviderSettingsDescriptorTests().makeSettingsFixture(suite: "XAPISettingsTests")
        let implementation = try #require(ProviderCatalog.implementation(for: .xapi))
        let context = fixture.settingsContext(provider: .xapi)
        let field = try #require(implementation.settingsFields(context: context).first)
        let picker = try #require(implementation.settingsPickers(context: context).first)
        #expect(field.id == "xapi-cookie")
        #expect(field.kind == .secure)
        #expect(picker.options.map(\.id) == ["auto", "manual", "off"])
        picker.binding.wrappedValue = "manual"
        field.binding.wrappedValue = "auth_token=synthetic; ct0=synthetic-csrf"
        #expect(fixture.settings.providerConfig(for: .xapi)?.cookieHeader == field.binding.wrappedValue)
        let contribution = try #require(implementation.settingsSnapshot(context: .init(
            settings: fixture.settings, tokenOverride: nil)))
        let snapshot = ProviderSettingsSnapshot(contributions: [contribution])
        #expect(snapshot[XAPIProviderSettingsKey.self]?.cookieSource == .manual)
        #expect(snapshot[XAPIProviderSettingsKey.self]?.manualCookieHeader == field.binding.wrappedValue)
        #expect(fixture.settings.providerConfig(for: .xai)?.cookieHeader == nil)
    }

    @Test(arguments: [12.4, 0, -2.15])
    func `X API balance reaches menu layout and synthetic card`(balance: Double) async throws {
        let runtime = try BundledPluginTestSupport.runtime(
            "xapi",
            engine: .quickJS,
            transport: ProviderHTTPTransportHandler { request in
                let url = try #require(request.url)
                let free = balance > 0 ? 2.0 : 0.0
                let paid = balance - free
                let body = url.path == "/api/me"
                    ? #"{"account":{"id":"fixture-account"}}"#
                    : "{\"credits\":{\"balance\":\(paid)},\"freeCredits\":{\"balance\":\(free)}}"
                return try (Data(body.utf8), #require(HTTPURLResponse(
                    url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])))
            })
        let snapshot = try await runtime.fetchUsage(cookieSessionResolver: { _, _ in
            .init(
                header: "auth_token=synthetic; ct0=synthetic-csrf",
                source: "Fixture",
                origin: "https://console.x.com")
        })
        let expected = UsageFormatter.currencyString(balance, currencyCode: "USD")
        #expect(MenuBarLayoutBalanceResolver.balance(provider: .xapi, snapshot: snapshot) == expected)
        let model = try UsageMenuCardView.Model.make(.init(
            provider: .xapi,
            metadata: #require(ProviderDefaults.metadata[.xapi]),
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
            resetTimeDisplayStyle: .absolute,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: true,
            usesLiveSubtitle: false,
            now: snapshot.updatedAt))
        #expect(model.providerCost == nil)
        let balanceRows = model.providerDetails.flatMap(\.rows).filter { $0.label == "Balance" }
        #expect(balanceRows.count == 1)
        #expect(balanceRows.first?.value == expected)
        guard let path = ProcessInfo.processInfo.environment["CODEXBAR_XAPI_SCREENSHOT_DIR"] else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let view = AnyView(UsageMenuCardView(model: model, width: 360)
            .environment(\.locale, Locale(identifier: "en_US_POSIX"))
            .environment(\.colorScheme, .light)
            .environment(\.displayScale, 2)
            .background(Color(nsColor: .windowBackgroundColor)))
        let hosting = NSHostingView(rootView: view)
        hosting.appearance = NSAppearance(named: .aqua)
        try #require(MenuLayoutScreenshotRenderTests.pngDataWithWindow(hosting: hosting))
            .write(to: directory.appendingPathComponent("xapi-\(balance).png"))
    }
}
