import Foundation
import Testing
@testable import CodexBar

@MainActor
struct ClaudeSwapRichUsageCardTests {
    @Test
    func `adapter last known usage reaches the account card beside its error and age`() async throws {
        try await ClaudeSwapRichUsageFixture.withFixture { fixture in
            #expect(fixture.arguments == "--list\n--json\n")
            let model = try fixture.model(for: "2")
            #expect(model.metrics.map(\.percent) == [62, 41])
            #expect(model.subtitleStyle == .error)
            #expect(model.subtitleText.contains("Token expired"))
            #expect(model.lastKnownUsageText?.contains("last-known usage") == true)
            #expect(model.planEmphasis == .none)
            #expect(model.planText == nil)
            #expect(!model.usesLiveSubtitle)
            let later = try fixture.model(for: "2", now: ClaudeSwapRichUsageFixture.now.addingTimeInterval(3600))
            #expect(later.lastKnownUsageText != model.lastKnownUsageText)
            #expect(later.heightFingerprint(section: "card") != model.heightFingerprint(section: "card"))
            #expect(later.metrics.map(\.percent) == model.metrics.map(\.percent))
        }
    }

    @Test
    func `source spend reaches the existing cost row without inventing a quota`() async throws {
        try await ClaudeSwapRichUsageFixture.withFixture { fixture in
            let model = try fixture.model(for: "1")
            let account = try #require(fixture.accounts.first { $0.id.opaqueID == "1" })
            #expect(account.snapshot?.providerCost?.used == 5.25)
            #expect(account.snapshot?.providerCost?.limit == 20)
            #expect(account.snapshot?.providerCost?.currencyCode == "USD")
            #expect(model.providerCost != nil)
            #expect(model.metrics.map(\.percent) == [26, 42])
            #expect(model.planText == "Active")
            #expect(model.planEmphasis == .active)
        }
    }

    @Test
    func `unavailable usage does not invent a deferred polling cause`() async throws {
        try await ClaudeSwapRichUsageFixture.withFixture { fixture in
            let model = try fixture.model(for: "3")
            #expect(model.metrics.map(\.percent) == [12, 30])
            #expect(model.subtitleText.contains("Usage unavailable"))
            #expect(model.lastKnownUsageText?.contains("last-known usage") == true)
            #expect(!model.subtitleText.contains("deferred"))
        }
    }

    @Test
    func `switch and adapter diagnostics retain last known age and account privacy`() async throws {
        try await ClaudeSwapRichUsageFixture.withFixture { fixture in
            let failedSwitch = try fixture.model(for: "2", hidePersonalInfo: true, switchError: "Fixture switch failed")
            #expect(failedSwitch.email == "Account 2")
            #expect(failedSwitch.subtitleText.contains("Account switch failed: Fixture switch failed"))
            #expect(failedSwitch.lastKnownUsageText?.contains("last-known usage") == true)
            #expect(!failedSwitch.subtitleText.contains("example.invalid"))
            #expect(failedSwitch.metrics.map(\.percent) == [62, 41])
            let failedAdapter = try fixture.model(for: "2", adapterError: "Fixture list failed")
            #expect(failedAdapter.subtitleText.contains("Token expired"))
            #expect(failedAdapter.lastKnownUsageText?.contains("last-known usage") == true)
        }
    }

    @Test
    func `an enabled privacy preference retains slot labels when toggled on the same store`() async throws {
        try await ClaudeSwapRichUsageFixture.withFixture { fixture in
            let initiallyHidden = try fixture.model(for: "2", hidePersonalInfo: true)
            let revealed = try fixture.model(for: "2", hidePersonalInfo: false)
            let hiddenAgain = try fixture.model(for: "2", hidePersonalInfo: true)
            #expect(initiallyHidden.email == "Account 2")
            #expect(revealed.email == "Research")
            #expect(hiddenAgain.email == initiallyHidden.email)
            #expect(initiallyHidden.heightFingerprint(section: "card") != revealed.heightFingerprint(section: "card"))
            #expect(initiallyHidden.heightFingerprint(section: "card") == hiddenAgain
                .heightFingerprint(section: "card"))
            #expect(initiallyHidden.metrics.map(\.percent) == revealed.metrics.map(\.percent))
        }
    }

    @Test
    func `active foreign credentials expose explicit repair and its busy state`() async throws {
        try await ClaudeSwapRichUsageFixture.withFixture(activeNeedsRepair: true) { fixture in
            let account = try #require(fixture.accounts.first { $0.id.opaqueID == "1" })
            #expect(account.isActive)
            #expect(account.canActivate)
            #expect(try fixture.model(for: "1").planText == L("Re-authenticate"))
            #expect(ClaudeSwapAccountMenuDisplay.actionLabel(
                for: account, switchingAccountID: account.id, switchInFlight: true) == L("Loading…"))
            #expect(ClaudeSwapAccountMenuDisplay.actionLabel(
                for: account, switchingAccountID: nil, switchInFlight: true) == nil)
        }
    }
}
