import AppKit
import CodexBarCore
import Testing
@testable import CodexBar

@MainActor
struct IconRendererEmptySecondaryTests {
    private func lowerMeterRows(weekly: Double, credits: Double? = nil, style: IconStyle) throws -> [Int] {
        let image = IconRenderer.makeIcon(
            primaryRemaining: 0,
            weeklyRemaining: weekly,
            creditsRemaining: credits,
            stale: false,
            style: style,
            hideCritters: true)
        let bitmap = try #require(image.representations.compactMap { $0 as? NSBitmapImageRep }.first {
            $0.pixelsWide == 36 && $0.pixelsHigh == 36
        })
        // The taller credits meter reaches row 22; only inspect the secondary lane below it.
        return (23..<36).filter { y in
            (0..<36).contains { x in
                (bitmap.colorAt(x: x, y: y) ?? .clear).alphaComponent > 0.01
            }
        }
    }

    @Test(arguments: [IconStyle(provider: .opencodego), .codex, .claude, .cursor])
    func `empty secondary keeps the same height and position as a filled secondary`(style: IconStyle) throws {
        // Zero is also a fresh weekly window when the user chooses Show usage as used.
        let empty = try self.lowerMeterRows(weekly: 0, style: style)
        let filled = try self.lowerMeterRows(weekly: 100, style: style)
        #expect(empty.count == 8)
        #expect(empty == filled)
    }

    @Test(arguments: [0.0, 500.0])
    func `credits meter retains its compact empty secondary lane`(credits: Double) throws {
        let rows = try self.lowerMeterRows(weekly: 0, credits: credits, style: .codex)
        #expect(rows.count == 6)
    }
}
