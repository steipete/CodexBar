import AppKit
import Foundation
import SwiftUI
import Testing
@testable import CodexBar
@testable import CodexBarCLI
@testable import CodexBarCore

@MainActor
struct MiMoAPIIntegrationTests {
    @Test
    func `MiMo key and region settings project into a browser free API pipeline`() async throws {
        let fixture = try ProviderSettingsDescriptorTests().makeSettingsFixture(suite: "MiMoAPIIntegrationTests")
        let context = fixture.settingsContext(provider: .mimo)
        let implementation = MiMoProviderImplementation()
        let fields = implementation.settingsFields(context: context)
        try #require(fields.first { $0.id == "mimo-api-key" }).binding.wrappedValue = "tp-fixture"
        let region = try #require(implementation.settingsPickers(context: context).first { $0.id == "mimo-api-region" })
        #expect(region.binding.wrappedValue == "cn")
        region.binding.wrappedValue = "sgp"
        let config = try #require(fixture.settings.providerConfig(for: .mimo))
        let descriptor = MiMoProviderDescriptor.descriptor
        let credentials = try #require(descriptor.credentials)
        let environment = credentials.applyConfig(base: [:], config: config)
        #expect(environment["MIMO_API_KEY"] == "tp-fixture")
        #expect(environment["MIMO_TOKEN_PLAN_REGION"] == "sgp")
        let fetchContext = ProviderCutoverTestSupport.context(environment: environment)
        let strategies = await descriptor.fetchPlan.pipeline.resolveStrategies(fetchContext)
        #expect(strategies.map(\.id) == ["mimo.api"])
        #expect(await strategies[0].isAvailable(fetchContext))
        #expect(await !CodexBarCLI.sourceModeRequiresWebSupport(provider: .mimo, context: fetchContext))
        let values = try #require(MiMoProviderDescriptor.apiStrategy().resolveValues(fetchContext))
        #expect(values.settings["REGION"] == "sgp")
        #expect(values.secrets["MIMO_API_KEY"] == "tp-fixture")
        let messages = try JSONDecoder().decode(
            [String: String].self, from: Data(#require(values.settings["MESSAGES"]).utf8))
        #expect(Set(messages.keys) == Set(MiMoProviderDescriptor.diagnosticMessages))
        for message in MiMoProviderDescriptor.diagnosticMessages {
            #expect(L(message, language: "it") != message)
        }
        #expect(!strategies[0].shouldFallback(on: URLError(.userAuthenticationRequired), context: fetchContext))
        let cookies = await descriptor.fetchPlan.pipeline.resolveStrategies(ProviderCutoverTestSupport.context())
        #expect(cookies.map(\.id) == ["mimo.web", "mimo.local"])

        let result = try await MiMoProviderDescriptor.apiStrategy(transport: ProviderHTTPTransportHandler { request in
            #expect(request.url?.host == "token-plan-sgp.xiaomimimo.com")
            #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
            let body = #"""
            {"object":"token_plan","plan_code":"lite","period":{"end_at":"2026-12-11 23:59:59"},
             "quota":{"total_credits":4100000000,"used_credits":1400000000,"remaining_credits":2700000000}}
            """#
            let url = try #require(request.url)
            return try (Data(body.utf8), #require(HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
        }).fetch(fetchContext)
        #expect(result.sourceLabel == "api")
        #expect(result.usage.primary?.quotaLimit == 4_100_000_000)
        for after in [false, true] {
            let model = UsageMenuCardView.Model.make(.init(
                provider: .mimo,
                metadata: descriptor.metadata,
                snapshot: after ? result.usage : nil,
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
                sourceLabel: result.sourceLabel,
                hidePersonalInfo: true,
                paceVisible: false,
                now: result.usage.updatedAt))
            if after {
                #expect(model.usageNotes.isEmpty)
                #expect(model.creditsText == nil)
            }
            guard let directory = ProcessInfo.processInfo.environment["CODEXBAR_MIMO_API_PROOF_DIR"] else { continue }
            let renderer = ImageRenderer(content: UsageMenuCardView(model: model, width: 380)
                .environment(\.locale, Locale(identifier: "en_US_POSIX"))
                .environment(\.colorScheme, .light).background(Color.white))
            renderer.scale = 2
            let bitmap = try NSBitmapImageRep(cgImage: #require(renderer.cgImage))
            try #require(bitmap.representation(using: .png, properties: [:])).write(
                to: URL(fileURLWithPath: directory)
                    .appendingPathComponent(after ? "mimo-after.png" : "mimo-before.png"))
        }
    }
}
