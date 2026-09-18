#if os(Linux)
import Foundation
import Testing
@testable import CodexBarCLI
@testable import CodexBarCore

struct CursorLinuxTests {
    @Test
    func `Cursor automatic source supports Linux app authentication`() {
        #expect(!CodexBarCLI.sourceModeRequiresWebSupport(
            .auto,
            provider: .cursor,
            settings: ProviderSettingsSnapshot.make(
                cursor: .init(cookieSource: .auto, manualCookieHeader: nil))))
    }

    @Test
    func `Cursor descriptor accepts explicit web source`() {
        #expect(CursorProviderDescriptor.descriptor.fetchPlan.sourceModes.contains(.web))
    }

    @Test
    func `Cursor usage split labels match Cursor and Third Party`() {
        let metadata = CursorProviderDescriptor.descriptor.metadata
        #expect(metadata.sessionLabel == "Total")
        #expect(metadata.weeklyLabel == "Cursor")
        #expect(metadata.opusLabel == "Third Party")
    }

    @Test
    func `Cursor semantic weekly window is monthly Cursor Auto, not Grok Bot`() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let monthlyReset = now.addingTimeInterval(TimeInterval((28 * 24 + 14) * 3600))
        let monthlyMinutes = 36 * 60 + (28 * 24 + 14) * 60
        let grokReset = now.addingTimeInterval(TimeInterval((2 * 24 + 14) * 3600))
        let grokWindow = RateWindow(
            usedPercent: 28,
            windowMinutes: 10080,
            resetsAt: grokReset,
            resetDescription: nil)
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 3,
                windowMinutes: monthlyMinutes,
                resetsAt: monthlyReset,
                resetDescription: nil),
            secondary: RateWindow(
                usedPercent: 3,
                windowMinutes: monthlyMinutes,
                resetsAt: monthlyReset,
                resetDescription: nil),
            tertiary: RateWindow(
                usedPercent: 16,
                windowMinutes: monthlyMinutes,
                resetsAt: monthlyReset,
                resetDescription: nil),
            extraRateWindows: [
                NamedRateWindow(
                    id: CursorSandUsageStatus.extraWindowID,
                    title: CursorSandUsageStatus.extraWindowTitle,
                    window: grokWindow),
            ],
            updatedAt: now,
            identity: nil)

        let semantic = CursorProviderDescriptor.descriptor.presentation.semanticWindows(snapshot: snapshot)
        #expect(semantic.weekly?.usedPercent == 3)
        #expect(semantic.weekly?.windowMinutes == monthlyMinutes)
        #expect(semantic.session == nil)

        let grokPace = try #require(UsagePace.weekly(window: grokWindow, now: now))
        #expect(Int(abs(grokPace.deltaPercent).rounded()) == 35)
        let monthlyWindow = try #require(snapshot.secondary)
        let monthlyPace = try #require(UsagePace.weekly(window: monthlyWindow, now: now))
        #expect(monthlyPace.stage == UsagePace.Stage.onTrack)
    }

    @Test
    func `Cursor manual cookie does not require macOS web support`() {
        #expect(!CodexBarCLI.sourceModeRequiresWebSupport(
            .web,
            provider: .cursor,
            settings: ProviderSettingsSnapshot.make(
                cursor: .init(
                    cookieSource: .manual,
                    manualCookieHeader: "WorkosCursorSessionToken=test"))))
    }

    @Test
    func `empty Cursor manual cookie still requires macOS web support`() {
        #expect(CodexBarCLI.sourceModeRequiresWebSupport(
            .web,
            provider: .cursor,
            settings: ProviderSettingsSnapshot.make(
                cursor: .init(
                    cookieSource: .manual,
                    manualCookieHeader: "  "))))
    }

    @Test
    func `disabled Cursor web source still requires macOS web support`() {
        #expect(CodexBarCLI.sourceModeRequiresWebSupport(
            .web,
            provider: .cursor,
            settings: ProviderSettingsSnapshot.make(
                cursor: .init(cookieSource: .off, manualCookieHeader: nil))))
    }
}
#endif
