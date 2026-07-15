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
    func `height fingerprint keeps cheap metric percent identity`() {
        let left = Self.model(percent: 42, percentStyle: .left).heightFingerprint(section: "card")
        let used = Self.model(percent: 42, percentStyle: .used).heightFingerprint(section: "card")
        let changedPercent = Self.model(percent: 43, percentStyle: .left).heightFingerprint(section: "card")

        #expect(left != used)
        #expect(left != changedPercent)
    }

    @Test
    func `height fingerprint tracks reset-credit inventory shape`() {
        let one = Self.model(resetCredits: CodexResetCreditsPresentation(
            text: "1 available",
            items: [.init(expiryText: "Expires in 1d", compactExpiryText: "1d")]))
        let two = Self.model(resetCredits: CodexResetCreditsPresentation(
            text: "2 available",
            items: [
                .init(expiryText: "Expires in 1d", compactExpiryText: "1d"),
                .init(expiryText: "No expiry", compactExpiryText: "No expiry"),
            ]))

        #expect(one.heightFingerprint(section: "card") != two.heightFingerprint(section: "card"))
    }

    @Test
    func `height fingerprint ignores reset-credit text when item count is unchanged`() {
        func items(fifthCompactExpiryText: String) -> [CodexResetCreditPresentationItem] {
            (1...4).map { day in
                CodexResetCreditPresentationItem(expiryText: "Expires in \(day)d", compactExpiryText: "\(day)d")
            } + [CodexResetCreditPresentationItem(
                expiryText: "Expires in 5d",
                compactExpiryText: fifthCompactExpiryText)]
        }
        let one = Self.model(resetCredits: CodexResetCreditsPresentation(
            text: "5 available",
            items: items(fifthCompactExpiryText: "5d")))
        let two = Self.model(resetCredits: CodexResetCreditsPresentation(
            text: "5 available",
            items: items(fifthCompactExpiryText: "6d")))

        #expect(one.heightFingerprint(section: "card") == two.heightFingerprint(section: "card"))
    }

    @Test
    func `height fingerprint changes when detail right secondary text changes`() {
        let withoutRisk = Self.model(detailRightSecondaryText: nil).heightFingerprint(section: "card")
        let withRisk = Self.model(detailRightSecondaryText: "≈ 45% run-out risk").heightFingerprint(section: "card")
        let withChangedRisk = Self.model(detailRightSecondaryText: "≈ 70% run-out risk")
            .heightFingerprint(section: "card")

        #expect(withoutRisk != withRisk)
        #expect(withRisk == withChangedRisk)
        #expect(!withRisk.contains("45% run-out risk"))
    }

    private static func model(
        percent: Double = 42,
        percentStyle: UsageMenuCardView.Model.PercentStyle = .left,
        resetCredits: CodexResetCreditsPresentation? = nil,
        detailRightSecondaryText: String? = nil) -> UsageMenuCardView.Model
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
                    statusText: "Secret status",
                    resetText: nil,
                    detailText: nil,
                    detailLeftText: nil,
                    detailRightText: nil,
                    detailRightSecondaryText: detailRightSecondaryText,
                    pacePercent: nil,
                    paceOnTop: true),
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
            codexResetCredits: resetCredits,
            providerCost: nil,
            tokenUsage: nil,
            placeholder: nil,
            progressColor: .blue)
    }
}
