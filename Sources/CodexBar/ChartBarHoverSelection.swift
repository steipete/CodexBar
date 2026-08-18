import Foundation

enum ChartBarHoverSelection {
    /// Shared by the BarMark and its hover frame so drawing and hit-testing cannot drift apart.
    static let barWidthRatio: CGFloat = 0.7

    struct Bar: Equatable {
        let index: Int
        let frame: CGRect
    }

    struct Selection: Equatable {
        let index: Int
        let highlightFrame: CGRect
    }

    static func calendarDayBars(
        dates: [Date],
        plotFrame: CGRect,
        calendar: Calendar = .current,
        position: (Date) -> CGFloat?) -> [Bar]?
    {
        let unitIntervals = dates.map { date -> ClosedRange<CGFloat>? in
            guard let interval = calendar.dateInterval(of: .day, for: date),
                  let startX = position(interval.start),
                  let endX = position(interval.end)
            else { return nil }
            return min(startX, endX)...max(startX, endX)
        }
        guard unitIntervals.allSatisfy({ $0 != nil }) else { return nil }
        return self.bars(
            plotFrame: plotFrame,
            unitIntervals: unitIntervals.compactMap(\.self))
    }

    static func bars(
        plotFrame: CGRect,
        unitIntervals: [ClosedRange<CGFloat>],
        widthRatio: CGFloat = ChartBarHoverSelection.barWidthRatio) -> [Bar]
    {
        guard plotFrame.width >= 0,
              plotFrame.height >= 0,
              widthRatio >= 0
        else { return [] }

        return unitIntervals.enumerated().map { index, interval in
            let width = (interval.upperBound - interval.lowerBound) * widthRatio
            let centerX = plotFrame.minX + (interval.lowerBound + interval.upperBound) / 2
            return Bar(
                index: index,
                frame: CGRect(
                    x: centerX - width / 2,
                    y: plotFrame.minY,
                    width: width,
                    height: plotFrame.height))
        }
    }

    static func selection(at location: CGPoint, plotFrame: CGRect, bars: [Bar]) -> Selection? {
        guard plotFrame.contains(location) else { return nil }
        let bar: Bar? = if bars.count == 1 {
            bars.first
        } else {
            bars.first { $0.frame.contains(location) }
        }
        return bar.map { Selection(index: $0.index, highlightFrame: $0.frame) }
    }

    static func accepts(distanceFromBarCenter: CGFloat, barHalfWidth: CGFloat, selectableCount: Int) -> Bool {
        selectableCount <= 1 || distanceFromBarCenter <= barHalfWidth
    }
}
