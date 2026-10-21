import Foundation
import SweetCookieKit
import Testing
@testable import CodexBar
@testable import CodexBarCLI
@testable import CodexBarCore

struct LangdockUsageTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test
    func `unknown resets never revive previous dates and weekly only CLI has one real metric`() async throws {
        let previous = try await LangdockPluginTests.fetch(LangdockPluginTests.body(LangdockPluginTests.plan))
        let current = try await LangdockPluginTests.fetch(LangdockPluginTests.body(
            """
            {"sessionUsageLimitsEnabled":true,"sessionUsagePercent":0,"sessionResetsAt":null,
             "weeklyUsagePercent":0,"weeklyResetsAt":null}
            """))
            .backfillingResetTimesForProvider(.langdock, from: previous)
        #expect(current.primary?.usedPercent == 0)
        #expect(current.primary?.resetsAt == nil)
        #expect(current.secondary?.resetsAt == nil)
        let weekly = try await LangdockPluginTests.fetch(LangdockPluginTests.body(
            #"{"sessionUsageLimitsEnabled":false,"weeklyUsagePercent":0}"#))
        let card = CLICardsRenderer.makeCard(.init(
            provider: .langdock,
            snapshot: weekly,
            credits: nil,
            source: "synthetic",
            status: nil,
            notes: [],
            useColor: false,
            resetStyle: .countdown,
            weeklyWorkDays: nil,
            now: Self.now))
        #expect(card.metrics.map(\.label) == ["Weekly"])
        #expect(card.metrics.first?.remainingPercent == 100)
    }

    @MainActor
    @Test
    func `profile configuration and shared picker retain the explicit selection`() async throws {
        let fixture = try ProviderSettingsDescriptorTests().makeSettingsFixture(suite: #function)
        let usage = try await LangdockPluginTests.fetch(LangdockPluginTests.body(LangdockPluginTests.plan))
        let settings = fixture.settings
        let store = fixture.store
        store.snapshots[.langdock] = usage
        #expect(store.snapshot(for: .langdock) == nil)
        settings
            .updateProviderConfig(provider: .langdock) { $0.browserProfileID = LangdockPluginTests.profile.profileID }
        #expect(store.snapshot(for: .langdock)?.secondary?.usedPercent == 104.2)
        let config = try #require(settings.providerConfig(for: .langdock))
        #expect(try JSONDecoder().decode(ProviderConfig.self, from: JSONEncoder().encode(config))
            .browserProfileID == config.browserProfileID)
        let implementation = PluginCookieProviderImplementation(spec: LangdockProviderDescriptor.spec)
        let picker = implementation.browserProfilePicker(
            browser: "edge", context: fixture.settingsContext(provider: .langdock), profiles: [
                BrowserProfile(id: "/synthetic/Edge/Profile 1", name: "Other"),
                BrowserProfile(id: LangdockPluginTests.profile.profileID, name: "Selected"),
            ])
        #expect(picker.title == "Browser profile")
        #expect(picker.binding.wrappedValue == LangdockPluginTests.profile.profileID)
        #expect(implementation.settingsFields(context: fixture.settingsContext(provider: .langdock)).isEmpty)
        picker.binding.wrappedValue = "/synthetic/Edge/Profile 1"
        #expect(store.snapshot(for: .langdock) == nil)
        #expect(store.snapshots[.langdock] == nil)
        let registration = LangdockProviderDescriptor.descriptor.settingsSection
        let contribution = try #require(implementation.settingsSnapshot(context: .init(
            settings: settings,
            tokenOverride: nil)))
        let snapshot = ProviderSettingsSnapshot(contributions: [contribution])
        #expect(registration.cookieSettings(from: snapshot)?.selectedBrowserProfile?
            .profileID == "/synthetic/Edge/Profile 1")
        #expect(!LangdockProviderDescriptor.descriptor.metadata.defaultEnabled)
        #expect(LangdockProviderDescriptor.descriptor.metadata.browserCookieOrder == [.edge, .chrome, .safari])
        var disabled = config
        disabled.cookieSource = .off
        let disabledContribution = try #require(registration.credentialContribution(
            context: .init(config: disabled, account: nil)))
        #expect(registration.cookieSettings(from: .init(contributions: [disabledContribution]))?.cookieSource == .off)
        #expect(LangdockProviderDescriptor.descriptor.fetchPlan.sourceModes == [.auto, .web])
    }

    @MainActor
    @Test(ProviderTransportRegressionFixtures())
    func `missing included limits remove previous bars while verified outages retain capture age`() async throws {
        try await ProviderTransportRegressionSupport.withStore(provider: .langdock, hasPriorData: false) { store, _ in
            store.settings.updateProviderConfig(provider: .langdock) {
                $0.source = .web
                $0.browserProfileID = LangdockPluginTests.profile.profileID
            }
            store.settings.usageBarsShowUsed = true
            let previous = try await LangdockPluginTests.fetch(
                LangdockPluginTests.body(LangdockPluginTests.plan), now: Self.now.addingTimeInterval(-600))
            store.snapshots[.langdock] = previous
            store.lastKnownResetSnapshots[.langdock] = previous
            let failure = ProviderBrowserSessionFailure(
                owner: previous.browserSessionOwner,
                underlyingError: ProviderFetchClassifiedError(
                    kind: .providerUnavailable,
                    message: "Synthetic outage"))
            store._test_providerFetchOutcomeOverride = { _ in
                ProviderFetchOutcome(result: .failure(failure), attempts: [])
            }
            await store.refreshProvider(.langdock, allowDisabled: true)
            #expect(store.snapshot(for: .langdock)?.updatedAt == previous.updatedAt)
            let model = store.menuCardModel(for: .langdock, now: Self.now)
            #expect(model.subtitleText == failure.localizedDescription)
            #expect(model.lastKnownUsageText == LastKnownUsagePresentation.message(
                capturedAt: previous.updatedAt,
                now: Self.now))
            let missing = try await LangdockPluginTests.fetch(LangdockPluginTests.body("null"), now: Self.now)
            store._test_providerFetchOutcomeOverride = { _ in
                ProviderFetchOutcome(result: .success(ProviderFetchResult(
                    usage: missing,
                    credits: nil,
                    dashboard: nil,
                    sourceLabel: "synthetic",
                    strategyID: "langdock.js",
                    strategyKind: .web)), attempts: [])
            }
            await store.refreshProvider(.langdock, allowDisabled: true)
            #expect(store.snapshot(for: .langdock)?.primary == nil)
            #expect(store.snapshot(for: .langdock)?.secondary == nil)
            #expect(store.menuCardModel(for: .langdock, now: Self.now).metrics.isEmpty)
            #expect(store.lastKnownResetSnapshots[.langdock]?.secondary == nil)
        }
    }
}
