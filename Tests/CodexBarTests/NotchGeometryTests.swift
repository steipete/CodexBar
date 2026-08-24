import Foundation
import Testing
@testable import CodexBar

struct NotchGeometryTests {
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
