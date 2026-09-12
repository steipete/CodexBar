import AppKit
import Testing
@testable import CodexBar

@MainActor
struct IconRendererGrokTests {
    @Test
    func `icon renderer grok visor and antennae use expected grid positions`() {
        let image = IconRenderer.makeIcon(
            primaryRemaining: 50,
            weeklyRemaining: 50,
            creditsRemaining: nil,
            stale: false,
            style: .grok)

        let bitmapReps = image.representations.compactMap { $0 as? NSBitmapImageRep }
        let rep = bitmapReps.first(where: { $0.pixelsWide == 36 && $0.pixelsHigh == 36 })
        #expect(rep != nil)
        guard let rep else { return }

        func alphaAt(px x: Int, _ y: Int) -> CGFloat {
            (rep.colorAt(x: x, y: y) ?? .clear).alphaComponent
        }

        func alphaAtEitherOrigin(px x: Int, _ y: Int) -> CGFloat {
            max(alphaAt(px: x, y), alphaAt(px: x, (rep.pixelsHigh - 1) - y))
        }

        func minAlphaAtEitherOrigin(px x: Int, _ y: Int) -> CGFloat {
            min(alphaAt(px: x, y), alphaAt(px: x, (rep.pixelsHigh - 1) - y))
        }

        #expect(alphaAtEitherOrigin(px: 10, 32) > 0.9)
        #expect(alphaAtEitherOrigin(px: 26, 32) > 0.9)
        #expect(minAlphaAtEitherOrigin(px: 18, 25) < 0.05)
    }
}
