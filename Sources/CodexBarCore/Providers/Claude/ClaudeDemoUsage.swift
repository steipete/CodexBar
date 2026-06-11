import Foundation

/// Demo / "troll" data source for the Claude provider.
///
/// This synthesises a fully-formed ``ClaudeAdminAPIUsageSnapshot`` with inflated
/// spend so the menu bar renders a believable Admin-API dashboard (Today / 7d /
/// 30d spend, daily bar chart, top model) WITHOUT any real Anthropic credentials.
///
/// It exists to demonstrate that a usage screenshot is just locally-rendered
/// numbers: whoever controls the data source controls the screenshot.
///
/// Activation (checked in this order):
///   1. Environment variable `CODEXBAR_DEMO_CLAUDE_SPEND` (its value is the multiplier).
///   2. Marker file `~/.codexbar-demo-claude` (its contents, if numeric, are the multiplier).
///
/// The marker file is the reliable path because the app is launched via `open`,
/// which does not inherit the shell environment.
public enum ClaudeDemoUsage {
    /// Baseline figures taken verbatim from the screenshot being parodied
    /// (steipete's CodexBar OpenAI-API card). The multiplier scales all of them.
    private static let baselineToday = 19_985.84
    private static let baselineLast7 = 249_661.09
    private static let baselineLast30 = 1_305_088.81
    private static let baselineTokens30 = 603_000_000_000.0

    private static let markerFileName = ".codexbar-demo-claude"
    private static let environmentKey = "CODEXBAR_DEMO_CLAUDE_SPEND"

    /// Returns the active demo multiplier, or `nil` when demo mode is off.
    public static func activeMultiplier(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> Double?
    {
        if let raw = environment[self.environmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty
        {
            return Double(raw) ?? 3.0
        }
        let marker = homeDirectory.appendingPathComponent(self.markerFileName)
        guard let contents = try? String(contentsOf: marker, encoding: .utf8) else {
            return nil
        }
        let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        return Double(trimmed) ?? 3.0
    }

    /// Builds the synthetic snapshot. `multiplier` scales the parodied baseline
    /// (e.g. `3` => "I burn 3x more, and in Anthropic Claude credits").
    public static func makeSnapshot(
        multiplier: Double,
        now: Date = Date(),
        calendar: Calendar? = nil) -> ClaudeAdminAPIUsageSnapshot
    {
        let calendar = calendar ?? Self.utcCalendar
        let days = 30
        let todayCost = self.baselineToday * multiplier
        let last7Cost = self.baselineLast7 * multiplier
        let last30Cost = self.baselineLast30 * multiplier
        let tokens30 = self.baselineTokens30 * multiplier

        // Shape that mimics the screenshot: a tall peak left-of-centre, a smaller
        // secondary bump near the end, and a comparatively quiet "today".
        func gauss(_ x: Double, _ mu: Double, _ sigma: Double) -> Double {
            exp(-pow(x - mu, 2) / (2 * sigma * sigma))
        }
        let weights = (0..<days).map { index -> Double in
            let x = Double(index)
            return gauss(x, 11, 4.5) + 0.4 * gauss(x, 24, 2.8) + 0.05
        }

        let todayIndex = days - 1
        let recentRange = (days - 7)..<(days - 1) // last 6 days excluding today
        let olderRange = 0..<(days - 7)           // everything before the trailing week

        // Distribute the spend so the headline KPIs land on exactly multiplier x baseline.
        let olderTarget = max(0, last30Cost - last7Cost)
        let recentTarget = max(0, last7Cost - todayCost)
        let olderWeight = olderRange.reduce(0.0) { $0 + weights[$1] }
        let recentWeight = recentRange.reduce(0.0) { $0 + weights[$1] }

        var cost = [Double](repeating: 0, count: days)
        for i in olderRange { cost[i] = olderWeight > 0 ? weights[i] / olderWeight * olderTarget : 0 }
        for i in recentRange { cost[i] = recentWeight > 0 ? weights[i] / recentWeight * recentTarget : 0 }
        cost[todayIndex] = todayCost

        let tokenScale = last30Cost > 0 ? tokens30 / last30Cost : 0
        let startOfToday = calendar.startOfDay(for: now)

        let buckets: [ClaudeAdminAPIUsageSnapshot.DailyBucket] = (0..<days).map { index in
            let dayCost = cost[index]
            let start = calendar.date(byAdding: .day, value: -(days - 1 - index), to: startOfToday) ?? startOfToday
            let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start

            let dayTokens = Int((dayCost * tokenScale).rounded())
            let input = Int(Double(dayTokens) * 0.28)
            let cacheCreation = Int(Double(dayTokens) * 0.08)
            let cacheRead = Int(Double(dayTokens) * 0.52)
            let output = Int(Double(dayTokens) * 0.12)

            let models = self.modelSplit(
                input: input,
                cacheCreation: cacheCreation,
                cacheRead: cacheRead,
                output: output)
            let costItems = self.costSplit(total: dayCost)

            return ClaudeAdminAPIUsageSnapshot.DailyBucket(
                day: self.dayKey(from: start, calendar: calendar),
                startTime: start,
                endTime: end,
                costUSD: dayCost,
                inputTokens: input,
                cacheCreationInputTokens: cacheCreation,
                cacheReadInputTokens: cacheRead,
                outputTokens: output,
                totalTokens: input + cacheCreation + cacheRead + output,
                costItems: costItems,
                models: models)
        }

        return ClaudeAdminAPIUsageSnapshot(daily: buckets, updatedAt: now)
    }

    // Opus carries the lion's share so it surfaces as "Top model".
    private static let modelMix: [(name: String, share: Double)] = [
        ("claude-opus-4-8", 0.55),
        ("claude-sonnet-4-6", 0.30),
        ("claude-haiku-4-5", 0.15),
    ]

    private static func modelSplit(
        input: Int,
        cacheCreation: Int,
        cacheRead: Int,
        output: Int) -> [ClaudeAdminAPIUsageSnapshot.ModelBreakdown]
    {
        self.modelMix.map { model in
            let mIn = Int(Double(input) * model.share)
            let mCacheCreation = Int(Double(cacheCreation) * model.share)
            let mCacheRead = Int(Double(cacheRead) * model.share)
            let mOut = Int(Double(output) * model.share)
            return ClaudeAdminAPIUsageSnapshot.ModelBreakdown(
                name: model.name,
                inputTokens: mIn,
                cacheCreationInputTokens: mCacheCreation,
                cacheReadInputTokens: mCacheRead,
                outputTokens: mOut,
                totalTokens: mIn + mCacheCreation + mCacheRead + mOut)
        }
    }

    private static func costSplit(total: Double) -> [ClaudeAdminAPIUsageSnapshot.CostBreakdown] {
        self.modelMix.map { model in
            ClaudeAdminAPIUsageSnapshot.CostBreakdown(name: model.name, costUSD: total * model.share)
        }
    }

    private static func dayKey(from date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
}
