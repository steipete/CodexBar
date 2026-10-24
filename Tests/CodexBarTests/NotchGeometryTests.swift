import Foundation
import Testing
@testable import CodexBar

struct NotchGeometryTests {
    @Test(arguments: [CGFloat(0), 32, 200, 800])
    func `screen clamping keeps both scroll viewports accessible`(available: CGFloat) {
        let heights = NotchGeometry.sectionHeights(
            availableHeight: available, providerHeight: 500, sessionHeight: 1000)
        #expect(heights.providers + heights.sessions <= available + 0.000001)
        #expect(heights.providers <= 500)
        #expect(heights.sessions <= 1000)
        if available > 0 {
            #expect(heights.providers > 0)
            #expect(heights.sessions > 0)
        }
    }

    @Test
    func `sections preserve natural heights when they fit and absent sections reserve no space`() {
        let small = NotchGeometry.sectionHeights(availableHeight: 800, providerHeight: 100, sessionHeight: 200)
        #expect(small.providers == 100)
        #expect(small.sessions == 200)
        let onlyProviders = NotchGeometry.sectionHeights(availableHeight: 300, providerHeight: 500, sessionHeight: 0)
        #expect(onlyProviders.providers == 300)
        #expect(onlyProviders.sessions == 0)
        let onlySessions = NotchGeometry.sectionHeights(availableHeight: 300, providerHeight: 0, sessionHeight: 500)
        #expect(onlySessions.providers == 0)
        #expect(onlySessions.sessions == 300)
    }

    @Test(arguments: [CGPoint.zero, CGPoint(x: 1512, y: 100), CGPoint(x: -1800, y: -982)])
    func `expanded content never overlaps either menu bar area`(origin: CGPoint) throws {
        let screen = CGRect(origin: origin, size: CGSize(width: 1512, height: 982))
        let notch = try #require(NotchGeometry.notchRect(
            screenFrame: screen,
            topInset: 32,
            auxiliaryTopLeftWidth: 656,
            auxiliaryTopRightWidth: 656))
        let frame = NotchGeometry.expandedContentFrame(
            screenFrame: screen,
            notchRect: notch,
            contentSize: CGSize(width: 875, height: 283))
        let leftMenu = CGRect(x: screen.minX, y: notch.minY, width: 656, height: 32)
        let rightMenu = CGRect(x: notch.maxX, y: notch.minY, width: 656, height: 32)

        #expect(frame.maxY <= notch.minY)
        #expect(!frame.intersects(leftMenu))
        #expect(!frame.intersects(rightMenu))
        #expect(screen.contains(frame))
        #expect(frame.size == CGSize(width: 875, height: 283))

        let expanded = NotchGeometry.expandedPanelFrame(contentFrame: frame, notchRect: notch, showsEars: true)
        let cutout = NotchGeometry.notchFrameInPanel(panelFrame: expanded, notchRect: notch)
        #expect(expanded.minY == frame.minY)
        #expect(expanded.maxY == screen.maxY)
        #expect(expanded.minX == frame.minX)
        #expect(expanded.width == frame.width)
        #expect(expanded.height == frame.height + notch.height)
        #expect(screen.contains(expanded))
        #expect(cutout.offsetBy(dx: expanded.minX, dy: expanded.minY) == notch)
        #expect(NotchGeometry.expandedPanelFrame(contentFrame: frame, notchRect: notch, showsEars: false) == frame)
    }

    @Test
    func `unified popover reserves the real camera position when the display clamps its width`() throws {
        let screen = CGRect(x: -1512, y: 100, width: 1512, height: 982)
        let notch = try #require(NotchGeometry.notchRect(
            screenFrame: screen,
            topInset: 32,
            auxiliaryTopLeftWidth: 500,
            auxiliaryTopRightWidth: 812))
        let content = NotchGeometry.expandedContentFrame(
            screenFrame: screen, notchRect: notch, contentSize: CGSize(width: 10000, height: 500))
        let panel = NotchGeometry.expandedPanelFrame(contentFrame: content, notchRect: notch, showsEars: true)
        let cutout = NotchGeometry.notchFrameInPanel(panelFrame: panel, notchRect: notch)
        #expect(cutout.minX == 500)
        #expect(cutout.width == 200)
        #expect(cutout.midX != panel.width / 2)
        #expect(panel.maxY == screen.maxY)
        #expect(panel.minY == content.minY)
        #expect(panel.height == content.height + notch.height)
    }

    @Test
    func `oversized content stays below the menu strip and within the display`() throws {
        let screen = CGRect(x: -1512, y: 100, width: 1512, height: 982)
        let notch = try #require(NotchGeometry.notchRect(
            screenFrame: screen,
            topInset: 32,
            auxiliaryTopLeftWidth: 656,
            auxiliaryTopRightWidth: 656))
        let frame = NotchGeometry.expandedContentFrame(
            screenFrame: screen,
            notchRect: notch,
            contentSize: CGSize(width: 10000, height: 10000))

        #expect(frame.maxY <= notch.minY)
        #expect(screen.contains(frame))
        #expect(frame.width == screen.width - 16)
        #expect(frame.height <= screen.height * 0.9)
    }

    @Test
    func `returns nil without a top safe area`() {
        #expect(NotchGeometry.notchRect(
            screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            topInset: 0,
            auxiliaryTopLeftWidth: 656,
            auxiliaryTopRightWidth: 656) == nil)
    }

    @Test
    func `returns nil when an auxiliary area is unavailable`() {
        #expect(NotchGeometry.notchRect(
            screenFrame: .init(x: 0, y: 0, width: 1512, height: 982),
            topInset: 32,
            auxiliaryTopLeftWidth: nil,
            auxiliaryTopRightWidth: 656) == nil)
        #expect(NotchGeometry.notchRect(
            screenFrame: .init(x: 0, y: 0, width: 1512, height: 982),
            topInset: 32,
            auxiliaryTopLeftWidth: 656,
            auxiliaryTopRightWidth: nil) == nil)
    }

    @Test
    func `returns nil when auxiliary areas consume the whole frame`() {
        #expect(NotchGeometry.notchRect(
            screenFrame: .init(x: 0, y: 0, width: 100, height: 500),
            topInset: 32,
            auxiliaryTopLeftWidth: 50,
            auxiliaryTopRightWidth: 50) == nil)
    }

    @Test
    func `preserves a secondary display origin`() throws {
        let rect = try #require(NotchGeometry.notchRect(
            screenFrame: CGRect(x: 1512, y: 100, width: 1512, height: 982),
            topInset: 32,
            auxiliaryTopLeftWidth: 656,
            auxiliaryTopRightWidth: 656))

        #expect(rect == CGRect(x: 2168, y: 1050, width: 200, height: 32))
    }
}
