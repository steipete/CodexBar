import AppKit
import Foundation
import SwiftUI
import Testing
@testable import CodexBar
@testable import CodexBarCLI
@testable import CodexBarCore

/// The card is where the calendar-cycle resolution has to land. `ProviderPaceCapability` exposing the
/// right duration is not enough on its own: the card is also handed a precomputed `weeklyPace`, and
/// preferring it would score the billing period as a flat 30 days while the CLI scored the real month.
struct NotionMenuCardModelTests {
    /// 2026-02-08T00:00:00Z — 21 days before the cycle ends, 7 days into a 28-day February.
    private static let now = Date(timeIntervalSince1970: 1_770_508_800)
    /// 2026-03-01T00:00:00Z.
    private static let periodEnd = Date(timeIntervalSince1970: 1_772_323_200)

    private static func snapshot() -> UsageSnapshot {
        UsageSnapshot(
            primary: RateWindow(
                usedPercent: 50,
                windowMinutes: 360,
                resetsAt: self.now.addingTimeInterval(3600),
                resetDescription: nil),
            secondary: RateWindow(
                usedPercent: 40,
                windowMinutes: 43200,
                resetsAt: self.periodEnd,
                resetDescription: nil),
            updatedAt: self.now)
    }

    private static func model(
        weeklyPace: UsagePace?,
        snapshot: UsageSnapshot? = Self.snapshot(),
        lastError: String? = nil,
        showOptional: Bool = true,
        now: Date = Self.now,
        hidePersonalInfo: Bool = false) throws -> UsageMenuCardView.Model
    {
        let metadata = try #require(ProviderDefaults.metadata[.notion])
        return UsageMenuCardView.Model.make(.init(
            provider: .notion,
            metadata: metadata,
            snapshot: snapshot,
            credits: nil,
            creditsError: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: lastError,
            usageBarsShowUsed: true,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: showOptional,
            hidePersonalInfo: hidePersonalInfo,
            weeklyPace: weeklyPace,
            now: now))
    }

    @Test
    func `monthly bar paces against February, not a flat thirty days`() throws {
        let monthly = try #require(Self.snapshot().secondary)
        // What the store hands the card: a pace measured against the raw 30-day sentinel. Reusing it
        // would report 30% expected (9 of 30 days) instead of 25% (7 of February's 28).
        let sentinelPace = try #require(UsagePace.weekly(
            window: monthly,
            now: Self.now,
            defaultWindowMinutes: 10080))
        #expect((sentinelPace.expectedUsedPercent * 10).rounded() / 10 == 30)

        let metric = try #require(try Self.model(weeklyPace: sentinelPace).metrics.first { $0.id == "secondary" })

        #expect(metric.pacePercent == 25)
        #expect(metric.detailLeftText == "15% in deficit")
    }

    @Test
    func `monthly pace is identical whether or not a precomputed pace is supplied`() throws {
        let monthly = try #require(Self.snapshot().secondary)
        let sentinelPace = UsagePace.weekly(window: monthly, now: Self.now, defaultWindowMinutes: 10080)

        let withPace = try #require(try Self.model(weeklyPace: sentinelPace).metrics.first { $0.id == "secondary" })
        let withoutPace = try #require(try Self.model(weeklyPace: nil).metrics.first { $0.id == "secondary" })

        #expect(withPace.pacePercent == withoutPace.pacePercent)
        #expect(withPace.detailLeftText == withoutPace.detailLeftText)
    }

    @Test
    func `rolling bar carries a session pace`() throws {
        let metric = try #require(try Self.model(weeklyPace: nil).metrics.first { $0.id == "primary" })

        // Five of the six rolling hours elapsed against 50% used.
        #expect(metric.detailLeftText == "33% in reserve")
    }

    @Test(arguments: ["7,850.5", "0", nil] as [String?])
    func `premium balance renders as a separate text section without a fabricated gauge`(balance: String?) throws {
        let base = Self.snapshot()
        let sections = try balance.map { value in
            try [ProviderDetailSection(title: "Notion Credits", rows: [
                .init(label: "Remaining credits", value: value),
            ])]
        } ?? []
        let snapshot = UsageSnapshot(
            primary: base.primary,
            secondary: base.secondary,
            details: sections,
            updatedAt: Self.now)
        let model = try Self.model(weeklyPace: nil, snapshot: snapshot)
        #expect(model.metrics.map(\.id) == ["primary", "secondary"])
        #expect(model.providerDetails.first?.title == (balance == nil ? nil : "Notion Credits"))
        #expect(model.providerDetails.first?.rows.first?.value == balance)
        #expect(model.providerDetails.first?.rows.first?.progress == nil)
        #expect(model.creditsText == nil)
        #expect(model.cloudCredits == nil)
        let hidden = try Self.model(weeklyPace: nil, snapshot: snapshot, showOptional: false)
        #expect(hidden.providerDetails.isEmpty)
        #expect(hidden.metrics.map(\.id) == model.metrics.map(\.id))
        let restored = try Self.model(weeklyPace: nil, snapshot: snapshot, showOptional: true)
        #expect(restored.providerDetails.first?.rows.first?.value == balance)
        let refreshedWithoutCredits = try Self.model(weeklyPace: nil, snapshot: base, showOptional: true)
        #expect(refreshedWithoutCredits.providerDetails.isEmpty)
    }

    @Test
    func `personal pools retain independent pace with the production precomputed weekly pace`() throws {
        let standard = RateWindow(
            usedPercent: 80,
            windowMinutes: 43200,
            resetsAt: Self.periodEnd,
            resetDescription: nil,
            title: "Standard")
        let select = RateWindow(
            usedPercent: 0,
            windowMinutes: 43200,
            resetsAt: Self.periodEnd,
            resetDescription: nil,
            title: "Select")
        let snapshot = UsageSnapshot(primary: standard, secondary: select, updatedAt: Self.now)
        let descriptor = NotionProviderDescriptor.descriptor
        let weekly = try #require(descriptor.presentation.semanticWindows(snapshot: snapshot).weekly)
        // Match UsageStore.menuCardInput: precompute pace from the descriptor's semantic weekly window.
        let precomputed = UsagePace.weekly(
            window: descriptor.pace.resolvedResetWindowForPace(weekly),
            now: Self.now,
            defaultWindowMinutes: 10080)
        let model = try Self.model(weeklyPace: precomputed, snapshot: snapshot)
        let standardMetric = try #require(model.metrics.first { $0.id == "primary" })
        let selectMetric = try #require(model.metrics.first { $0.id == "secondary" })
        #expect(weekly == select)
        #expect(standardMetric.detailLeftText == "50% in deficit")
        #expect(selectMetric.detailLeftText == "30% in reserve")
        #expect(selectMetric.detailRightText?.hasPrefix("Lasts until reset") == true)
        #expect(selectMetric.pacePercent == 30)
    }

    @Test
    func `personal monthly labels and pace use the exact server duration even at the legacy sentinel`() throws {
        let standard = RateWindow(
            usedPercent: 20,
            windowMinutes: 43200,
            resetsAt: Self.periodEnd,
            resetDescription: nil,
            quotaLimit: 1500,
            quotaUnit: "credits",
            title: "Standard")
        let select = RateWindow(
            usedPercent: 0,
            windowMinutes: 43200,
            resetsAt: Self.periodEnd,
            resetDescription: nil,
            quotaLimit: 500,
            quotaUnit: "credits",
            title: "Select")
        let snapshot = try UsageSnapshot(
            primary: standard,
            secondary: select,
            details: [
                ProviderDetailSection(title: "Personal credits", rows: [
                    .init(label: "Standard remaining", value: "1,200 credits"),
                    .init(label: "Select remaining", value: "500 credits"),
                ]),
                ProviderDetailSection(title: "Notion Credits", rows: [
                    .init(label: "Remaining credits", value: "300"),
                ]),
            ], updatedAt: Self.now)
        let model = try Self.model(weeklyPace: nil, snapshot: snapshot)
        #expect(model.metrics.map(\.title) == ["Standard", "Select"])
        // This server interval starts January 30. Inferring February would incorrectly yield 25%.
        #expect(model.metrics.map(\.pacePercent) == [30, 30])
        let labels = MenuBarLayoutLaneLabels(provider: .notion, snapshot: snapshot)
        #expect(labels.primary == "Standard")
        #expect(labels.secondary == "Select")
        #expect(MenuBarPercentWindowPreference.session.label(for: .notion, snapshot: snapshot) == "Rolling")
        #expect(MenuBarLayoutSemanticWindowResolver.windows(provider: .notion, snapshot: snapshot).session == nil)
        #expect(MenuBarLayoutBalanceResolver.balance(provider: .notion, snapshot: snapshot) == "300")
        #expect(MenuBarLayoutBalanceResolver.legacyBalance(provider: .notion, snapshot: snapshot) == nil)
        let hidden = try Self.model(weeklyPace: nil, snapshot: snapshot, showOptional: false)
        #expect(hidden.metrics.map(\.title) == model.metrics.map(\.title))
        #expect(hidden.providerDetails.map(\.title) == ["Personal credits"])
        #expect(MenuBarLayoutBalanceResolver.balance(
            provider: .notion, snapshot: snapshot, showsOptionalCredits: false) == nil)
    }

    @MainActor
    @Test
    func `captured allowances flow through the production strategy card and CLI payload`() async throws {
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Providers/Notion")
        let spaces = try Data(contentsOf: fixtures.appendingPathComponent("get-spaces.json"))
        let allowances = try Data(contentsOf: fixtures
            .appendingPathComponent("get-credit-rate-limit-status-migrated.json"))
        let workspace = "11111111-2222-3333-4444-555555555555"
        let strategy = NotionProviderDescriptor.webStrategy(transport: ProviderHTTPTransportHandler { request in
            let endpoint = try #require(request.url?.lastPathComponent)
            #expect(request.value(forHTTPHeaderField: "Cookie") == "token_v2=synthetic-preview")
            let body: Data
            if endpoint == "getSpaces" {
                body = spaces
            } else {
                #expect(try JSONDecoder().decode([String: String].self, from: #require(request.httpBody))
                    == ["spaceId": workspace])
                body = endpoint == "getCreditRateLimitStatus"
                    ? allowances : Data(#"{"premiumCredits":{"totalCreditBalance":300}}"#.utf8)
            }
            let url = try #require(request.url)
            return try (body, #require(HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
        })
        let directory = ProcessInfo.processInfo.environment["CODEXBAR_NOTION_CARD_PROOF_DIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let directory {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let now = Date(timeIntervalSince1970: 1_794_585_600)
        var previews: [UsageMenuCardView.Model] = []
        for optional in [true, false] {
            let context = ProviderFetchContext(
                runtime: .app,
                sourceMode: .web,
                includeCredits: false,
                includeOptionalUsage: optional,
                webTimeout: 15,
                webDebugDumpHTML: false,
                verbose: false,
                env: [:],
                settings: .make(notion: .init(
                    cookieSource: .manual, manualCookieHeader: "token_v2=synthetic-preview", workspaceID: workspace)),
                fetcher: UsageFetcher(environment: [:]),
                claudeFetcher: ClaudeUsageFetcher(browserDetection: BrowserDetection()),
                browserDetection: BrowserDetection())
            let usage = try await strategy.fetch(context).usage
            // Replay captured values with a stable presentation clock; allowance fields stay unchanged.
            let snapshot = UsageSnapshot(
                primary: usage.primary,
                secondary: usage.secondary,
                details: usage.details,
                updatedAt: now,
                identity: usage.identity)
            let descriptor = NotionProviderDescriptor.descriptor
            let pace = descriptor.presentation.semanticWindows(snapshot: snapshot).weekly.flatMap {
                UsagePace.weekly(window: descriptor.pace.resolvedResetWindowForPace($0), now: now)
            }
            let model = try Self.model(
                weeklyPace: pace, snapshot: snapshot, showOptional: optional, now: now, hidePersonalInfo: true)
            #expect(model.metrics.map(\.title) == ["Standard", "Select"])
            #expect(snapshot.detailRow(label: "Standard remaining")?.usageValue == 134.66869)
            #expect(snapshot.secondary?.quotaLimit == 500)
            #expect(snapshot.detailRow(label: "Remaining credits")?.value == (optional ? "300" : nil))
            #expect(model.providerDetails.map(\.title) == (optional
                    ? ["Personal credits", "Notion Credits"] : ["Personal credits"]))
            let payload = ProviderPayload(
                providerID: "notion",
                account: nil,
                version: nil,
                source: "fixture",
                status: nil,
                usage: snapshot,
                credits: nil,
                antigravityPlanInfo: nil,
                openaiDashboard: nil,
                error: nil)
            #expect(payload.rateWindowLabels?.primary == "Standard")
            #expect(payload.rateWindowLabels?.secondary == "Select")
            let text = CLIRenderer.renderText(
                provider: .notion,
                snapshot: snapshot,
                credits: nil,
                context: RenderContext(
                    header: "Notion AI", status: nil, useColor: false, resetStyle: .countdown),
                now: now)
            #expect(text.contains("Standard:"))
            #expect(text.contains("Select:"))
            #expect(text.contains("Remaining credits: 300") == optional)
            previews.append(model)
            if let directory {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                try encoder.encode(payload).write(to: directory.appendingPathComponent(
                    optional ? "notion-optional-on.json" : "notion-optional-off.json"))
                try text.write(
                    to: directory
                        .appendingPathComponent(optional ? "notion-optional-on.txt" : "notion-optional-off.txt"),
                    atomically: true,
                    encoding: .utf8)
            }
        }
        guard let directory else { return }
        let before = try Self.model(
            weeklyPace: nil,
            snapshot: nil,
            lastError: "Notion AI usage allowance is not tracked for this workspace.",
            now: now,
            hidePersonalInfo: true)
        let renderer = ImageRenderer(content: VStack(alignment: .leading, spacing: 16) {
            Text("Notion AI · captured-response preview").font(.headline)
            Text("Fixture session; no live account access").font(.caption)
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading) {
                    Text("Before").font(.subheadline)
                    UsageMenuCardView(model: before, width: 360)
                }
                VStack(alignment: .leading) {
                    Text("Optional usage on").font(.subheadline)
                    UsageMenuCardView(model: previews[0], width: 360)
                }
                VStack(alignment: .leading) {
                    Text("Optional usage off").font(.subheadline)
                    UsageMenuCardView(model: previews[1], width: 360)
                }
            }
        }.padding(20).background(Color(nsColor: .windowBackgroundColor))
            .environment(\.locale, Locale(identifier: "en"))
            .environment(\.colorScheme, .light))
        renderer.scale = 2
        let bitmap = try NSBitmapImageRep(cgImage: #require(renderer.cgImage))
        try #require(bitmap.representation(using: .png, properties: [:])).write(
            to: directory.appendingPathComponent("notion-three-credit-pools.png"))
    }
}

@MainActor
struct NotionLocalizationTests {
    @Test
    func `personal credit labels and units localize without changing amounts`() throws {
        let section = try ProviderDetailSection(title: "Personal credits", rows: [
            .init(label: "Standard remaining", value: "1,365.33 credits", secondaryValue: "134.67 / 1,500 used"),
        ])
        let localized = CodexBarLocalizationOverride.$appLanguage.withValue("it") {
            UsageMenuCardView.Model.localizedProviderDetails([section], provider: .notion)
        }
        let row = try #require(localized.first?.rows.first)
        #expect(localized.first?.title == "Crediti personali")
        #expect(row.label == "Standard rimanente")
        #expect(row.value == "1,365.33 crediti")
        #expect(row.secondaryValue != "134.67 / 1,500 used")
        #expect(row.secondaryValue?.contains("134.67 / 1,500") == true)
    }
}
