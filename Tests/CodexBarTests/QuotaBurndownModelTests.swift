import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct QuotaBurndownModelTests {
    @Test
    func `builds current window samples and ideal line`() throws {
        let reset = Self.now.addingTimeInterval(2 * 3600)
        let history = Self.history(entries: [
            Self.entry(hoursBeforeNow: 2, usedPercent: 20, reset: reset),
            Self.entry(hoursBeforeNow: 1, usedPercent: 45, reset: reset),
        ])

        let model = try #require(QuotaBurndownModel(
            history: history,
            window: Self.window(usedPercent: 60, reset: reset),
            now: Self.now))

        #expect(model.start == reset.addingTimeInterval(-5 * 3600))
        #expect(model.reset == reset)
        #expect(model.samples == [
            .init(date: Self.now.addingTimeInterval(-2 * 3600), remainingPercent: 80),
            .init(date: Self.now.addingTimeInterval(-3600), remainingPercent: 55),
            .init(date: Self.now, remainingPercent: 40),
        ])
        #expect(model.ideal == [
            .init(date: reset.addingTimeInterval(-5 * 3600), remainingPercent: 100),
            .init(date: reset, remainingPercent: 0),
        ])
    }

    @Test
    func `isolates the current reset and keeps only the newest segment after a usage drop`() throws {
        let reset = Self.now.addingTimeInterval(2 * 3600)
        let priorReset = reset.addingTimeInterval(-5 * 3600)
        let history = Self.history(entries: [
            Self.entry(hoursBeforeNow: 6, usedPercent: 90, reset: priorReset),
            Self.entry(hoursBeforeNow: 4, usedPercent: 70, reset: reset),
            Self.entry(hoursBeforeNow: 2, usedPercent: 80, reset: reset),
            Self.entry(hoursBeforeNow: 1.5, usedPercent: 85, reset: priorReset),
            Self.entry(hoursBeforeNow: 1, usedPercent: 10, reset: reset),
            Self.entry(hoursBeforeNow: 0.5, usedPercent: 25, reset: reset),
        ])

        let model = try #require(QuotaBurndownModel(
            history: history,
            window: Self.window(usedPercent: 30, reset: reset),
            now: Self.now))

        #expect(model.samples == [
            .init(date: Self.now.addingTimeInterval(-3600), remainingPercent: 90),
            .init(date: Self.now.addingTimeInterval(-1800), remainingPercent: 75),
            .init(date: Self.now, remainingPercent: 70),
        ])
    }

    @Test
    func `accepts small reset timestamp drift while excluding another cycle`() throws {
        let reset = Self.now.addingTimeInterval(2 * 3600)
        let history = Self.history(entries: [
            Self.entry(hoursBeforeNow: 2, usedPercent: 20, reset: reset.addingTimeInterval(90)),
            Self.entry(hoursBeforeNow: 1, usedPercent: 40, reset: reset.addingTimeInterval(-5 * 3600)),
        ])

        let model = try #require(QuotaBurndownModel(
            history: history,
            window: Self.window(usedPercent: 50, reset: reset),
            now: Self.now))

        #expect(model.samples == [
            .init(date: Self.now.addingTimeInterval(-2 * 3600), remainingPercent: 80),
            .init(date: Self.now, remainingPercent: 50),
        ])
    }

    @Test
    func `requires a valid current reset and duration`() {
        let history = Self.history(entries: [])

        #expect(QuotaBurndownModel(
            history: history,
            window: RateWindow(
                usedPercent: 10,
                windowMinutes: 300,
                resetsAt: nil,
                resetDescription: nil),
            now: Self.now) == nil)
        #expect(QuotaBurndownModel(
            history: history,
            window: RateWindow(
                usedPercent: 10,
                windowMinutes: 0,
                resetsAt: Self.now.addingTimeInterval(3600),
                resetDescription: nil),
            now: Self.now) == nil)
        #expect(QuotaBurndownModel(
            history: history,
            window: RateWindow(
                usedPercent: 10,
                windowMinutes: 300,
                resetsAt: Self.now.addingTimeInterval(3600),
                resetDescription: nil,
                isSyntheticPlaceholder: true),
            now: Self.now) == nil)
    }

    @Test
    func `uses the live window when history has no current samples`() throws {
        let reset = Self.now.addingTimeInterval(2 * 3600)
        let history = Self.history(entries: [
            Self.entry(hoursBeforeNow: 6, usedPercent: 80, reset: reset.addingTimeInterval(-5 * 3600)),
        ])

        let model = try #require(QuotaBurndownModel(
            history: history,
            window: Self.window(usedPercent: 125, reset: reset),
            now: Self.now))

        #expect(model.samples == [.init(date: Self.now, remainingPercent: 0)])
    }

    @Test
    func `deduplicates timestamps skips nonfinite history and rejects nonfinite live usage`() throws {
        let reset = Self.now.addingTimeInterval(2 * 3600)
        let duplicateDate = Self.now.addingTimeInterval(-3600)
        let history = Self.history(entries: [
            .init(capturedAt: Self.now.addingTimeInterval(-2 * 3600), usedPercent: .nan, resetsAt: reset),
            .init(capturedAt: duplicateDate, usedPercent: 20, resetsAt: reset),
            .init(capturedAt: duplicateDate, usedPercent: 30, resetsAt: reset),
            .init(capturedAt: Self.now, usedPercent: 40, resetsAt: reset),
        ])

        let model = try #require(QuotaBurndownModel(
            history: history,
            window: Self.window(usedPercent: 150, reset: reset),
            now: Self.now))

        #expect(model.samples == [
            .init(date: duplicateDate, remainingPercent: 70),
            .init(date: Self.now, remainingPercent: 0),
        ])
        #expect(QuotaBurndownModel(
            history: history,
            window: Self.window(usedPercent: .infinity, reset: reset),
            now: Self.now) == nil)
    }

    private static let now = Date(timeIntervalSince1970: 1_700_000_000)

    private static func history(entries: [PlanUtilizationHistoryEntry]) -> PlanUtilizationSeriesHistory {
        PlanUtilizationSeriesHistory(name: .session, windowMinutes: 300, entries: entries)
    }

    private static func entry(
        hoursBeforeNow: Double,
        usedPercent: Double,
        reset: Date?) -> PlanUtilizationHistoryEntry
    {
        PlanUtilizationHistoryEntry(
            capturedAt: self.now.addingTimeInterval(-hoursBeforeNow * 3600),
            usedPercent: usedPercent,
            resetsAt: reset)
    }

    private static func window(usedPercent: Double, reset: Date) -> RateWindow {
        RateWindow(
            usedPercent: usedPercent,
            windowMinutes: 300,
            resetsAt: reset,
            resetDescription: nil)
    }
}
