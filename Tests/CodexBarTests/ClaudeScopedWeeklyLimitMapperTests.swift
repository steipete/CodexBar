import Foundation
import Testing
@testable import CodexBarCore

struct ClaudeScopedWeeklyLimitMapperTests {
    @Test
    func `model id provides a stable safe identifier and duplicate limits collapse`() throws {
        let reset = Date(timeIntervalSince1970: 1_783_507_200)
        let limits = [
            Self.limit(modelID: "claude/fable.5:promo", modelName: "Fable", resetsAt: reset),
            Self.limit(modelID: "claude/fable.5:promo", modelName: "Fable renamed", resetsAt: reset),
        ]

        let windows = ClaudeScopedWeeklyLimitMapper.extraRateWindows(
            from: limits,
            resetDescription: { _ in "Jul 8" })
        let window = try #require(windows.first)

        #expect(windows.count == 1)
        #expect(window.id == "claude-weekly-scoped-claude-fable-5-promo")
        #expect(window.title == "Fable only")
        #expect(window.window.resetsAt == reset)
        #expect(window.window.resetDescription == "Jul 8")
    }

    @Test
    func `display name supplies the identifier when the API omits a model id`() throws {
        let windows = ClaudeScopedWeeklyLimitMapper.extraRateWindows(from: [
            Self.limit(modelID: "  ", modelName: " Team / Research "),
        ])

        let window = try #require(windows.first)
        #expect(window.id == "claude-weekly-scoped-team-research")
        #expect(window.title == "Team / Research only")
    }

    @Test
    func `unrelated malformed and unnamed limits are ignored`() {
        let limits = [
            Self.limit(kind: "session", modelName: "Fable"),
            Self.limit(group: "monthly", modelName: "Fable"),
            Self.limit(percent: .nan, modelName: "Fable"),
            Self.limit(modelName: "  "),
        ]

        #expect(ClaudeScopedWeeklyLimitMapper.extraRateWindows(from: limits).isEmpty)
    }

    private static func limit(
        kind: String = "weekly_scoped",
        group: String = "weekly",
        percent: Double = 5,
        modelID: String? = nil,
        modelName: String?,
        resetsAt: Date? = nil) -> ClaudeScopedWeeklyLimitMapper.Limit
    {
        ClaudeScopedWeeklyLimitMapper.Limit(
            kind: kind,
            group: group,
            percent: percent,
            resetsAt: resetsAt,
            modelID: modelID,
            modelName: modelName)
    }
}
