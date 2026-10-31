import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct UpcomingResetNotificationTests {
    struct UpcomingResetPost: Equatable {
        let provider: UsageProvider
        let event: UpcomingResetWarningEvent
    }

    @MainActor
    final class NotifierSpy: SessionQuotaNotifying {
        private(set) var upcomingResetPosts: [UpcomingResetPost] = []
        var deliveryChecks: [@MainActor () -> Bool] = []

        func post(transition _: SessionQuotaTransition, provider _: UsageProvider, badge _: NSNumber?) {}

        func postQuotaWarning(
            event _: QuotaWarningEvent,
            provider _: UsageProvider,
            soundEnabled _: Bool,
            onScreenAlertEnabled _: Bool)
        {}

        func postLimitReset(
            provider _: UsageProvider,
            window _: QuotaWarningWindow,
            accountDisplayName _: String?,
            isCurrent _: @escaping @MainActor () -> Bool)
        {}

        func postUpcomingResetWarning(
            event: UpcomingResetWarningEvent,
            provider: UsageProvider,
            now _: Date,
            isCurrent: @escaping @MainActor () -> Bool)
        {
            self.deliveryChecks.append(isCurrent)
            self.upcomingResetPosts.append(UpcomingResetPost(provider: provider, event: event))
        }
    }

    private static let accountEmail = "upcoming-reset@example.com"
    private static let start = Date(timeIntervalSince1970: 1_784_600_000)

    // MARK: - Settings

    @Test
    func `upcoming reset warnings default off and persist when enabled`() {
        let defaults = InMemoryUserDefaults()
        let settings = Self.makeSettings(defaults: defaults)

        #expect(settings.upcomingResetNotificationsEnabled == false)
        #expect(defaults.object(forKey: "upcomingResetNotificationsEnabled") == nil)

        settings.upcomingResetNotificationsEnabled = true

        #expect(defaults.bool(forKey: "upcomingResetNotificationsEnabled") == true)
        #expect(Self.makeSettings(defaults: defaults).upcomingResetNotificationsEnabled == true)
    }

    @Test
    func `portable preferences carry the upcoming reset toggle in both directions`() throws {
        let source = Self.makeSettings(defaults: InMemoryUserDefaults())
        let target = Self.makeSettings(defaults: InMemoryUserDefaults())
        source.upcomingResetNotificationsEnabled = true
        let document = try PreferencesDocument(data: source.exportPreferences().encoded())
        #expect(try document.value("upcomingResetNotificationsEnabled") == true)
        try target.importPreferences(document)
        #expect(target.upcomingResetNotificationsEnabled)
        try target.importPreferences(PreferencesDocument())
        #expect(target.upcomingResetNotificationsEnabled)
        source.upcomingResetNotificationsEnabled = false
        try target.importPreferences(source.exportPreferences())
        #expect(!target.upcomingResetNotificationsEnabled)
    }

    // MARK: - Stage logic

    @Test
    func `early warning fires within a day of the boundary and records the stage`() {
        let boundary = Self.start.addingTimeInterval(23 * 3600)
        let crossed = UpcomingResetNotificationLogic.crossedStage(
            previousState: nil,
            resetsAt: boundary,
            now: Self.start)
        #expect(crossed?.stage == .earlyWarning)
        #expect(crossed?.state.firedStages == [.earlyWarning])
        #expect(crossed?.state.resetBoundary == boundary)
    }

    @Test
    func `fired stages do not repeat for the same boundary`() {
        let boundary = Self.start.addingTimeInterval(23 * 3600)
        let first = UpcomingResetNotificationLogic.crossedStage(
            previousState: nil,
            resetsAt: boundary,
            now: Self.start)
        let second = UpcomingResetNotificationLogic.crossedStage(
            previousState: first?.state,
            resetsAt: boundary,
            now: Self.start.addingTimeInterval(60))
        #expect(second == nil)
    }

    @Test
    func `only the last call fires when both lead times already elapsed`() {
        let boundary = Self.start.addingTimeInterval(30 * 60)
        let crossed = UpcomingResetNotificationLogic.crossedStage(
            previousState: nil,
            resetsAt: boundary,
            now: Self.start)
        #expect(crossed?.stage == .lastCall)
        #expect(crossed?.state.firedStages == [.earlyWarning, .lastCall])
        #expect(UpcomingResetNotificationLogic.crossedStage(
            previousState: crossed?.state,
            resetsAt: boundary,
            now: Self.start.addingTimeInterval(60)) == nil)
    }

    @Test
    func `the last call follows the early warning for the same boundary`() {
        let boundary = Self.start.addingTimeInterval(23 * 3600)
        let early = UpcomingResetNotificationLogic.crossedStage(
            previousState: nil,
            resetsAt: boundary,
            now: Self.start)
        let lastCall = UpcomingResetNotificationLogic.crossedStage(
            previousState: early?.state,
            resetsAt: boundary,
            now: boundary.addingTimeInterval(-30 * 60))
        #expect(lastCall?.stage == .lastCall)
        #expect(lastCall?.state.firedStages == [.earlyWarning, .lastCall])
    }

    @Test
    func `a new reset boundary re-arms every stage`() {
        let boundary = Self.start.addingTimeInterval(23 * 3600)
        let early = UpcomingResetNotificationLogic.crossedStage(
            previousState: nil,
            resetsAt: boundary,
            now: Self.start)
        let nextBoundary = boundary.addingTimeInterval(7 * 86400)
        let nextCycle = UpcomingResetNotificationLogic.crossedStage(
            previousState: early?.state,
            resetsAt: nextBoundary,
            now: nextBoundary.addingTimeInterval(-23 * 3600))
        #expect(nextCycle?.stage == .earlyWarning)
        #expect(nextCycle?.state.firedStages == [.earlyWarning])
    }

    @Test
    func `an elapsed boundary never fires`() {
        #expect(UpcomingResetNotificationLogic.crossedStage(
            previousState: nil,
            resetsAt: Self.start,
            now: Self.start) == nil)
        #expect(UpcomingResetNotificationLogic.crossedStage(
            previousState: nil,
            resetsAt: Self.start.addingTimeInterval(-60),
            now: Self.start) == nil)
    }

    // MARK: - Store handling

    @Test
    func `codex weekly window posts the early warning and then the last call`() {
        let notifier = NotifierSpy()
        let store = Self.makeStore(notifier: notifier)
        store.settings.upcomingResetNotificationsEnabled = true
        let boundary = Self.start.addingTimeInterval(23 * 3600)

        store.handleUpcomingResetWarning(
            provider: .codex,
            snapshot: Self.snapshot(weeklyUsed: 30, resetsAt: boundary),
            accountDiscriminator: "codex-account:a",
            now: Self.start)
        store.handleUpcomingResetWarning(
            provider: .codex,
            snapshot: Self.snapshot(weeklyUsed: 30, resetsAt: boundary),
            accountDiscriminator: "codex-account:a",
            now: boundary.addingTimeInterval(-30 * 60))

        #expect(notifier.upcomingResetPosts.count == 2)
        #expect(notifier.upcomingResetPosts.map(\.event.remainingPercent) == [70, 70])
        #expect(notifier.upcomingResetPosts.first?.event.accountDisplayName == Self.accountEmail)
    }

    @Test
    func `upcoming reset warnings stay silent when disabled`() {
        let notifier = NotifierSpy()
        let store = Self.makeStore(notifier: notifier)
        store.handleUpcomingResetWarning(
            provider: .codex,
            snapshot: Self.snapshot(weeklyUsed: 30, resetsAt: Self.start.addingTimeInterval(30 * 60)),
            accountDiscriminator: nil,
            now: Self.start)
        #expect(notifier.upcomingResetPosts.isEmpty)
    }

    @Test
    func `upcoming reset warnings stay silent for other providers`() {
        let notifier = NotifierSpy()
        let store = Self.makeStore(notifier: notifier)
        store.settings.upcomingResetNotificationsEnabled = true
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: RateWindow(
                usedPercent: 30,
                windowMinutes: 10080,
                resetsAt: Self.start.addingTimeInterval(30 * 60),
                resetDescription: nil),
            updatedAt: Self.start,
            identity: ProviderIdentitySnapshot(
                providerID: .claude,
                accountEmail: Self.accountEmail,
                accountOrganization: nil,
                loginMethod: "max"))
        store.handleUpcomingResetWarning(
            provider: .claude,
            snapshot: snapshot,
            accountDiscriminator: nil,
            now: Self.start)
        #expect(notifier.upcomingResetPosts.isEmpty)
    }

    @Test
    func `hide personal info omits the account from upcoming reset warnings`() {
        let notifier = NotifierSpy()
        let store = Self.makeStore(notifier: notifier)
        store.settings.upcomingResetNotificationsEnabled = true
        store.settings.hidePersonalInfo = true
        store.handleUpcomingResetWarning(
            provider: .codex,
            snapshot: Self.snapshot(weeklyUsed: 30, resetsAt: Self.start.addingTimeInterval(30 * 60)),
            accountDiscriminator: nil,
            now: Self.start)
        #expect(notifier.upcomingResetPosts.count == 1)
        #expect(notifier.upcomingResetPosts.first?.event.accountDisplayName == nil)
    }

    @Test
    func `windows without a reset boundary never warn`() {
        let notifier = NotifierSpy()
        let store = Self.makeStore(notifier: notifier)
        store.settings.upcomingResetNotificationsEnabled = true
        store.handleUpcomingResetWarning(
            provider: .codex,
            snapshot: Self.snapshot(weeklyUsed: 30, resetsAt: nil),
            accountDiscriminator: nil,
            now: Self.start)
        #expect(notifier.upcomingResetPosts.isEmpty)
    }

    @Test
    func `one warning per stage survives a restart`() {
        let notifier = NotifierSpy()
        let defaults = InMemoryUserDefaults()
        var store = Self.makeStore(notifier: notifier, defaults: defaults)
        store.settings.upcomingResetNotificationsEnabled = true
        let boundary = Self.start.addingTimeInterval(23 * 3600)
        for offset in [0.0, 300, 600] {
            if offset == 300 {
                store = Self.makeStore(notifier: notifier, defaults: defaults)
            }
            store.handleUpcomingResetWarning(
                provider: .codex,
                snapshot: Self.snapshot(weeklyUsed: 30, resetsAt: boundary),
                accountDiscriminator: nil,
                now: Self.start.addingTimeInterval(offset))
        }
        #expect(notifier.upcomingResetPosts.count == 1)
    }

    @Test
    func `pending upcoming reset delivery rechecks opt in and personal info`() throws {
        let notifier = NotifierSpy()
        let store = Self.makeStore(notifier: notifier)
        store.settings.upcomingResetNotificationsEnabled = true
        store.handleUpcomingResetWarning(
            provider: .codex,
            snapshot: Self.snapshot(weeklyUsed: 30, resetsAt: Self.start.addingTimeInterval(30 * 60)),
            accountDiscriminator: nil,
            now: Self.start)
        let isCurrent = try #require(notifier.deliveryChecks.first)
        #expect(isCurrent())
        store.settings.upcomingResetNotificationsEnabled = false
        #expect(!isCurrent())
        store.settings.upcomingResetNotificationsEnabled = true
        store.settings.hidePersonalInfo = true
        #expect(!isCurrent())
    }

    @Test
    func `exhausted quota does not consume the upcoming reset stage`() {
        let notifier = NotifierSpy()
        let store = Self.makeStore(notifier: notifier)
        store.settings.upcomingResetNotificationsEnabled = true
        let boundary = Self.start.addingTimeInterval(1800)
        for used in [100.0, 120, Double.nan] {
            store.handleUpcomingResetWarning(
                provider: .codex,
                snapshot: Self.snapshot(weeklyUsed: used, resetsAt: boundary),
                accountDiscriminator: nil,
                now: Self.start)
        }
        #expect(notifier.upcomingResetPosts.isEmpty)
        store.handleUpcomingResetWarning(
            provider: .codex,
            snapshot: Self.snapshot(weeklyUsed: 50, resetsAt: boundary),
            accountDiscriminator: nil,
            now: Self.start)
        #expect(notifier.upcomingResetPosts.count == 1)
    }

    @Test
    func `snapshot identities keep PAT reminders separate without an OAuth owner`() {
        let notifier = NotifierSpy()
        let defaults = InMemoryUserDefaults()
        let store = Self.makeStore(notifier: notifier, defaults: defaults)
        store.settings.upcomingResetNotificationsEnabled = true
        let boundary = Self.start.addingTimeInterval(23 * 3600)
        for email in ["first@example.com", "second@example.com", "first@example.com"] {
            store.handleUpcomingResetWarning(
                provider: .codex,
                snapshot: Self.snapshot(weeklyUsed: 30, resetsAt: boundary, email: email),
                accountDiscriminator: nil,
                now: Self.start)
        }
        #expect(notifier.upcomingResetPosts.count == 2)
        let receipts = defaults.data(forKey: UsageStore.upcomingResetNotificationStatesDefaultsKey)
        let text = receipts.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        #expect(!text.contains("@example.com"))
    }

    @Test
    func `unknown identities do not share an upcoming reset receipt`() {
        let notifier = NotifierSpy()
        let store = Self.makeStore(notifier: notifier)
        store.settings.upcomingResetNotificationsEnabled = true
        store.handleUpcomingResetWarning(
            provider: .codex,
            snapshot: Self.snapshot(weeklyUsed: 30, resetsAt: Self.start.addingTimeInterval(1800), email: nil),
            accountDiscriminator: nil,
            now: Self.start)
        #expect(notifier.upcomingResetPosts.isEmpty)
        #expect(store.settings.userDefaults.data(forKey: UsageStore.upcomingResetNotificationStatesDefaultsKey) == nil)
    }

    @Test
    func `monthly quotas do not emit weekly reset warnings`() {
        let notifier = NotifierSpy()
        let store = Self.makeStore(notifier: notifier)
        store.settings.upcomingResetNotificationsEnabled = true
        store.handleUpcomingResetWarning(
            provider: .codex,
            snapshot: Self.snapshot(
                weeklyUsed: 30,
                resetsAt: Self.start.addingTimeInterval(1800),
                windowMinutes: 43200),
            accountDiscriminator: nil,
            now: Self.start)
        #expect(notifier.upcomingResetPosts.isEmpty)
    }

    // MARK: - Copy

    @Test
    func `upcoming reset copy names provider window remaining quota and countdown`() {
        CodexBarLocalizationOverride.$appLanguage.withValue("en") {
            let boundary = Self.start.addingTimeInterval(23 * 3600)
            let early = UpcomingResetNotificationLogic.notificationCopy(
                providerName: "Codex",
                event: UpcomingResetWarningEvent(
                    resetsAt: boundary,
                    remainingPercent: 70,
                    accountDisplayName: nil),
                now: Self.start)
            #expect(early.title == "Codex weekly reset soon")
            #expect(early.body == "70% of the quota is still unused. It resets in 23h and unused quota is lost.")

            let withAccount = UpcomingResetNotificationLogic.notificationCopy(
                providerName: "Codex",
                event: UpcomingResetWarningEvent(
                    resetsAt: boundary,
                    remainingPercent: 70,
                    accountDisplayName: "work@example.com"),
                now: Self.start)
            let expectedWithAccount = "Account work@example.com. 70% of the quota is still unused. "
                + "It resets in 23h and unused quota is lost."
            #expect(withAccount.body == expectedWithAccount)
        }
    }

    // MARK: - Helpers

    private static func makeSettings(defaults: UserDefaults) -> SettingsStore {
        testSettingsStore(suiteName: "UpcomingResetNotificationTests", userDefaults: defaults)
    }

    private static func makeStore(
        notifier: NotifierSpy,
        defaults: UserDefaults = InMemoryUserDefaults()) -> UsageStore
    {
        let suiteName = "UpcomingResetNotificationTests-\(UUID().uuidString)"
        let settings = Self.makeSettings(defaults: defaults)
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        settings.sessionQuotaNotificationsEnabled = false
        settings.hidePersonalInfo = false
        let store = UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            planUtilizationHistoryStore: testPlanUtilizationHistoryStore(suiteName: suiteName),
            sessionQuotaNotifier: notifier,
            startupBehavior: .testing)
        store._cancelPlanUtilizationHistoryLoadForTesting()
        store.planUtilizationHistory = [:]
        return store
    }

    private static func snapshot(
        weeklyUsed: Double,
        resetsAt: Date?,
        email: String? = "upcoming-reset@example.com",
        windowMinutes: Int = 10080) -> UsageSnapshot
    {
        UsageSnapshot(
            primary: RateWindow(
                usedPercent: 10,
                windowMinutes: 300,
                resetsAt: nil,
                resetDescription: nil),
            secondary: RateWindow(
                usedPercent: weeklyUsed,
                windowMinutes: windowMinutes,
                resetsAt: resetsAt,
                resetDescription: nil),
            updatedAt: self.start,
            identity: ProviderIdentitySnapshot(
                providerID: .codex,
                accountEmail: email,
                accountOrganization: nil,
                loginMethod: "chatgpt"))
    }
}
