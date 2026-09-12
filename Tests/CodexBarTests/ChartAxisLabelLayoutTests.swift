import AppKit
import Foundation
import SwiftUI
import Testing
@testable import CodexBar

struct ChartAxisLabelLayoutTests {
    @Test(arguments: ["de_CH", "en_US", "fr_FR", "ja_JP", "ar", "hi_IN", "ru_RU"], Array(1...12))
    @MainActor
    func `plot edge padding fits localized caption dates`(localeIdentifier: String, month: Int) throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let date = try #require(calendar.date(from: DateComponents(year: 2026, month: month, day: 22)))
        let natural = Self.labelSize(date: date, localeIdentifier: localeIdentifier, proposedWidth: nil)

        #expect(natural.width > 0)
        #expect(natural.width <= ChartAxisLabelLayout.dateLabelEdgePadding * 2)
    }

    @Test(arguments: ["de_CH", "en_US"], [8, 9])
    @MainActor
    func `date labels keep their full width under narrow endpoint proposals`(
        localeIdentifier: String,
        month: Int) throws
    {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let date = try #require(calendar.date(from: DateComponents(year: 2026, month: month, day: 22)))
        for preformatted in [false, true] {
            let natural = Self.labelSize(
                date: date, localeIdentifier: localeIdentifier, proposedWidth: nil, preformatted: preformatted)
            let narrow = Self.labelSize(
                date: date, localeIdentifier: localeIdentifier, proposedWidth: 8, preformatted: preformatted)

            #expect(natural.width > 8)
            #expect(abs(narrow.width - natural.width) < 0.5)
            #expect(abs(narrow.height - natural.height) < 0.5)
        }
    }

    @MainActor
    private static func labelSize(
        date: Date,
        localeIdentifier: String,
        proposedWidth: CGFloat?,
        preformatted: Bool = false) -> CGSize
    {
        let text: Text
        if preformatted {
            var format: Date.FormatStyle = .dateTime.month(.abbreviated).day()
            format.locale = Locale(identifier: localeIdentifier)
            format.timeZone = .gmt
            text = Text(date.formatted(format))
        } else {
            text = Text(date, format: .dateTime.month(.abbreviated).day())
        }
        let root = LabelWidthProposal(width: proposedWidth) {
            ChartAxisLabelLayout.dateLabel(text)
        }
        .environment(\.locale, Locale(identifier: localeIdentifier))
        .environment(\.timeZone, .gmt)
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(x: 0, y: 0, width: 160, height: 40)
        hosting.layoutSubtreeIfNeeded()
        return hosting.fittingSize
    }

    @Test
    func `first date label center matches first bar center`() throws {
        let barCenter = try #require(ChartAxisLabelLayout.barCenterX(
            slotIndex: 0,
            slotCount: 16,
            chartWidth: 480))
        let labelCenter = ChartAxisLabelLayout.labelCenterX(
            tickX: barCenter,
            labelWidth: 44,
            anchor: ChartAxisLabelLayout.barCenteredAnchor)

        #expect(abs(labelCenter - barCenter) < 0.0001)
    }

    @Test
    func `last date label center matches last bar center`() throws {
        let barCenter = try #require(ChartAxisLabelLayout.barCenterX(
            slotIndex: 15,
            slotCount: 16,
            chartWidth: 480))
        let labelCenter = ChartAxisLabelLayout.labelCenterX(
            tickX: barCenter,
            labelWidth: 64,
            anchor: ChartAxisLabelLayout.barCenteredAnchor)

        #expect(abs(labelCenter - barCenter) < 0.0001)
    }
}

private struct LabelWidthProposal: Layout {
    let width: CGFloat?

    func sizeThatFits(proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        subviews[0].sizeThatFits(ProposedViewSize(width: self.width, height: nil))
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        subviews[0].place(
            at: bounds.origin,
            anchor: .topLeading,
            proposal: ProposedViewSize(width: self.width, height: nil))
    }
}
