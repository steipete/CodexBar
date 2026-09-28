import AppKit
import Testing
@testable import CodexBar

@MainActor
struct MenuBarLayoutVisibilityTests {
    @Test(arguments: MenuBarLayoutSize.allCases, [NSAppearance.Name.aqua, .darkAqua])
    func `icon and percent paints both parts at regular and small sizes`(
        size: MenuBarLayoutSize, appearance: NSAppearance.Name) throws
    {
        let fixtures = MenuBarLayoutRendererTests()
        let options = MenuBarLayoutRenderOptions(
            size: size,
            highContrast: false,
            showUsed: true,
            conditionals: [],
            appearanceName: appearance.rawValue,
            isDebugApp: false,
            now: fixtures.now)
        let icon = try #require(ProviderBrandIcon.image(for: .codex))
        let output = MenuBarLayoutRenderer().render(
            layout: .defaultLayout, data: fixtures.data(), icon: icon, options: options)
        let button = NSButton(frame: NSRect(x: 0, y: 0, width: 100, height: 22))
        button.isBordered = false
        button.imageScaling = .scaleNone
        button.appearance = NSAppearance(named: appearance)
        let cell = try #require(button.cell)

        for gap in MenuBarLayoutGap.allCases {
            let width = StatusItemController.applyMenuBarLayoutContent(output, for: button, gap: gap)
            button.setFrameSize(NSSize(width: width, height: 22))
            #expect(width.isFinite && width >= 18)
            #expect(button.image === output.leadingIcon)
            #expect(button.imagePosition == .imageLeft)
            #expect(button.attributedTitle.string.contains("50%"))
            let imageRect = cell.imageRect(forBounds: button.bounds)
            let titleRect = cell.titleRect(forBounds: button.bounds)
            #expect(imageRect.width >= icon.size.width)
            #expect(titleRect.width > 0)

            for scale in [1, 2] {
                let context = try #require(CGContext(
                    data: nil,
                    width: Int(width) * scale,
                    height: 22 * scale,
                    bitsPerComponent: 8,
                    bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
                context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
                button.effectiveAppearance.performAsCurrentDrawingAppearance {
                    cell.draw(withFrame: button.bounds, in: button)
                }
                NSGraphicsContext.restoreGraphicsState()
                let bitmap = try NSBitmapImageRep(cgImage: #require(context.makeImage()))
                for rect in [imageRect, titleRect] {
                    var painted = 0
                    for y in 0..<bitmap.pixelsHigh {
                        for x in 0..<bitmap.pixelsWide {
                            let point = CGPoint(x: CGFloat(x) / CGFloat(scale), y: CGFloat(y) / CGFloat(scale))
                            if rect.contains(point), (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 {
                                painted += 1
                            }
                        }
                    }
                    #expect(painted > 10)
                }
                if let directory = ProcessInfo.processInfo.environment["CODEXBAR_LAYOUT_VISIBILITY_PROOF_DIR"] {
                    let name = "\(size.rawValue)-\(appearance.rawValue)-\(gap.rawValue)-\(scale)x.png"
                    let png = try #require(bitmap.representation(using: .png, properties: [:]))
                    try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
                }
            }
            print("LAYOUT_VISIBILITY size=\(size.rawValue) appearance=\(appearance.rawValue) "
                + "gap=\(gap.rawValue) width=\(width) height=22")
        }
    }
}
