import Foundation
import Testing
@testable import CodexBar

struct StatusItemAnimationCapTests {
    @Test
    func `loading animation cap expires only after thirty seconds`() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)

        #expect(!StatusItemController.loadingAnimationHasExceededContinuousCap(
            startedAt: now.addingTimeInterval(-30),
            now: now))
        #expect(StatusItemController.loadingAnimationHasExceededContinuousCap(
            startedAt: now.addingTimeInterval(-30.001),
            now: now))
    }

    @Test
    func `capped animation marker does not qualify as a fresh cap`() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)

        #expect(!StatusItemController.loadingAnimationHasExceededContinuousCap(
            startedAt: .distantPast,
            now: now))
        #expect(!StatusItemController.loadingAnimationHasExceededContinuousCap(
            startedAt: nil,
            now: now))
    }
}
