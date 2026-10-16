import AppKit
import SwiftUI
import Testing
@testable import CodexBar

@MainActor
struct CostHistoryMenuScrollViewTests {
    @Test(arguments: [200.0, 1400.0])
    func `native row height is bounded while the document keeps its full extent`(height: Double) {
        let expectedHeight = CGFloat(height)
        let hosting = MenuHostingView(rootView: Color.clear.frame(width: 400, height: expectedHeight))
        let viewport = CostHistoryMenuScrollView(hosting: hosting, width: 400, maximumHeight: 620)
        #expect(viewport.intrinsicContentSize.height == min(expectedHeight, 620))
        #expect(viewport.fittingSize.height == min(expectedHeight, 620))
        #expect(hosting.frame.height == expectedHeight)
        #expect(viewport.scrollerStyle == .overlay)
        #expect(viewport.contentSize.width == 400)
    }

    @Test
    func `content height changes resize the existing native row at the same width`() {
        let hosting = MenuHostingView(rootView: Color.clear)
        let viewport = CostHistoryMenuScrollView(hosting: hosting, width: 400, maximumHeight: 620)
        for value in [360.0, 318.0, 900.0, 318.0, 360.0] {
            let height = CGFloat(value)
            viewport.updateDocumentHeight(height)
            #expect(viewport.documentView === hosting)
            #expect(hosting.frame.height == height)
            #expect(hosting.intrinsicContentSize.height == height)
            #expect(viewport.fittingHeight(width: 400) == min(height, 620))
            #expect(viewport.intrinsicContentSize.height == min(height, 620))
            #expect(viewport.frame.width == 400)
        }
    }

    @Test(arguments: [359.0, 360.0, 500.0])
    func `only menus without enough room below their anchor reserve the largest layout`(available: Double) {
        let hosting = MenuHostingView(rootView: Color.clear.frame(width: 400, height: 318))
        let viewport = CostHistoryMenuScrollView(
            hosting: hosting,
            width: 400,
            maximumHeight: 620,
            maximumHeightGrowth: 42,
            availableHeightBelowAnchor: CGFloat(available))
        let constrained = available < 360
        #expect(viewport.frame.height == (constrained ? 360 : 318))
        for height in [360.0, 318.0, 360.0, 318.0] {
            viewport.updateDocumentHeight(CGFloat(height))
            #expect(viewport.fittingHeight(width: 400) == (constrained ? 360 : CGFloat(height)))
            #expect(hosting.frame.height == CGFloat(height))
            #expect(hosting.convert(NSPoint.zero, to: viewport).y == 0)
        }
    }

    @Test
    func `reserved menu height stays bounded and can adapt when reopened at another anchor`() {
        let hosting = MenuHostingView(rootView: Color.clear.frame(width: 400, height: 600))
        let viewport = CostHistoryMenuScrollView(
            hosting: hosting,
            width: 400,
            maximumHeight: 620,
            maximumHeightGrowth: 200,
            availableHeightBelowAnchor: 610)
        #expect(viewport.frame.height == 620)
        viewport.updateSize(width: 400, maximumHeight: 620, availableHeightBelowAnchor: 800)
        #expect(viewport.frame.height == 600)
        viewport.updateSize(width: 400, maximumHeight: 620, availableHeightBelowAnchor: 610)
        #expect(viewport.frame.height == 620)
        #expect(hosting.frame.height == 600)
    }

    @Test
    func `growth makes room before publishing expanded content`() {
        let hosting = MenuHostingView(rootView: Color.clear.frame(width: 400, height: 318))
        let viewport = CostHistoryMenuScrollView(hosting: hosting, width: 400, maximumHeight: 620)
        var published = false
        viewport.adjustDocumentHeight(by: 42) {
            #expect(viewport.frame.height == 360)
            published = true
        }
        #expect(published)
        #expect(hosting.frame.height == 360)
        #expect(viewport.documentView === hosting)
    }

    @Test
    func `repeated sizing preserves document identity and intentional scroll position`() {
        let hosting = MenuHostingView(rootView: Color.clear.frame(width: 400, height: 1400))
        let viewport = CostHistoryMenuScrollView(hosting: hosting, width: 400, maximumHeight: 620)
        viewport.contentView.scroll(to: NSPoint(x: 0, y: 100))
        viewport.reflectScrolledClipView(viewport.contentView)
        let origin = viewport.contentView.bounds.origin
        viewport.updateSize(width: 400, maximumHeight: 620)
        #expect(viewport.documentView === hosting)
        #expect(viewport.contentView.bounds.origin == origin)
        #expect(viewport.fittingHeight(width: 400) == 620)
        #expect(viewport.contentView.bounds.origin == origin)
        viewport.updateSize(width: 400, maximumHeight: 400)
        #expect(viewport.documentView === hosting)
        #expect(viewport.intrinsicContentSize.height == 400)
        #expect(hosting.frame.height == 1400)
        #expect(viewport.contentView.bounds.origin == origin)
    }
}
