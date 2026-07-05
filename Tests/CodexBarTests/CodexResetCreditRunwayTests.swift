import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct CodexResetCreditRunwayTests {
    private let day: TimeInterval = 86400
    private let hour: TimeInterval = 3600
    private let now = Date(timeIntervalSince1970: 1_781_726_400)

    @Test
    func `markers are placed by remaining time over the longest credit lifetime`() {
        // a: granted 1d ago, expires in 6d -> lifetime 7d, remaining 6d
        // b: granted 1d ago, expires in 29d -> lifetime 30d, remaining 29d ; horizon = 30d
        let markers = CodexResetCreditsPresentation.runwayMarkers(
            credits: [
                self.credit(id: "a", grantedAgo: self.day, expiresIn: 6 * self.day),
                self.credit(id: "b", grantedAgo: self.day, expiresIn: 29 * self.day),
            ],
            resetStyle: .countdown,
            now: self.now)

        #expect(markers.count == 2)
        #expect(markers[0].isNearest)
        #expect(!markers[1].isNearest)
        #expect(abs(markers[0].position - 6.0 / 30.0) < 0.001)
        #expect(abs(markers[1].position - 29.0 / 30.0) < 0.001)
        // Resting label rides the nearest credit only; every marker carries hover text.
        #expect(markers[0].restingLabel == "6d")
        #expect(markers[1].restingLabel == nil)
        #expect(markers.allSatisfy { !$0.hoverText.isEmpty })
    }

    @Test
    func `credits without an expiry stay off the track`() {
        let markers = CodexResetCreditsPresentation.runwayMarkers(
            credits: [
                self.credit(id: "dated", grantedAgo: self.day, expiresIn: 5 * self.day),
                self.credit(id: "forever", grantedAgo: self.day, expiresIn: nil),
            ],
            resetStyle: .countdown,
            now: self.now)

        #expect(markers.count == 1)
    }

    @Test
    func `nearest credit under 48h is urgent`() {
        let urgent = CodexResetCreditsPresentation.runwayMarkers(
            credits: [
                self.credit(id: "soon", grantedAgo: self.day, expiresIn: 37 * self.hour),
                self.credit(id: "later", grantedAgo: self.day, expiresIn: 10 * self.day),
            ],
            resetStyle: .countdown,
            now: self.now)
        #expect(urgent[0].isUrgent)
        #expect(!urgent[1].isUrgent)

        let calm = CodexResetCreditsPresentation.runwayMarkers(
            credits: [self.credit(id: "ok", grantedAgo: self.day, expiresIn: 5 * self.day)],
            resetStyle: .countdown,
            now: self.now)
        #expect(!calm[0].isUrgent)
    }

    @Test
    func `no dated future credits yields no markers`() {
        let markers = CodexResetCreditsPresentation.runwayMarkers(
            credits: [
                self.credit(id: "expired", grantedAgo: 2 * self.day, expiresIn: -1 * self.hour),
                self.credit(id: "forever", grantedAgo: self.day, expiresIn: nil),
            ],
            resetStyle: .countdown,
            now: self.now)
        #expect(markers.isEmpty)
    }

    @Test
    func `horizon label reflects the longest lifetime`() {
        let label = CodexResetCreditsPresentation.runwayHorizonLabel(
            credits: [self.credit(id: "a", grantedAgo: self.day, expiresIn: 6 * self.day)],
            now: self.now)
        #expect(label == "7d")
    }

    @Test
    func `make builds runway data only for the runway style`() throws {
        let snapshot = self.snapshot(credits: [
            self.credit(id: "a", grantedAgo: self.day, expiresIn: 6 * self.day),
            self.credit(id: "b", grantedAgo: self.day, expiresIn: 20 * self.day),
        ])

        let list = try #require(CodexResetCreditsPresentation.make(
            snapshot: snapshot, resetStyle: .countdown, expiryStyle: .list, now: self.now))
        #expect(list.markers.isEmpty)
        #expect(list.horizonLabel == nil)
        #expect(!list.showsRunway)

        let runway = try #require(CodexResetCreditsPresentation.make(
            snapshot: snapshot, resetStyle: .countdown, expiryStyle: .runway, now: self.now))
        #expect(runway.markers.count == 2)
        #expect(runway.horizonLabel != nil)
        #expect(runway.showsRunway)
    }

    @Test
    func `runway falls back to the list when no dated credits exist`() throws {
        let snapshot = self.snapshot(credits: [self.credit(id: "forever", grantedAgo: self.day, expiresIn: nil)])
        let presentation = try #require(CodexResetCreditsPresentation.make(
            snapshot: snapshot, resetStyle: .countdown, expiryStyle: .runway, now: self.now))
        #expect(presentation.markers.isEmpty)
        #expect(!presentation.showsRunway)
        #expect(presentation.items.count == 1)
    }

    private func credit(
        id: String,
        status: CodexRateLimitResetCreditStatus = .available,
        grantedAgo: TimeInterval,
        expiresIn: TimeInterval?) -> CodexRateLimitResetCredit
    {
        CodexRateLimitResetCredit(
            id: id,
            resetType: "codex_rate_limits",
            status: status,
            grantedAt: self.now.addingTimeInterval(-grantedAgo),
            expiresAt: expiresIn.map(self.now.addingTimeInterval),
            redeemStartedAt: nil,
            redeemedAt: nil,
            title: nil,
            description: nil)
    }

    private func snapshot(credits: [CodexRateLimitResetCredit]) -> CodexRateLimitResetCreditsSnapshot {
        CodexRateLimitResetCreditsSnapshot(credits: credits, availableCount: credits.count, updatedAt: self.now)
    }
}
