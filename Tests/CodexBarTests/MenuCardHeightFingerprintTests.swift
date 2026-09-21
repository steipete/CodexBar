import SwiftUI
import Testing
@testable import CodexBar

struct MenuCardHeightFingerprintTests {
    @Test
    func `height fingerprint does not retain raw text fields`() {
        let model = Self.model()

        let fingerprint = model.heightFingerprint(section: "card")

        #expect(!fingerprint.contains("very-secret@example.com"))
        #expect(!fingerprint.contains("Secret Provider Name"))
        #expect(!fingerprint.contains("Secret Metric"))
        #expect(!fingerprint.contains("Secret note"))
    }

    @Test
    func `height fingerprint field distinguishes nil from empty string`() {
        let nilField = UsageMenuCardView.Model.heightFingerprintField("storage", nil)
        let emptyField = UsageMenuCardView.Model.heightFingerprintField("storage", "")

        #expect(nilField != emptyField)
    }

    @Test
    func `height fingerprint ignores content changes inside fixed metric lines`() {
        let left = Self.model(percent: 42, percentStyle: .left).heightFingerprint(section: "card")
        let used = Self.model(percent: 42, percentStyle: .used).heightFingerprint(section: "card")
        let changedPercent = Self.model(percent: 43, percentStyle: .left).heightFingerprint(section: "card")

        #expect(left == used)
        #expect(left == changedPercent)
    }

    @Test
    func `height fingerprint tracks wrapping metric text content`() {
        let bare = Self.model(statusText: nil).heightFingerprint(section: "card")
        let withReset = Self.model(statusText: nil, resetText: "Resets in 2h").heightFingerprint(section: "card")
        let withMeta = Self.model(statusText: nil, detailLeftText: "20% in reserve")
            .heightFingerprint(section: "card")
        let withChangedMeta = Self.model(statusText: nil, detailLeftText: "45% in deficit")
            .heightFingerprint(section: "card")
        let withFoldedForecast = Self.model(
            statusText: nil,
            detailLeftText: "20% in reserve",
            sessionEquivalentDetail: .init(
                leftText: "Est. 2 session quotas left",
                rightText: "6 windows until reset",
                accessibilityLabel: "Est. 2 session quotas left · 6 windows until reset"))
            .heightFingerprint(section: "card")

        #expect(bare != withReset)
        #expect(bare != withMeta)
        // Meta and reset rows can wrap to a second line, so any text change
        // must invalidate the cached height instead of reusing a short frame.
        #expect(withMeta != withChangedMeta)
        #expect(withMeta != withFoldedForecast)
    }

    @Test
    func `height fingerprint invalidates when wrapping text grows from short to long`() {
        let shortReset = Self.model(statusText: nil, resetText: "Resets in 2h")
            .heightFingerprint(section: "card")
        let widerTitle = Self.model(percent: 100, statusText: nil, resetText: "Resets in 2h")
            .heightFingerprint(section: "card")
        let longReset = Self.model(
            statusText: nil,
            resetText: "Resets tomorrow at 6:00 AM after a very long localized description")
            .heightFingerprint(section: "card")
        let shortMeta = Self.model(statusText: nil, detailLeftText: "On pace")
            .heightFingerprint(section: "card")
        let longMeta = Self.model(
            statusText: nil,
            detailLeftText: "Estimated 2 session quotas left with a generously long localized pace explanation")
            .heightFingerprint(section: "card")

        #expect(shortReset != widerTitle)
        #expect(shortReset != longReset)
        #expect(shortMeta != longMeta)
    }

    @Test
    func `height fingerprint tracks reset-credit inventory shape`() {
        let one = Self.model(resetCredits: LimitResetCreditsPresentation(
            text: "1 available",
            items: [.init(expiryText: "Expires in 1d", compactExpiryText: "1d")]))
        let two = Self.model(resetCredits: LimitResetCreditsPresentation(
            text: "2 available",
            items: [
                .init(expiryText: "Expires in 1d", compactExpiryText: "1d"),
                .init(expiryText: "No expiry", compactExpiryText: "No expiry"),
            ]))

        #expect(one.heightFingerprint(section: "card") != two.heightFingerprint(section: "card"))
    }

    private static func model(
        percent: Double = 42,
        percentStyle: UsageMenuCardView.Model.PercentStyle = .left,
        resetCredits: LimitResetCreditsPresentation? = nil,
        statusText: String? = "Secret status",
        resetText: String? = nil,
        detailLeftText: String? = nil,
        sessionEquivalentDetail: UsagePaceText.SessionEquivalentDetail? = nil) -> UsageMenuCardView.Model
    {
        UsageMenuCardView.Model(
            provider: .codex,
            providerName: "Secret Provider Name",
            email: "very-secret@example.com",
            subtitleText: "Signed in as very-secret@example.com",
            subtitleStyle: .info,
            planText: "Secret Plan",
            metrics: [
                .init(
                    id: "primary",
                    title: "Secret Metric",
                    percent: percent,
                    percentStyle: percentStyle,
                    statusText: statusText,
                    resetText: resetText,
                    detailText: nil,
                    detailLeftText: detailLeftText,
                    detailRightText: nil,
                    pacePercent: nil,
                    paceOnTop: true,
                    sessionEquivalentDetail: sessionEquivalentDetail),
            ],
            usageNotes: ["Secret note"],
            openAIAPIUsage: nil,
            inlineUsageDashboard: nil,
            creditsText: nil,
            creditsRemaining: nil,
            creditsProgressPercent: nil,
            creditsScaleText: nil,
            creditsHintText: nil,
            creditsHintCopyText: nil,
            limitResetCredits: resetCredits,
            providerCost: nil,
            tokenUsage: nil,
            placeholder: nil,
            progressColor: .blue)
    }
}
