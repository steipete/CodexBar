import Foundation
import Testing
@testable import CodexBar

@Suite(.serialized)
struct SessionQuotaNotificationLogicTests {
    @Test
    func `does nothing without previous value`() {
        let transition = SessionQuotaNotificationLogic.transition(previousRemaining: nil, currentRemaining: 0)
        #expect(transition == .none)
    }

    @Test
    func `detects depleted transition`() {
        let transition = SessionQuotaNotificationLogic.transition(previousRemaining: 12, currentRemaining: 0)
        #expect(transition == .depleted)
    }

    @Test
    func `detects restored transition`() {
        let transition = SessionQuotaNotificationLogic.transition(previousRemaining: 0, currentRemaining: 5)
        #expect(transition == .restored)
    }

    @Test
    func `ignores non transitions`() {
        #expect(SessionQuotaNotificationLogic.transition(previousRemaining: 0, currentRemaining: 0) == .none)
        #expect(SessionQuotaNotificationLogic.transition(previousRemaining: 10, currentRemaining: 10) == .none)
        #expect(SessionQuotaNotificationLogic.transition(previousRemaining: 10, currentRemaining: 9) == .none)
    }

    @Test
    func `treats tiny positive remaining as depleted`() {
        let transition = SessionQuotaNotificationLogic.transition(previousRemaining: 0, currentRemaining: 0.00001)
        #expect(transition == .none)
    }

    @Test
    func `suppresses restored transition when session reset boundary is unchanged`() {
        let boundary = Date(timeIntervalSince1970: 1_700_000_000)
        let evaluationTime = boundary.addingTimeInterval(-60)
        #expect(
            SessionQuotaNotificationLogic.sessionResetBoundaryAllowsRestore(
                previousResetBoundary: boundary,
                currentResetBoundary: boundary,
                evaluationTime: evaluationTime) == false)
    }

    @Test
    func `allows restored transition when unchanged session reset boundary has elapsed`() {
        let boundary = Date(timeIntervalSince1970: 1_700_000_000)
        let evaluationTime = boundary.addingTimeInterval(60)
        #expect(
            SessionQuotaNotificationLogic.sessionResetBoundaryAllowsRestore(
                previousResetBoundary: boundary,
                currentResetBoundary: boundary,
                evaluationTime: evaluationTime) == true)
    }

    @Test
    func `allows restored transition when session reset boundary advances`() {
        let previous = Date(timeIntervalSince1970: 1_700_000_000)
        let current = previous.addingTimeInterval(5 * 3600)
        #expect(
            SessionQuotaNotificationLogic.sessionResetBoundaryAllowsRestore(
                previousResetBoundary: previous,
                currentResetBoundary: current,
                evaluationTime: current) == true)
    }

    @Test
    func `allows restored transition when no previous session reset boundary exists`() {
        let current = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(
            SessionQuotaNotificationLogic.sessionResetBoundaryAllowsRestore(
                previousResetBoundary: nil,
                currentResetBoundary: current,
                evaluationTime: current) == true)
    }

    @Test
    func `allows restored transition when current boundary is missing after prior boundary elapsed`() {
        let previous = Date(timeIntervalSince1970: 1_700_000_000)
        let evaluationTime = previous.addingTimeInterval(60)
        #expect(
            SessionQuotaNotificationLogic.sessionResetBoundaryAllowsRestore(
                previousResetBoundary: previous,
                currentResetBoundary: nil,
                evaluationTime: evaluationTime) == true)
    }

    @Test
    func `suppresses restored transition when current boundary is missing before prior boundary elapsed`() {
        let previous = Date(timeIntervalSince1970: 1_700_000_000)
        let evaluationTime = previous.addingTimeInterval(-60)
        #expect(
            SessionQuotaNotificationLogic.sessionResetBoundaryAllowsRestore(
                previousResetBoundary: previous,
                currentResetBoundary: nil,
                evaluationTime: evaluationTime) == false)
    }

    @Test
    func `depleted notification copy follows Traditional Chinese app language`() {
        Self.withAppLanguage("zh-Hant") {
            let copy = SessionQuotaNotificationLogic.notificationCopy(
                transition: .depleted,
                providerName: "Codex")

            #expect(copy.title == "Codex 工作階段已用完")
            #expect(copy.body == "剩餘 0%。恢復可用時會再通知。")
        }
    }

    @Test
    func `restored notification copy follows Traditional Chinese app language`() {
        Self.withAppLanguage("zh-Hant") {
            let copy = SessionQuotaNotificationLogic.notificationCopy(
                transition: .restored,
                providerName: "Codex")

            #expect(copy.title == "Codex 工作階段已恢復")
            #expect(copy.body == "工作階段配額已恢復可用。")
        }
    }

    private static func withAppLanguage(_ language: String, perform body: () -> Void) {
        CodexBarLocalizationOverride.$appLanguage.withValue(language, operation: body)
    }
}
