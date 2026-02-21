import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
@Suite
struct UsagePaceProfileStoreTests {
    @Test
    func isWeeklyWindow_rejectsUnknownDuration() {
        let window = RateWindow(
            usedPercent: 40,
            windowMinutes: nil,
            resetsAt: Date(timeIntervalSince1970: 0).addingTimeInterval(3 * 24 * 3600),
            resetDescription: nil)

        #expect(UsagePaceProfileStore.isWeeklyWindow(window) == false)
    }

    @Test
    func isWeeklyWindow_acceptsExplicitWeeklyDuration() {
        let window = RateWindow(
            usedPercent: 40,
            windowMinutes: 10080,
            resetsAt: Date(timeIntervalSince1970: 0).addingTimeInterval(3 * 24 * 3600),
            resetDescription: nil)

        #expect(UsagePaceProfileStore.isWeeklyWindow(window))
    }
}
