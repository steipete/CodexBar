import AppKit
import CodexBarCore
import SwiftUI
import XCTest
@testable import CodexBar

/// Opt-in renderer for reviewer-facing Overview allocation proof.
///
/// All values are synthetic. The output uses the production summary and provider-row views.
///
/// Run with a full Xcode toolchain:
///   CODEXBAR_OVERVIEW_ALLOCATION_PROOF_DIR=docs/screenshots/spend-dashboard-proof \
///     swift test --filter OverviewTokenAllocationScreenshotTests
@MainActor
final class OverviewTokenAllocationScreenshotTests: XCTestCase {
    private static let menuWidth: CGFloat = 310
    private static let requestedDays = 30

    func test_renderOverviewTokenAllocationProof() throws {
        guard let directoryPath = ProcessInfo.processInfo.environment[
            "CODEXBAR_OVERVIEW_ALLOCATION_PROOF_DIR",
        ]
        else {
            throw XCTSkip("Set CODEXBAR_OVERVIEW_ALLOCATION_PROOF_DIR to render proof screenshots.")
        }

        let directory = URL(fileURLWithPath: directoryPath, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let scenarios: [(String, [ProofProvider])] = [
            ("overview-token-allocation-complete", Self.completeProviders),
            ("overview-token-allocation-partial-long-roster", Self.partialLongRosterProviders),
            ("overview-token-allocation-native-currencies", Self.nativeCurrencyProviders),
        ]

        for (name, providers) in scenarios {
            let model = Self.spendModel(providers: providers)
            let summary = OverviewSpendSummary(
                model: model,
                trackedProviders: providers.map(\.provider))
            let view = AnyView(Self.proofMenu(
                providers: providers,
                summary: summary,
                days: model.requestedDays))
            let data = try XCTUnwrap(Self.pngData(for: view), "render failed for \(name)")
            let url = directory.appendingPathComponent("\(name).png")
            try data.write(to: url, options: .atomic)
            print("Wrote \(url.path)")
        }
    }

    private struct ProofProvider {
        let provider: UsageProvider
        let displayName: String
        let plan: String
        let tokens: Int?
        let cost: Double?
        let currencyCode: String
        let coveredDayCount: Int
        let metricTitle: String
        let metricPercent: Double
    }

    private static let completeProviders: [ProofProvider] = [
        .init(
            provider: .codex,
            displayName: "Codex",
            plan: "Pro 20x",
            tokens: 4_820_000,
            cost: 412.64,
            currencyCode: "USD",
            coveredDayCount: 30,
            metricTitle: "Monthly",
            metricPercent: 28),
        .init(
            provider: .openrouter,
            displayName: "OpenRouter",
            plan: "Research",
            tokens: 9_640_000,
            cost: 282.74,
            currencyCode: "USD",
            coveredDayCount: 30,
            metricTitle: "Credits",
            metricPercent: 64),
        .init(
            provider: .cursor,
            displayName: "Cursor",
            plan: "Work",
            tokens: 1_250_000,
            cost: 64.18,
            currencyCode: "USD",
            coveredDayCount: 30,
            metricTitle: "Total",
            metricPercent: 24),
    ]

    private static let partialLongRosterProviders: [ProofProvider] = [
        .init(
            provider: .codex,
            displayName: "Codex",
            plan: "Pro 20x",
            tokens: 4_820_000,
            cost: 412.64,
            currencyCode: "USD",
            coveredDayCount: 30,
            metricTitle: "Monthly",
            metricPercent: 28),
        .init(
            provider: .claude,
            displayName: "Claude",
            plan: "Team",
            tokens: 3_750_000,
            cost: nil,
            currencyCode: "USD",
            coveredDayCount: 8,
            metricTitle: "Session",
            metricPercent: 39),
        .init(
            provider: .openrouter,
            displayName: "OpenRouter",
            plan: "Research",
            tokens: 9_640_000,
            cost: 282.74,
            currencyCode: "USD",
            coveredDayCount: 30,
            metricTitle: "Credits",
            metricPercent: 64),
        .init(
            provider: .cursor,
            displayName: "Cursor",
            plan: "Work",
            tokens: 1_250_000,
            cost: 64.18,
            currencyCode: "USD",
            coveredDayCount: 30,
            metricTitle: "Total",
            metricPercent: 24),
        .init(
            provider: .gemini,
            displayName: "Gemini",
            plan: "Studio",
            tokens: nil,
            cost: nil,
            currencyCode: "USD",
            coveredDayCount: 0,
            metricTitle: "Pro",
            metricPercent: 7),
        .init(
            provider: .grok,
            displayName: "Grok",
            plan: "Personal",
            tokens: nil,
            cost: nil,
            currencyCode: "USD",
            coveredDayCount: 0,
            metricTitle: "Monthly",
            metricPercent: 52),
    ]

    private static let nativeCurrencyProviders: [ProofProvider] = [
        .init(
            provider: .codex,
            displayName: "Codex",
            plan: "USD workspace",
            tokens: 2_000_000,
            cost: 10,
            currencyCode: "USD",
            coveredDayCount: 30,
            metricTitle: "Monthly",
            metricPercent: 28),
        .init(
            provider: .claude,
            displayName: "Claude",
            plan: "EUR workspace",
            tokens: 1_000_000,
            cost: 7,
            currencyCode: "EUR",
            coveredDayCount: 30,
            metricTitle: "Session",
            metricPercent: 39),
        .init(
            provider: .openrouter,
            displayName: "OpenRouter",
            plan: "Tiny rate",
            tokens: 8_000_000,
            cost: 0.039,
            currencyCode: "USD",
            coveredDayCount: 30,
            metricTitle: "Credits",
            metricPercent: 64),
    ]

    private static func spendModel(providers: [ProofProvider]) -> SpendDashboardModel {
        let groups = Dictionary(grouping: providers, by: \.currencyCode)
            .map { currencyCode, groupProviders in
                let rows = groupProviders.enumerated().map { index, provider in
                    SpendDashboardModel.ProviderRow(
                        id: "proof-\(provider.provider.rawValue)",
                        rank: index + 1,
                        provider: provider.provider,
                        displayName: provider.displayName,
                        totalTokens: provider.tokens,
                        totalCost: provider.cost,
                        coveredDayCount: provider.coveredDayCount)
                }
                let allTokensKnown = rows.allSatisfy { $0.totalTokens != nil }
                let allCostsKnown = rows.allSatisfy { $0.totalCost != nil }
                return SpendDashboardModel.CurrencyGroup(
                    currencyCode: currencyCode,
                    providers: rows,
                    models: [],
                    dailyPoints: [],
                    totalTokens: allTokensKnown ? rows.compactMap(\.totalTokens).reduce(0, +) : nil,
                    totalCost: allCostsKnown ? rows.compactMap(\.totalCost).reduce(0, +) : nil,
                    coveredDayCount: rows.map(\.coveredDayCount).min() ?? 0,
                    chartDomain: Date(timeIntervalSince1970: 1_783_036_800)...Date(
                        timeIntervalSince1970: 1_785_628_800),
                    modelHistoryCompleteness: rows.allSatisfy {
                        $0.coveredDayCount >= Self.requestedDays
                    } ? .complete : .incomplete)
            }
            .sorted { $0.currencyCode < $1.currencyCode }
        return SpendDashboardModel(requestedDays: Self.requestedDays, groups: groups)
    }

    private static func proofMenu(
        providers: [ProofProvider],
        summary: OverviewSpendSummary,
        days: Int) -> some View
    {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.shield")
                Text("SYNTHETIC DATA · PRODUCTION COMPONENTS")
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            OverviewSpendSummaryCardView(
                summary: summary,
                days: days,
                width: Self.menuWidth,
                canShare: true,
                share: {})

            Divider().padding(.horizontal, 10)

            ForEach(Array(providers.enumerated()), id: \.offset) { index, provider in
                OverviewMenuCardRowView(
                    model: Self.menuModel(provider),
                    storageText: nil,
                    width: Self.menuWidth,
                    emphasis: index == 0 ? .prominent : .compact)
            }

            Divider().padding(.horizontal, 10)
            HStack(spacing: 8) {
                Image(systemName: "arrow.clockwise")
                Text("Refresh")
                Spacer()
                Text("⌘ R").foregroundStyle(.secondary)
            }
            .font(.body)
            .padding(.horizontal, 16)
            .frame(height: 38)
        }
        .frame(width: self.menuWidth)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.locale, Locale(identifier: "en_US"))
    }

    private static func menuModel(_ provider: ProofProvider) -> UsageMenuCardView.Model {
        let costText = provider.cost.map {
            UsageFormatter.currencyString($0, currencyCode: provider.currencyCode)
        }
        let metric = UsageMenuCardView.Model.Metric(
            id: "proof-metric",
            title: provider.metricTitle,
            percent: provider.metricPercent,
            percentStyle: .left,
            resetText: "Resets in 3d",
            detailText: nil,
            detailLeftText: nil,
            detailRightText: nil,
            pacePercent: nil,
            paceOnTop: true)
        return UsageMenuCardView.Model(
            provider: provider.provider,
            providerName: provider.displayName,
            email: "",
            subtitleText: "Synthetic fixture",
            subtitleStyle: provider.coveredDayCount > 0 ? .info : .error,
            planText: provider.plan,
            metrics: [metric],
            usageNotes: [],
            openAIAPIUsage: nil,
            inlineUsageDashboard: nil,
            creditsText: nil,
            creditsRemaining: nil,
            creditsProgressPercent: nil,
            creditsScaleText: nil,
            creditsHintText: nil,
            creditsHintCopyText: nil,
            providerCost: costText.map {
                UsageMenuCardView.Model.ProviderCostSection(
                    title: "Tracked spend",
                    percentUsed: nil,
                    spendLine: "Last 30 days: \($0)",
                    percentLine: nil)
            },
            tokenUsage: nil,
            placeholder: nil,
            progressColor: UsageMenuCardView.Model.progressColor(for: provider.provider))
    }

    private static func pngData(for view: AnyView) -> Data? {
        let hosting = NSHostingView(rootView: view)
        hosting.appearance = NSAppearance(named: .darkAqua)
        let size = hosting.fittingSize
        guard size.width > 0, size.height > 0 else { return nil }
        hosting.frame = CGRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()

        let scale: CGFloat = 2
        guard let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * scale),
            pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0)
        else { return nil }
        representation.size = size
        guard let context = NSGraphicsContext(bitmapImageRep: representation) else { return nil }
        hosting.displayIgnoringOpacity(hosting.bounds, in: context)
        return representation.representation(using: .png, properties: [:])
    }
}
