import CodexBarCore
import Foundation
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
    func `height fingerprint tracks codex reset credit presentation shape`() {
        let base = Self.model().heightFingerprint(section: "card")
        let withButton = Self.model(resetCredits: .init(
            text: "1 manual reset available",
            detailText: "Next expires in 1d",
            helpText: "available, in 1d",
            creditToConsume: Self.resetCredit())).heightFingerprint(section: "card")
        let withoutButton = Self.model(resetCredits: .init(
            text: "1 manual reset available",
            detailText: "Next expires in 1d",
            helpText: "available, in 1d",
            creditToConsume: nil)).heightFingerprint(section: "card")
        let changedDetail = Self.model(resetCredits: .init(
            text: "2 manual resets available",
            detailText: "Next expires in 2d",
            helpText: "available, in 2d",
            creditToConsume: Self.resetCredit())).heightFingerprint(section: "card")

        #expect(base != withButton)
        #expect(withButton != withoutButton)
        #expect(withButton != changedDetail)
    }

    private static func model(
        percent: Double = 42,
        percentStyle: UsageMenuCardView.Model.PercentStyle = .left,
        resetCredits: CodexResetCreditsPresentation? = nil) -> UsageMenuCardView.Model
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

    private static func resetCredit() -> CodexRateLimitResetCredit {
        CodexRateLimitResetCredit(
            id: "reset-1",
            resetType: "codex_rate_limits",
            status: .available,
            grantedAt: Date(timeIntervalSince1970: 1),
            expiresAt: Date(timeIntervalSince1970: 2),
            redeemStartedAt: nil,
            redeemedAt: nil,
            title: "Reset",
            description: nil)
    }
}
