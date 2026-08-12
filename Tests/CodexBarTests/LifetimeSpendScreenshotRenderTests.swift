import AppKit
import CodexBarCore
import SwiftUI
import Testing
@testable import CodexBar

/// Opt-in documentation renderer for the All Time dashboard and its share card.
///
/// Run with:
///   CODEXBAR_LIFETIME_PROOF_DIR=docs/screenshots/lifetime-spend-proof \
///     swift test --filter LifetimeSpendScreenshotRenderTests
@MainActor
struct LifetimeSpendScreenshotRenderTests {
    private static let dashboardSize = CGSize(width: 900, height: 1370)
    private static let periodStart = Self.date(year: 2025, month: 8, day: 1)
    private static let periodEnd = Self.date(year: 2026, month: 8, day: 12)

    @Test
    func `all time production views render synthetic privacy safe proof`() throws {
        let model = Self.dashboardModel
        let dashboardData = try #require(Self.pngData(
            for: Self.dashboardView(model: model),
            size: Self.dashboardSize))
        let dashboardBitmap = try #require(NSBitmapImageRep(data: dashboardData))
        #expect(dashboardBitmap.pixelsWide == Int(Self.dashboardSize.width * 2))
        #expect(dashboardBitmap.pixelsHigh == Int(Self.dashboardSize.height * 2))

        let payload = try #require(ShareStatsBuilder.make(model: model))
        let shareText = ShareStatsFormatting.text(payload)
        #expect(shareText.contains("available history since"))
        #expect(shareText.contains("377 covered days"))
        for forbidden in ["@", "/Users/", "akshay", "example.com", "fixture", "00000000"] {
            #expect(!shareText.localizedCaseInsensitiveContains(forbidden))
        }

        let shareData = try #require(ShareStatsRenderer.pngData(for: payload))
        let shareBitmap = try #require(NSBitmapImageRep(data: shareData))
        #expect(shareBitmap.pixelsWide == Int(ShareStatsCardView.size.width))
        #expect(shareBitmap.pixelsHigh == Int(ShareStatsCardView.size.height))

        guard let path = ProcessInfo.processInfo.environment["CODEXBAR_LIFETIME_PROOF_DIR"] else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try dashboardData.write(
            to: directory.appendingPathComponent("all-time-dashboard.png"),
            options: .atomic)
        try shareData.write(
            to: directory.appendingPathComponent("all-time-share-stats.png"),
            options: .atomic)
    }

    private static func dashboardView(model: SpendDashboardModel) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SpendDashboardHeader(
                    selectedRange: .allTime,
                    isRefreshing: false,
                    isCostTrackingEnabled: true,
                    selectRange: { _ in },
                    refresh: {})
                ForEach(model.groups) { group in
                    SpendCurrencySection(
                        group: group,
                        range: model.range,
                        requestedDays: model.requestedDays)
                }
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "lock.shield.fill")
                    Text("Local estimates · Available history starts when CodexBar begins tracking.")
                    Spacer()
                    Toggle("Track costs", isOn: .constant(true))
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(24)
        }
        .frame(width: self.dashboardSize.width, height: self.dashboardSize.height)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.colorScheme, .dark)
    }

    private static var dashboardModel: SpendDashboardModel {
        let points: [SpendDashboardModel.DailyPoint] = [
            self.point(
                sourceID: "codex-a",
                provider: .codex,
                name: "Codex",
                date: self.date(year: 2025, month: 8, day: 1),
                cost: 12),
            self.point(
                sourceID: "claude-a",
                provider: .claude,
                name: "Claude",
                date: self.date(year: 2025, month: 9, day: 16),
                cost: 18),
            self.point(
                sourceID: "codex-b",
                provider: .codex,
                name: "Codex",
                date: self.date(year: 2025, month: 11, day: 4),
                cost: 31),
            self.point(
                sourceID: "claude-b",
                provider: .claude,
                name: "Claude",
                date: self.date(year: 2026, month: 2, day: 10),
                cost: 27),
            self.point(
                sourceID: "codex-c",
                provider: .codex,
                name: "Codex",
                date: self.date(year: 2026, month: 5, day: 22),
                cost: 43),
            self.point(
                sourceID: "claude-c",
                provider: .claude,
                name: "Claude",
                date: self.date(year: 2026, month: 8, day: 12),
                cost: 46.15),
        ]
        let group = SpendDashboardModel.CurrencyGroup(
            currencyCode: "USD",
            providers: [
                SpendDashboardModel.ProviderRow(
                    id: "codex:proof",
                    rank: 1,
                    provider: .codex,
                    displayName: "Codex",
                    totalTokens: 230_000_000,
                    totalCost: 128.45,
                    coveredDayCount: 377,
                    coverageStart: self.periodStart),
                SpendDashboardModel.ProviderRow(
                    id: "claude:proof",
                    rank: 2,
                    provider: .claude,
                    displayName: "Claude",
                    totalTokens: 19_000_000,
                    totalCost: 48.70,
                    coveredDayCount: 377,
                    coverageStart: self.periodStart),
            ],
            models: [
                SpendDashboardModel.ModelRow(
                    rank: 1,
                    provider: .codex,
                    providerName: "Codex",
                    modelName: "gpt-5.4",
                    totalTokens: 230_000_000,
                    totalCost: 128.45),
                SpendDashboardModel.ModelRow(
                    rank: 2,
                    provider: .claude,
                    providerName: "Claude",
                    modelName: "claude-sonnet-4",
                    totalTokens: 19_000_000,
                    totalCost: 48.70),
            ],
            dailyPoints: points,
            totalTokens: 249_000_000,
            totalCost: 177.15,
            coveredDayCount: 377,
            chartDomain: self.periodStart...self.periodEnd,
            modelHistoryCompleteness: .complete)
        return SpendDashboardModel(
            range: .allTime,
            requestedDays: 377,
            groups: [group])
    }

    private static func point(
        sourceID: String,
        provider: UsageProvider,
        name: String,
        date: Date,
        cost: Double) -> SpendDashboardModel.DailyPoint
    {
        SpendDashboardModel.DailyPoint(
            sourceID: sourceID,
            provider: provider,
            providerName: name,
            day: date,
            cost: cost,
            stackStart: 0,
            stackEnd: cost)
    }

    private static func date(year: Int, month: Int, day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    private static func pngData(for rootView: some View, size: CGSize) -> Data? {
        let view = NSHostingView(rootView: rootView)
        view.appearance = NSAppearance(named: .darkAqua)
        view.frame = CGRect(origin: .zero, size: size)
        view.layoutSubtreeIfNeeded()

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
        view.displayIgnoringOpacity(view.bounds, in: context)
        return representation.representation(using: .png, properties: [:])
    }
}
