import AppKit
import Foundation
import SwiftUI
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct SpendSessionPerformanceTests {
    @Test
    func `dashboard filters timing samples by completion day and keeps providers separate`() throws {
        let now = try #require(CostUsageScanner.dateFromTimestamp("2026-05-10T12:00:00Z"))
        let today = try #require(CostUsageTurnPerformanceSample(
            completedAt: now,
            outputTokens: 100,
            durationMilliseconds: 1000,
            firstTokenMilliseconds: 100))
        let yesterday = try #require(CostUsageTurnPerformanceSample(
            completedAt: now.addingTimeInterval(-86400),
            outputTokens: 100,
            durationMilliseconds: 9000))
        for (provider, source) in [
            (UsageProvider.codex, SpendDashboardModel.SourceKind.native),
            (.claude, .native),
            (.codex, .openCodex),
        ] {
            let group = try Self.group(
                now: now,
                samples: [today, yesterday],
                provider: provider,
                source: source)
            let row = try #require(group.sessions.first)
            if provider == .codex, source == .native {
                #expect(row.turnPerformance?.sampleCount == 1)
                #expect(row.turnPerformance?.outputTokensPerSecond == 100)
                #expect(row.turnPerformance?.medianDurationMilliseconds == 1000)
            } else {
                #expect(row.turnPerformance == nil)
            }
        }
    }

    @Test
    func `selected chart day scopes native performance and clearing restores range statistics`() throws {
        let now = try #require(CostUsageScanner.dateFromTimestamp("2026-05-10T12:00:00Z"))
        let samples = try (0..<24).map { index in
            try #require(CostUsageTurnPerformanceSample(
                completedAt: now.addingTimeInterval(index < 12 ? -86400 : 0),
                outputTokens: 150 + index * 10,
                durationMilliseconds: 10000 + index * 500,
                firstTokenMilliseconds: 500 + index * 30,
                model: index.isMultiple(of: 2) ? "gpt-5.4" : "gpt-5",
                reasoningEffort: index.isMultiple(of: 2) ? "high" : "low",
                inputTokens: 1000,
                cachedInputTokens: 700 + (index % 4) * 50))
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        for selectedDay in [now, now.addingTimeInterval(-86400), nil] {
            let group = try Self.group(now: now, samples: samples, requestedDays: 7, selectedDay: selectedDay)
            let row = try #require(group.sessions.first)
            let summary = try #require(row.turnPerformance)
            let expected = selectedDay.map { day in
                samples.filter { calendar.isDate($0.completedAt, inSameDayAs: day) }
            } ?? samples
            #expect(summary == CostUsageTurnPerformanceSummary(samples: expected))
            #expect(summary.sampleCount == (selectedDay == nil ? 24 : 12))
            #expect(row.totalTokens == 3500)
            #expect(row.totalCost == 0.03)
            CodexBarLocalizationOverride.$appLanguage.withValue("en") {
                let p95 = spendSessionPerformanceDetailMetrics(summary).first { $0.id == "p95-duration" }
                #expect(p95?.value == (selectedDay == nil ? "21.0 s" : "—"))
                #expect((p95?.note == nil) == (selectedDay == nil))
            }
        }
        let emptyDay = try Self.group(
            now: now, samples: samples, requestedDays: 7, selectedDay: now.addingTimeInterval(-172_800))
        #expect(emptyDay.sessions.first?.turnPerformance == nil)
    }

    @Test
    func `completion day keeps native timing when file activity is outside the selected day`() throws {
        let now = try #require(CostUsageScanner.dateFromTimestamp("2026-05-10T12:00:00Z"))
        let sample = try #require(CostUsageTurnPerformanceSample(
            completedAt: now,
            outputTokens: 100,
            durationMilliseconds: 1000))
        let outsideWindow = try #require(CostUsageTurnPerformanceSample(
            completedAt: now.addingTimeInterval(-86400),
            outputTokens: 100,
            durationMilliseconds: 9000))
        for (provider, source) in [
            (UsageProvider.codex, SpendDashboardModel.SourceKind.native),
            (.claude, .native),
            (.codex, .openCodex),
        ] {
            let group = try Self.group(
                now: now,
                samples: [sample, outsideWindow],
                provider: provider,
                source: source,
                lastActivity: now.addingTimeInterval(86400))
            if provider == .codex, source == .native {
                #expect(group.sessions.count == 1)
                let row = try #require(group.sessions.first)
                #expect(row.turnPerformance?.sampleCount == 1)
                #expect(row.turnPerformance?.outputTokensPerSecond == 100)
                #expect(row.turnPerformance?.medianDurationMilliseconds == 1000)
                #expect(row.totalTokens == 3500)
                #expect(row.totalCost == 0.03)
            } else {
                #expect(group.sessions.isEmpty)
            }
        }
    }

    @Test
    func `metrics describe whole turn throughput and keep missing first token timing unavailable`() throws {
        let sample = try #require(CostUsageTurnPerformanceSample(
            completedAt: Date(),
            outputTokens: 20,
            durationMilliseconds: 10000))
        let summary = try #require(CostUsageTurnPerformanceSummary(samples: [sample]))
        CodexBarLocalizationOverride.$appLanguage.withValue("en") {
            let metrics = spendSessionPerformanceMetrics(summary)
            #expect(metrics.map(\.value) == ["—", "2.0 tok/s", "10.0 s", "—"])
            #expect(metrics[0].note == "First-token samples: 0 / 1")
            #expect(metrics[3].note == "0 / 1 turns with cache data")
        }
        CodexBarLocalizationOverride.$appLanguage.withValue("zh-Hans") {
            let metrics = spendSessionPerformanceMetrics(summary)
            #expect(metrics.map(\.value) == ["—", "2.0 tok/s", "10.0 秒", "—"])
        }
    }

    @Test
    func `details retain unavailable values and sample coverage`() throws {
        let sample = try #require(CostUsageTurnPerformanceSample(
            completedAt: Date(),
            outputTokens: 100,
            durationMilliseconds: 1000,
            inputTokens: 100,
            cachedInputTokens: 80))
        let summary = try #require(CostUsageTurnPerformanceSummary(samples: [sample]))
        CodexBarLocalizationOverride.$appLanguage.withValue("en") {
            let metrics = spendSessionPerformanceDetailMetrics(summary)
            #expect(metrics[0].value == "—")
            #expect(metrics[0].note != nil)
            #expect(metrics[1].value == "—")
            #expect(metrics[1].note != nil)
            let cachedInput = spendSessionPerformanceMetrics(summary).first { $0.id == "cached-input" }
            #expect(cachedInput?.value == "80.0%")
            #expect(cachedInput?.note == "1 / 1 turns with cache data")
            #expect(summary.firstTokenSampleCount == 0)
            #expect(summary.sampleCount == 1)
            #expect(summary.details.cacheSampleCount == 1)
        }
    }

    @Test
    func `primary observations distinguish measured zero cache reuse from missing records`() throws {
        let measured = try #require(CostUsageTurnPerformanceSample(
            completedAt: Date(),
            outputTokens: 300,
            durationMilliseconds: 1000,
            firstTokenMilliseconds: 100,
            inputTokens: 1000,
            cachedInputTokens: 0))
        let unrecorded = try #require(CostUsageTurnPerformanceSample(
            completedAt: Date(),
            outputTokens: 200,
            durationMilliseconds: 2000))
        let summary = try #require(CostUsageTurnPerformanceSummary(samples: [measured, unrecorded]))
        CodexBarLocalizationOverride.$appLanguage.withValue("en") {
            let metrics = spendSessionPerformanceMetrics(summary)
            #expect(metrics.map(\.value) == ["0.1 s", "166.7 tok/s", "1.5 s", "0.0%"])
            #expect(metrics[0].note == "First-token samples: 1 / 2")
            #expect(metrics.first(where: { $0.id == "cached-input" })?.note == "1 / 2 turns with cache data")
            #expect(!spendSessionPerformanceDetailMetrics(summary).contains { $0.id == "cached-input" })
        }
    }

    @Test
    func `render production session rows with synthetic timing`() throws {
        guard let path = ProcessInfo.processInfo.environment["CODEXBAR_PERFORMANCE_UI_PROOF_DIR"] else { return }
        let width = Double(ProcessInfo.processInfo.environment["CODEXBAR_PERFORMANCE_UI_PROOF_WIDTH"] ?? "") ?? 820
        let root = URL(
            fileURLWithPath: path,
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true)
        let now = try #require(CostUsageScanner.dateFromTimestamp("2026-05-10T12:00:00Z"))
        let sample = try #require(CostUsageTurnPerformanceSample(
            completedAt: now,
            outputTokens: 500,
            durationMilliseconds: 10000,
            firstTokenMilliseconds: 800,
            model: "gpt-5.4",
            reasoningEffort: "high",
            inputTokens: 1000,
            cachedInputTokens: 800))
        let group = try Self.group(
            now: now,
            samples: [sample, sample, sample])
        let untimedGroup = try Self.group(now: now, samples: [])
        #expect(untimedGroup.sessions.first?.turnPerformance == nil)
        let detailSummary = try #require(CostUsageTurnPerformanceSummary(samples: Array(repeating: sample, count: 20)))
        for language in ["en", "zh-Hans"] {
            for dark in [false, true] {
                try CodexBarLocalizationOverride.$appLanguage.withValue(language) {
                    let view = VStack(
                        alignment: .leading,
                        spacing: 12)
                    {
                        Text(L("Usage & Spend")).font(.title2.bold())
                        Text(L("Sessions")).font(.headline)
                        SpendSessionRows(
                            group: group,
                            hidePersonalInfo: false)
                        Divider()
                        SpendSessionRows(
                            group: group,
                            hidePersonalInfo: true)
                        Divider()
                        SpendSessionRows(group: untimedGroup, hidePersonalInfo: false)
                        Divider()
                        SpendSessionPerformanceDetailsView(summary: detailSummary)
                    }
                    .padding(20).frame(width: width)
                    .background(dark ? Color(
                        red: 0.12,
                        green: 0.12,
                        blue: 0.12) : .white)
                    .foregroundStyle(dark ? .white : .black)
                    .environment(\.colorScheme, dark ? .dark : .light)
                    let renderer = ImageRenderer(content: view)
                    renderer.scale = 2
                    let bitmap = try NSBitmapImageRep(cgImage: #require(renderer.cgImage))
                    try #require(bitmap.representation(
                        using: .png,
                        properties: [:]))
                        .write(to: root.appendingPathComponent("sessions-\(language)-\(dark ? "dark" : "light").png"))
                }
            }
        }
    }

    private static func group(
        now: Date,
        samples: [CostUsageTurnPerformanceSample],
        provider: UsageProvider = .codex,
        source: SpendDashboardModel.SourceKind = .native,
        lastActivity: Date? = nil,
        requestedDays: Int = 1,
        selectedDay: Date? = nil) throws
        -> SpendDashboardModel.CurrencyGroup
    {
        let sessions = [CostUsageSessionBreakdown(
            sessionID: "synthetic-session",
            lastActivity: lastActivity ?? now,
            inputTokens: 2000,
            cachedInputTokens: 1000,
            outputTokens: 1500,
            totalTokens: 3500,
            requestCount: 3,
            costUSD: 0.03,
            modelBreakdowns: [],
            projectPath: "/synthetic/project",
            projectName: "Example project",
            title: "Check performance",
            turnPerformanceSamples: samples)]
        let snapshot = CostUsageTokenSnapshot(
            sessionTokens: 3500,
            sessionCostUSD: 0.03,
            last30DaysTokens: 3500,
            last30DaysCostUSD: 0.03,
            daily: [.init(
                date: "2026-05-10",
                inputTokens: 2000,
                outputTokens: 1500,
                totalTokens: 3500,
                costUSD: 0.03,
                modelsUsed: nil,
                modelBreakdowns: nil)],
            sessions: sessions,
            updatedAt: now)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let model = SpendDashboardModel.build(
            inputs: [.init(
                provider: provider,
                displayName: "Codex",
                snapshot: snapshot,
                sourceKind: source)],
            requestedDays: requestedDays,
            now: now,
            calendar: calendar,
            selectedDay: selectedDay)
        return try #require(model.groups.first)
    }
}
