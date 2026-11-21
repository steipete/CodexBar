import AppKit
import Foundation
import SwiftUI
import Testing
@testable import CodexBar
@testable import CodexBarCLI
@testable import CodexBarCore

@MainActor
struct TrustedRouterProviderTests {
    @Test
    func `TrustedRouter is an opt in key limit provider using the shared API key field`() throws {
        let descriptor = TrustedRouterProviderDescriptor.descriptor
        #expect(!descriptor.metadata.defaultEnabled)
        #expect(!descriptor.metadata.balanceOnly)
        #expect(descriptor.metadata.usesDetailBackedWindow)
        #expect(!descriptor.metadata.burnDownWidgetSelectable)
        #expect(descriptor.fetchPlan.sourceModes == [.auto, .api])
        #expect(!descriptor.tokenCost.supportsTokenCost)
        #expect(descriptor.history == .unavailable)
        #expect(ProviderSelection(argument: "trustedrouter")?.asList == [.trustedrouter])
        let credentials = try #require(descriptor.credentials)
        let environment = credentials.applyConfig(
            base: ["TRUSTEDROUTER_API_KEY": "environment-fixture"],
            config: ProviderConfig(id: .trustedrouter, apiKey: "tr_fixture"))
        #expect(environment["TRUSTEDROUTER_API_KEY"] == "tr_fixture")
        #expect(credentials.resolveToken(environment: environment)?.token == "tr_fixture")
        let values = try #require(TrustedRouterProviderDescriptor.spec.scriptValues(
            ProviderCutoverTestSupport.context(environment: ["TRUSTEDROUTER_API_KEY": "tr_fixture"])))
        let encoded = try #require(values.settings["MESSAGES"]?.data(using: .utf8))
        let messages = try JSONDecoder().decode([String: String].self, from: encoded)
        #expect(Set(messages.keys) == Set(TrustedRouterProviderDescriptor.diagnosticMessages))
        for message in TrustedRouterProviderDescriptor.diagnosticMessages {
            #expect(messages[message] == UsageFormatter.localized(message))
            #expect(L(message, language: "it") != message)
        }
        let fixture = try ProviderSettingsDescriptorTests().makeSettingsFixture(suite: "TrustedRouterProviderTests")
        let implementation = try #require(ProviderCatalog.implementation(for: .trustedrouter))
        #expect(!implementation.isAvailable(context: .init(
            provider: .trustedrouter, settings: fixture.settings, environment: [:])))
        let fields = implementation.settingsFields(context: fixture.settingsContext(provider: .trustedrouter))
        #expect(fields.map(\.id) == ["trustedrouter-api-key"])
        #expect(fields.map(\.kind) == [.secure])
        fields[0].binding.wrappedValue = "tr_fixture"
        #expect(fixture.settings.providerConfig(for: .trustedrouter)?.apiKey == "tr_fixture")
        #expect(implementation.isAvailable(context: .init(
            provider: .trustedrouter, settings: fixture.settings, environment: [:])))
    }

    @Test
    func `key limit meter keeps amounts without reset text or monthly pace`() throws {
        let now = Date(timeIntervalSince1970: 1_792_540_800)
        let snapshot = try UsageSnapshot(
            primary: RateWindow(
                usedPercent: 34, windowMinutes: nil, resetsAt: nil, resetDescription: "$3.40 / $10.00"),
            secondary: nil,
            details: [ProviderDetailSection(title: "Usage", rows: [.init(label: "Remaining", value: "$6.60")])],
            updatedAt: now)
        func card(_ value: UsageSnapshot?) throws -> UsageMenuCardView.Model {
            try UsageMenuCardView.Model.make(.init(
                provider: .trustedrouter,
                metadata: #require(ProviderDefaults.metadata[.trustedrouter]),
                snapshot: value,
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
                hidePersonalInfo: false,
                paceVisible: true,
                now: now))
        }
        let model = try card(snapshot)
        #expect(model.metrics.count == 1)
        #expect(model.metrics.first?.title == "Limit")
        #expect(model.metrics.first?.percent == 34)
        #expect(model.metrics.first?.detailText == "$3.40 / $10.00")
        #expect(model.metrics.first?.resetText == nil)
        #expect(model.metrics.first?.pacePercent == nil)
        #expect(model.providerCost == nil)

        let text = CLIRenderer.renderText(
            provider: .trustedrouter,
            snapshot: snapshot,
            credits: nil,
            context: RenderContext(header: "TrustedRouter", status: nil, useColor: false, resetStyle: .countdown),
            now: now)
        #expect(text.contains("$3.40 / $10.00"))
        #expect(!text.contains("Resets $"))
        guard let directory = ProcessInfo.processInfo.environment["CODEXBAR_TRUSTEDROUTER_PROOF_DIR"] else { return }
        for after in [false, true] {
            let preview = try card(after ? snapshot : nil)
            let renderer = ImageRenderer(content: UsageMenuCardView(model: preview, width: 380)
                .environment(\.locale, Locale(identifier: "en_US_POSIX"))
                .environment(\.colorScheme, .light).background(Color.white))
            renderer.scale = 2
            let bitmap = try NSBitmapImageRep(cgImage: #require(renderer.cgImage))
            try #require(bitmap.representation(using: .png, properties: [:])).write(
                to: URL(fileURLWithPath: directory)
                    .appendingPathComponent(after ? "trustedrouter-after.png" : "trustedrouter-before.png"))
        }
    }
}
