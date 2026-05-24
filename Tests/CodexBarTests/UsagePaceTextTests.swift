import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct UsagePaceTextTests {
    private static let localizedKeys: [String] = [
        "Pace: %@",
        "Pace: %@ · %@",
        "On pace",
        "%d%% in deficit",
        "%d%% in reserve",
        "Lasts until reset",
        "Projected empty now",
        "Projected empty in %@",
        "Runs out now",
        "Runs out in %@",
        "≈ %d%% run-out risk",
        "%@ · %@",
    ]

    @Test
    func `weekly pace detail provides left right labels`() throws {
        let now = Date(timeIntervalSince1970: 0)
        let window = RateWindow(
            usedPercent: 50,
            windowMinutes: 10080,
            resetsAt: now.addingTimeInterval(4 * 24 * 3600),
            resetDescription: nil)
        let pace = try #require(UsagePace.weekly(window: window, now: now))

        let detail = UsagePaceText.weeklyDetail(pace: pace, now: now)

        #expect(detail.leftLabel == "7% in deficit")
        #expect(detail.rightLabel == "Runs out in 3d")
    }

    @Test
    func `weekly pace detail reports lasts until reset`() throws {
        let now = Date(timeIntervalSince1970: 0)
        let window = RateWindow(
            usedPercent: 10,
            windowMinutes: 10080,
            resetsAt: now.addingTimeInterval(4 * 24 * 3600),
            resetDescription: nil)
        let pace = try #require(UsagePace.weekly(window: window, now: now))

        let detail = UsagePaceText.weeklyDetail(pace: pace, now: now)

        #expect(detail.leftLabel == "33% in reserve")
        #expect(detail.rightLabel == "Lasts until reset")
    }

    @Test
    func `weekly pace summary formats single line text`() throws {
        let now = Date(timeIntervalSince1970: 0)
        let window = RateWindow(
            usedPercent: 50,
            windowMinutes: 10080,
            resetsAt: now.addingTimeInterval(4 * 24 * 3600),
            resetDescription: nil)
        let pace = try #require(UsagePace.weekly(window: window, now: now))

        let summary = UsagePaceText.weeklySummary(pace: pace, now: now)

        #expect(summary == "Pace: 7% in deficit · Runs out in 3d")
    }

    @Test
    func `weekly pace detail formats rounded risk when available`() {
        let now = Date(timeIntervalSince1970: 0)
        let pace = UsagePace(
            stage: .ahead,
            deltaPercent: 8,
            expectedUsedPercent: 42,
            actualUsedPercent: 50,
            etaSeconds: 2 * 24 * 3600,
            willLastToReset: false,
            runOutProbability: 0.683)

        let detail = UsagePaceText.weeklyDetail(pace: pace, now: now)

        #expect(detail.rightLabel == "Runs out in 2d · ≈ 70% run-out risk")
    }

    // MARK: - Session pace (5-hour window)

    @Test
    func `session pace detail provides left right labels`() {
        let now = Date(timeIntervalSince1970: 0)
        // 300-minute window, 2h remaining => 3h elapsed out of 5h
        // expected = 60%, actual = 80% => 20% ahead (in deficit)
        let window = RateWindow(
            usedPercent: 80,
            windowMinutes: 300,
            resetsAt: now.addingTimeInterval(2 * 3600),
            resetDescription: nil)

        let detail = UsagePaceText.sessionDetail(provider: .claude, window: window, now: now)

        #expect(detail != nil)
        #expect(detail?.leftLabel == "20% in deficit")
        #expect(detail?.rightLabel == "Projected empty in 45m")
        #expect(detail?.stage == .farAhead)
    }

    @Test
    func `session pace detail reports lasts until reset`() {
        let now = Date(timeIntervalSince1970: 0)
        // 300-minute window, 2h remaining => 3h elapsed
        // expected = 60%, actual = 10% => far behind (in reserve)
        let window = RateWindow(
            usedPercent: 10,
            windowMinutes: 300,
            resetsAt: now.addingTimeInterval(2 * 3600),
            resetDescription: nil)

        let detail = UsagePaceText.sessionDetail(provider: .claude, window: window, now: now)

        #expect(detail != nil)
        #expect(detail?.leftLabel == "50% in reserve")
        #expect(detail?.rightLabel == "Lasts until reset")
    }

    @Test
    func `session pace summary formats single line text`() {
        let now = Date(timeIntervalSince1970: 0)
        let window = RateWindow(
            usedPercent: 80,
            windowMinutes: 300,
            resetsAt: now.addingTimeInterval(2 * 3600),
            resetDescription: nil)

        let summary = UsagePaceText.sessionSummary(provider: .claude, window: window, now: now)

        #expect(summary == "Pace: 20% in deficit · Projected empty in 45m")
    }

    @Test
    func `session pace detail supports Ollama five hour window`() {
        let now = Date(timeIntervalSince1970: 0)
        let window = RateWindow(
            usedPercent: 80,
            windowMinutes: 300,
            resetsAt: now.addingTimeInterval(2 * 3600),
            resetDescription: nil)

        let detail = UsagePaceText.sessionDetail(provider: .ollama, window: window, now: now)

        #expect(detail?.leftLabel == "20% in deficit")
        #expect(detail?.rightLabel == "Projected empty in 45m")
    }

    @Test
    func `session pace detail hides for unsupported provider`() {
        let now = Date(timeIntervalSince1970: 0)
        let window = RateWindow(
            usedPercent: 50,
            windowMinutes: 300,
            resetsAt: now.addingTimeInterval(2 * 3600),
            resetDescription: nil)

        let detail = UsagePaceText.sessionDetail(provider: .zai, window: window, now: now)

        #expect(detail == nil)
    }

    @Test
    func `session pace detail hides when reset is missing`() {
        let now = Date(timeIntervalSince1970: 0)
        let window = RateWindow(
            usedPercent: 50,
            windowMinutes: 300,
            resetsAt: nil,
            resetDescription: nil)

        let detail = UsagePaceText.sessionDetail(provider: .claude, window: window, now: now)

        #expect(detail == nil)
    }

    @Test
    func `usage pace text localization keys exist in en and zh Hans with matching placeholders`() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let enURL = root.appendingPathComponent("Sources/CodexBar/Resources/en.lproj/Localizable.strings")
        let zhURL = root.appendingPathComponent("Sources/CodexBar/Resources/zh-Hans.lproj/Localizable.strings")

        let en = try Self.readStringsTable(at: enURL)
        let zh = try Self.readStringsTable(at: zhURL)

        for key in Self.localizedKeys {
            let enValue = try #require(en[key], "Missing en key: \(key)")
            let zhValue = try #require(zh[key], "Missing zh-Hans key: \(key)")
            #expect(
                Self.placeholderTokens(in: enValue) == Self.placeholderTokens(in: zhValue),
                "Placeholder mismatch for key '\(key)': en='\(enValue)' zh='\(zhValue)'")
        }
    }

    private static func readStringsTable(at url: URL) throws -> [String: String] {
        guard let dict = NSDictionary(contentsOf: url) as? [String: String] else {
            throw NSError(
                domain: "UsagePaceTextTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to parse strings file at \(url.path)"])
        }
        return dict
    }

    private static func placeholderTokens(in value: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: "%(?:\\d+\\$)?[@dDuUxXfFeEgGcCsSpaA]") else {
            return []
        }
        let nsRange = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex
            .matches(in: value, options: [], range: nsRange)
            .compactMap { Range($0.range, in: value).map { String(value[$0]) } }
    }
}
