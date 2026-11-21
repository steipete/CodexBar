import Foundation
import Testing
@testable import CodexBarCore

struct NotionProviderTests {
    private static let now = Date(timeIntervalSince1970: 1_785_600_000)

    @Test
    func `manual tokens headers and captures are normalized without exposing cookies to scripts`() {
        #expect(NotionProviderDescriptor.manualHeader("fixture") == "token_v2=fixture")
        #expect(NotionProviderDescriptor
            .manualHeader("Cookie: token_v2=fixture; extra=value") == "token_v2=fixture; extra=value")
        #expect(NotionProviderDescriptor
            .manualHeader("curl https://app.notion.com -H 'Cookie: token_v2=fixture'") == "token_v2=fixture")
        #expect(NotionProviderDescriptor.manualHeader("") == nil)
    }

    private static func utcDate(year: Int, month: Int, day: Int) throws -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        return try #require(calendar.date(from: DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day)))
    }

    private static func monthlyWindow(usedPercent: Double, resetsAt: Date) -> RateWindow {
        RateWindow(
            usedPercent: usedPercent,
            windowMinutes: ProviderPaceCapability.monthlyWindowSentinelMinutes,
            resetsAt: resetsAt,
            resetDescription: nil)
    }

    @Test
    func `scores the billing window against the real calendar month`() throws {
        // The sentinel is a placeholder, not a duration: resolution has to yield the true length of the
        // cycle ending at the reset. Asserting only the capability booleans would stay green if the
        // descriptor were swapped for a plain 30-day capability, which is the regression to catch.
        let pace = ProviderDescriptorRegistry.descriptor(for: .notion).pace
        let februaryCycle = try Self.monthlyWindow(
            usedPercent: 18,
            resetsAt: Self.utcDate(year: 2026, month: 3, day: 1))
        let mayCycle = try Self.monthlyWindow(
            usedPercent: 18,
            resetsAt: Self.utcDate(year: 2026, month: 6, day: 1))

        #expect(pace.resolvedResetWindowForPace(februaryCycle).windowMinutes == 28 * 24 * 60)
        #expect(pace.resolvedResetWindowForPace(mayCycle).windowMinutes == 31 * 24 * 60)
        #expect(pace.resolvedResetWindowForPace(februaryCycle).resetsAt == februaryCycle.resetsAt)
        #expect(pace.resolvedResetWindowForPace(februaryCycle).usedPercent == februaryCycle.usedPercent)
    }

    @Test
    func `a billing window with no length is scored against the caller's default`() throws {
        // A nil length is not pace-safe on its own: `UsagePace.weekly` substitutes `defaultWindowMinutes`
        // rather than skipping the window, so dropping the sentinel would score a month against a week.
        let resetsAt = try Self.utcDate(year: 2026, month: 3, day: 1)
        let now = resetsAt.addingTimeInterval(-3 * 24 * 60 * 60)
        let lengthless = RateWindow(usedPercent: 37, windowMinutes: nil, resetsAt: resetsAt, resetDescription: nil)

        let weekScored = try #require(UsagePace.weekly(window: lengthless, now: now, defaultWindowMinutes: 10080))
        // Four of seven days elapsed against a week that is really a month.
        #expect((weekScored.expectedUsedPercent * 10).rounded() / 10 == 57.1)

        let resolved = ProviderDescriptorRegistry.descriptor(for: .notion).pace
            .resolvedResetWindowForPace(Self.monthlyWindow(usedPercent: 37, resetsAt: resetsAt))
        let cycleScored = try #require(UsagePace.weekly(window: resolved, now: now, defaultWindowMinutes: 10080))
        // Twenty-five of February's twenty-eight days elapsed.
        #expect((cycleScored.expectedUsedPercent * 10).rounded() / 10 == 89.3)
    }

    @Test
    func `does not treat the rolling window as a monthly one`() {
        let descriptor = ProviderDescriptorRegistry.descriptor(for: .notion)
        let rolling = RateWindow(
            usedPercent: 42.5,
            windowMinutes: 360,
            resetsAt: Self.now.addingTimeInterval(3600),
            resetDescription: nil)

        #expect(!descriptor.pace.usesInferredMonthlyDuration(window: rolling))
    }

    @Test
    func `personal pools use reported durations and never acquire a session or inferred month`() {
        let descriptor = NotionProviderDescriptor.descriptor
        for title in ["Standard", "Select"] {
            let window = RateWindow(
                usedPercent: 20,
                windowMinutes: 43200,
                resetsAt: Self.now.addingTimeInterval(86400),
                resetDescription: nil,
                title: title)
            #expect(!descriptor.pace.usesInferredMonthlyDuration(window: window))
            #expect(descriptor.pace.resolvedResetWindowForPace(window) == window)
            #expect(descriptor.pace.resolvedKind(slot: .primary, window: window, now: Self.now) == .weekly)
            #expect(!descriptor.pace.supportsSessionPace(window: window, now: Self.now))
            let unknown = RateWindow(
                usedPercent: 20,
                windowMinutes: nil,
                resetsAt: window.resetsAt,
                resetDescription: nil,
                title: title)
            #expect(descriptor.pace.resolvedKind(slot: .primary, window: unknown, now: Self.now) == nil)
        }
    }

    @Test
    func `a single Select pool remains monthly and is available to semantic and icon selection`() {
        let select = RateWindow(
            usedPercent: 0,
            windowMinutes: 44640,
            resetsAt: Self.now.addingTimeInterval(86400),
            resetDescription: nil,
            title: "Select")
        let snapshot = UsageSnapshot(primary: nil, secondary: select, updatedAt: Self.now)
        let presentation = NotionProviderDescriptor.descriptor.presentation
        #expect(presentation.semanticWindows(snapshot: snapshot).session == nil)
        #expect(presentation.semanticWindows(snapshot: snapshot).weekly == select)
        let icons = presentation.iconWindows(context: .init(
            snapshot: snapshot, secondaryOverrideWindowID: nil, now: Self.now))
        #expect(icons.primary == select)
        #expect(icons.secondary == nil)
        let labels = presentation.rateWindowLabels(
            metadata: NotionProviderDescriptor.descriptor.metadata, snapshot: snapshot)
        #expect(labels.secondary == "Select")
    }
}
