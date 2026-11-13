import AppKit
import SwiftUI
import Testing
@testable import CodexBar

@MainActor
struct UsageBarBatteryGeometryTests {
    private static let size = CGSize(width: 300, height: 10)

    @Test
    func `battery shell leaves room for the terminal nub inside the canvas`() {
        let body = UsageProgressBar.batteryBodyRect(size: Self.size)
        let nub = UsageProgressBar.batteryNubRect(size: Self.size)

        #expect(body == CGRect(x: 0.5, y: 0.5, width: 295.5, height: 9))
        #expect(nub == CGRect(x: 297.5, y: 3, width: 2.5, height: 4))
        #expect(nub.maxX <= Self.size.width)
        #expect(body.maxX < nub.minX)
    }

    @Test
    func `battery core is inset symmetrically inside the shell`() {
        let body = UsageProgressBar.batteryBodyRect(size: Self.size)
        let inner = UsageProgressBar.batteryInnerRect(size: Self.size)

        #expect(inner == CGRect(x: 2, y: 2, width: 292.5, height: 6))
        #expect(inner.minX - body.minX == body.maxX - inner.maxX)
        #expect(inner.minY - body.minY == body.maxY - inner.maxY)
    }

    @Test
    func `battery fill spans the core exactly at the rounded percent extremes`() {
        let inner = UsageProgressBar.batteryInnerRect(size: Self.size)

        #expect(UsageProgressBar.batteryFillWidth(percent: 0, size: Self.size) == 0)
        #expect(UsageProgressBar.batteryFillWidth(percent: 100, size: Self.size) == inner.width)
        // Sub-0.5% renders empty and 99.5%+ renders full, matching the capsule label contract.
        #expect(UsageProgressBar.batteryFillWidth(percent: 0.4, size: Self.size) == 0)
        #expect(UsageProgressBar.batteryFillWidth(percent: 99.6, size: Self.size) == inner.width)
    }

    @Test
    func `battery fill tracks the percent linearly across the core`() {
        let inner = UsageProgressBar.batteryInnerRect(size: Self.size)

        for percent in [10.0, 23.0, 42.0, 50.0, 67.0, 88.0] {
            let expected = inner.width * percent / 100
            let actual = UsageProgressBar.batteryFillWidth(percent: percent, size: Self.size)
            #expect(abs(actual - expected) < 0.0001)
        }
    }

    @Test
    func `battery fill clamps out-of-range percents`() {
        let inner = UsageProgressBar.batteryInnerRect(size: Self.size)

        #expect(UsageProgressBar.batteryFillWidth(percent: -20, size: Self.size) == 0)
        #expect(UsageProgressBar.batteryFillWidth(percent: 140, size: Self.size) == inner.width)
    }

    @Test(arguments: [40.0, 20.0, 10.0, 8.0])
    func `battery stays drawable at narrow widths`(width: Double) {
        let size = CGSize(width: width, height: 10)
        let inner = UsageProgressBar.batteryInnerRect(size: size)
        let nub = UsageProgressBar.batteryNubRect(size: size)

        #expect(inner.width > 0)
        #expect(inner.height > 0)
        #expect(nub.maxX <= size.width)
    }

    @Test
    func `battery core never reports a negative width at degenerate sizes`() {
        let inner = UsageProgressBar.batteryInnerRect(size: CGSize(width: 5, height: 10))

        #expect(inner.width >= 0)
    }

    @Test
    func `battery style is taller than the capsule so the shell stays legible`() {
        #expect(UsageProgressBar.barHeight(for: .battery) == 10)
        #expect(UsageProgressBar.barHeight(for: .capsule) == 6)
    }
}

@MainActor
struct UsageBarBatteryColorTests {
    @Test
    func `remaining level maps to the three iOS battery tiers`() {
        #expect(UsageProgressBar.batteryLevel(remainingPercent: 100) == .ample)
        #expect(UsageProgressBar.batteryLevel(remainingPercent: 50) == .ample)
        #expect(UsageProgressBar.batteryLevel(remainingPercent: 49.9) == .tight)
        #expect(UsageProgressBar.batteryLevel(remainingPercent: 20) == .tight)
        #expect(UsageProgressBar.batteryLevel(remainingPercent: 19.9) == .critical)
        #expect(UsageProgressBar.batteryLevel(remainingPercent: 0) == .critical)
    }

    @Test
    func `remaining level clamps out-of-range percents`() {
        #expect(UsageProgressBar.batteryLevel(remainingPercent: 140) == .ample)
        #expect(UsageProgressBar.batteryLevel(remainingPercent: -20) == .critical)
    }

    @Test
    func `used mode inverts the percent so red always means nearly exhausted`() {
        #expect(UsageProgressBar.batteryRemainingPercent(percent: 80, showsUsed: true) == 20)
        #expect(UsageProgressBar.batteryRemainingPercent(percent: 95, showsUsed: true) == 5)
        #expect(UsageProgressBar.batteryRemainingPercent(percent: 10, showsUsed: true) == 90)
        #expect(UsageProgressBar.batteryRemainingPercent(percent: 23, showsUsed: false) == 23)
    }

    @Test
    func `used mode clamps before inverting`() {
        #expect(UsageProgressBar.batteryRemainingPercent(percent: 140, showsUsed: true) == 0)
        #expect(UsageProgressBar.batteryRemainingPercent(percent: -20, showsUsed: true) == 100)
    }

    @Test
    func `severity colors use the iOS system palette`() {
        #expect(UsageProgressBar.batterySeverityColor(remainingPercent: 88) == Color(nsColor: .systemGreen))
        #expect(UsageProgressBar.batterySeverityColor(remainingPercent: 23) == Color(nsColor: .systemYellow))
        #expect(UsageProgressBar.batterySeverityColor(remainingPercent: 5) == Color(nsColor: .systemRed))
    }

    @Test
    func `a nearly exhausted used bar resolves to the critical tier`() {
        let remaining = UsageProgressBar.batteryRemainingPercent(percent: 95, showsUsed: true)

        #expect(UsageProgressBar.batteryLevel(remainingPercent: remaining) == .critical)
    }
}
