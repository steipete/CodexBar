import AdaptiveReplayKit
import Foundation
import Testing

struct ReplayTraceSegmentationTests {
    private static let epoch = Date(timeIntervalSinceReferenceDate: 0)

    private func at(_ seconds: TimeInterval) -> Date {
        Self.epoch.addingTimeInterval(seconds)
    }

    private func decision(_ seconds: TimeInterval, delay: TimeInterval = 600) -> AdaptiveRefreshTraceRecord {
        .decision(
            timestamp: self.at(seconds),
            menuAgeSeconds: nil,
            lowPowerModeEnabled: false,
            thermalState: .nominal,
            reason: "longIdle",
            delaySeconds: delay)
    }

    @Test
    func `segmentation excludes only time beyond the expected deadline`() {
        let firstRun = stride(from: 0.0, through: 3000.0, by: 600.0).map { self.decision($0) }
        let secondRun = stride(from: 68400.0, through: 71400.0, by: 600.0).map { self.decision($0) }
        let trace = firstRun + secondRun + [.refreshCompleted(timestamp: self.at(72000))]

        let report = ReplayTraceSegmenter.automatic(trace)

        #expect(report.segments.count == 2)
        #expect(report.segments[0].start == self.at(0))
        #expect(report.segments[0].end == self.at(3600))
        #expect(report.segments[1].start == self.at(68400))
        #expect(report.segments[1].end == self.at(72000))
        #expect(report.excludedGapSeconds == 18 * 60 * 60)
        #expect(report.includedSpanSeconds == 2 * 60 * 60)
    }

    @Test
    func `segmented rate uses summed span instead of averaging segment rates`() {
        let firstRun = stride(from: 0.0, through: 3000.0, by: 600.0).map { self.decision($0) }
        let secondRun = stride(from: 68400.0, through: 71400.0, by: 600.0).map { self.decision($0) }
        let trace = firstRun + secondRun + [.refreshCompleted(timestamp: self.at(72000))]

        let metrics = ReplayEngine.runSegmented(trace: trace, policy: FixedIntervalPolicy(minutes: 10))

        #expect(metrics.totalRefreshCount == 12)
        #expect(metrics.simulatedSpanSeconds == 7200)
        #expect(metrics.refreshCountPer24h == 144)
        #expect(metrics.segmentCount == 2)
        #expect(metrics.excludedGapSeconds == 18 * 60 * 60)
    }

    @Test
    func `a normal scheduled wait remains in the preceding segment`() {
        let trace = [
            self.decision(0, delay: 1800),
            .menuOpen(timestamp: self.at(1700)),
            self.decision(4000, delay: 1800),
        ]

        let report = ReplayTraceSegmenter.automatic(trace)

        #expect(report.segments.count == 2)
        #expect(report.segments[0].end == self.at(1800))
        #expect(report.excludedGapSeconds == 2200)
    }

    @Test
    func `menu opens before the first recorded refresh are censored equally`() throws {
        let trace = [
            self.decision(0, delay: 600),
            .menuOpen(timestamp: self.at(100)),
            .refreshCompleted(timestamp: self.at(600)),
            self.decision(600, delay: 600),
            .menuOpen(timestamp: self.at(700)),
            .refreshCompleted(timestamp: self.at(1200)),
        ]

        let metrics = ReplayEngine.runSegmented(trace: trace, policy: FixedIntervalPolicy(minutes: 10))

        #expect(metrics.boundaryCensoredMenuOpenCount == 1)
        #expect(try #require(metrics.stalenessAtMenuOpen).sampleCount == 1)
    }

    @Test
    func `recorded refresh anchors staleness before a policy refresh`() throws {
        let trace = [
            self.decision(0, delay: 600),
            .refreshCompleted(timestamp: self.at(600)),
            .menuOpen(timestamp: self.at(700)),
            self.decision(1200, delay: 600),
        ]

        let metrics = ReplayEngine.runSegmented(trace: trace, policy: ManualPolicy())
        let staleness = try #require(metrics.stalenessAtMenuOpen)

        #expect(staleness.sampleCount == 1)
        #expect(staleness.mean == 100)
    }

    @Test
    func `recorded refresh supersedes an earlier simulated refresh`() throws {
        let trace = [
            self.decision(0, delay: 650),
            .refreshCompleted(timestamp: self.at(650)),
            .menuOpen(timestamp: self.at(700)),
            self.decision(1200, delay: 600),
        ]

        let metrics = ReplayEngine.runSegmented(trace: trace, policy: FixedIntervalPolicy(minutes: 10))
        let staleness = try #require(metrics.stalenessAtMenuOpen)

        #expect(staleness.sampleCount == 1)
        #expect(staleness.mean == 50)
    }
}
