import AppKit
import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct ShareStatsModelSharesTests {
    private static func payload(
        tokens: [Int?],
        hasPartialModels: Bool = false,
        currencies: [ShareStatsCurrencyPayload] = [
            ShareStatsCurrencyPayload(currencyCode: "USD", estimatedCost: 10, coveredDayCount: 30),
        ]) -> ShareStatsPayload
    {
        ShareStatsPayload(
            days: 30,
            periodEnd: Date(timeIntervalSince1970: 1_793_000_000),
            providers: [ShareStatsProviderPayload(
                provider: .claude,
                providerName: "Claude",
                subscriptionName: "Max",
                currencyCode: "USD",
                totalTokens: 100,
                estimatedCost: 10,
                coveredDayCount: 30)],
            topModels: tokens.enumerated().map { index, tokens in
                ShareStatsModelPayload(
                    provider: .claude,
                    providerName: "Claude",
                    modelName: "Model \(index)",
                    currencyCode: "USD",
                    totalTokens: tokens,
                    estimatedCost: nil)
            },
            currencies: currencies,
            totalTokens: 100,
            hasPartialModels: hasPartialModels)
    }

    @Test
    func `shares divide by every ranked family including rows the card cannot show`() throws {
        let shares = ShareStatsModelShares.make(Self.payload(tokens: [50, 20, 10, 10, 5, 5]))

        #expect(shares == [0.5, 0.2, 0.1, 0.1, 0.05, 0.05])
        let shownShare = try #require(shares).prefix(4).reduce(0, +)
        #expect(abs(shownShare - 0.9) < 1e-9)
    }

    @Test
    func `partial rankings and missing counts withhold shares`() {
        #expect(ShareStatsModelShares.make(Self.payload(tokens: [50, 50], hasPartialModels: true)) == nil)
        #expect(ShareStatsModelShares.make(Self.payload(tokens: [50, nil])) == nil)
        #expect(ShareStatsModelShares.make(Self.payload(tokens: [0, 0])) == nil)
        #expect(ShareStatsModelShares.make(Self.payload(tokens: [])) == nil)
    }

    @Test @MainActor
    func `roll call names each plan once`() {
        func provider(_ name: String, plan: String?) -> ShareStatsProviderPayload {
            ShareStatsProviderPayload(
                provider: .claude,
                providerName: name,
                subscriptionName: plan,
                currencyCode: "USD",
                totalTokens: 1,
                estimatedCost: nil,
                coveredDayCount: 1)
        }
        #expect(ShareStatsCardView.rollCallName(provider("Claude", plan: "Max")) == "Claude Max")
        #expect(ShareStatsCardView.rollCallName(provider("Cursor", plan: "Cursor Pro")) == "Cursor Pro")
        #expect(ShareStatsCardView.rollCallName(provider("Codex", plan: nil)) == "Codex")
    }

    @Test
    func `share text keeps small shares visible`() {
        CodexBarLocalizationOverride.$appLanguage.withValue("en") {
            #expect(ShareStatsModelShares.text(0.47) == "47%")
            #expect(ShareStatsModelShares.text(0.004) == "0.4%")
        }
    }

    @Test @MainActor
    func `spend leads only when it is one complete figure`() {
        let usd = ShareStatsCurrencyPayload(currencyCode: "USD", estimatedCost: 10, coveredDayCount: 30)
        #expect(ShareStatsCardView.hero(for: Self.payload(tokens: [1])) == .spend(usd))

        let partial = ShareStatsCurrencyPayload(
            currencyCode: "USD",
            estimatedCost: 10,
            coveredDayCount: 30,
            isPartial: true)
        let shortCoverage = ShareStatsCurrencyPayload(currencyCode: "USD", estimatedCost: 10, coveredDayCount: 12)
        let gbp = ShareStatsCurrencyPayload(currencyCode: "GBP", estimatedCost: 4, coveredDayCount: 30)
        let unavailable = ShareStatsCurrencyPayload(currencyCode: "USD", estimatedCost: nil, coveredDayCount: 30)
        for currencies in [[partial], [shortCoverage], [usd, gbp], [unavailable], []] {
            #expect(ShareStatsCardView.hero(for: Self.payload(tokens: [1], currencies: currencies)) == .tokens)
        }
    }

    @Test @MainActor
    func `exported card follows the requested appearance on neutral surfaces`() throws {
        let payload = Self.payload(tokens: [60, 40])
        let light = try #require(ShareStatsRenderer.pngData(for: payload, appearance: NSAppearance(named: .aqua)))
        let dark = try #require(ShareStatsRenderer.pngData(for: payload, appearance: NSAppearance(named: .darkAqua)))

        func corner(_ data: Data) throws -> (Double, Double, Double) {
            let bitmap = try #require(NSBitmapImageRep(data: data))
            let color = try #require(bitmap.colorAt(x: 4, y: 4)?.usingColorSpace(.sRGB))
            return (color.redComponent, color.greenComponent, color.blueComponent)
        }
        let lightCorner = try corner(light)
        let darkCorner = try corner(dark)

        #expect(lightCorner.0 > 0.95 && lightCorner.1 > 0.95 && lightCorner.2 > 0.95)
        #expect(darkCorner.0 < 0.15)
        // Neutral graphite: no warm cast (the rejected card's black had red > green > blue).
        #expect(abs(darkCorner.0 - darkCorner.2) < 0.01)
    }

    @Test
    func `a zero share draws no sliver while tiny shares stay visible`() {
        #expect(ShareStatsShareBar.fillWidth(share: 0, trackWidth: 400) == 0)
        #expect(ShareStatsShareBar.fillWidth(share: 0.001, trackWidth: 400) == 4)
        #expect(ShareStatsShareBar.fillWidth(share: 0.5, trackWidth: 400) == 200)
        #expect(ShareStatsShareBar.fillWidth(share: 2, trackWidth: 400) == 400)
    }

    @Test
    func `rank numbers follow the card locale's digits`() {
        CodexBarLocalizationOverride.$appLanguage.withValue("en") {
            #expect(ShareStatsModelRow.rankText(1) == "01")
            #expect(ShareStatsModelRow.rankText(12) == "12")
        }
        CodexBarLocalizationOverride.$appLanguage.withValue("ar") {
            #expect(ShareStatsModelRow.rankText(1) == "٠١")
        }
    }
}
