import AppKit
import CodexBarCore
import SwiftUI
import Testing
@testable import CodexBar

@MainActor
struct MenuBarLayoutCircleTests {
    nonisolated static let windows: [PercentWindow] = [.session, .weekly, .scopedWeekly, .automatic]

    @Test
    func `circle choices appear in palette and conditional branches with provider labels`() {
        for window in Self.windows {
            let token = MenuBarLayoutToken.iconUsageCircle(window: window)
            #expect(MenuBarLayoutPaletteTokens.usage(provider: .codex, snapshot: nil).contains(token))
            #expect(MenuBarLayoutPaletteTokens.conditionalBranch.contains(token))
            #expect(token.editorLabel(provider: .codex).contains(L("Icon usage circle")))
            #expect(token.v7Compatible == .progressBar(window: window))
        }
        #expect(MenuBarLayoutToken.iconUsageCircle(window: .session).editorLabel(provider: .kimi)
            .replacingOccurrences(of: L("Icon usage circle"), with: "")
            == MenuBarLayoutToken.progressBar(window: .session).editorLabel(provider: .kimi)
            .replacingOccurrences(of: L("menu_bar_layout_token_bar"), with: ""))
    }

    @Test
    func `circles persist in V8 and older keys contain readable bars`() throws {
        let defaults = InMemoryUserDefaults()
        let settings = testSettingsStore(suiteName: #function, userDefaults: defaults)
        let layout = MenuBarLayout(lines: [Self.windows.map { .iconUsageCircle(window: $0) }])
        settings.setMenuBarLayout(layout, for: nil)
        settings.setMenuBarLayout(layout, for: .claude)
        let decoder = JSONDecoder()
        #expect(try decoder.decode(MenuBarLayout.self, from: #require(defaults.data(forKey: "menuBarLayoutV8")))
            == layout)
        let bars = layout.v7Compatible()
        #expect(try decoder.decode(MenuBarLayout.self, from: #require(defaults.data(forKey: "menuBarLayoutV7")))
            == bars)
        let reloaded = testSettingsStore(suiteName: "circle-reload", userDefaults: defaults)
        #expect(reloaded.menuBarLayout == layout)
        #expect(reloaded.menuBarLayoutOverrides[.claude] == layout)
        #expect(MenuBarLayoutPersistence.preferredLayout(current: layout, v7: bars, legacy: nil) == layout)
        #expect(MenuBarLayoutPersistence.preferredLayout(current: layout, v7: .defaultLayout, legacy: nil)
            == .defaultLayout)
        let rule = MenuBarLayoutConditional(
            name: "Circle", clauses: [], thenToken: .iconUsageCircle(window: .weekly), elseToken: .hidden)
        let blobs = try MenuBarLayoutPersistence.encodedLibrary([rule])
        #expect(try decoder.decode([MenuBarLayoutConditional].self, from: blobs.current) == [rule])
        #expect(try decoder.decode([MenuBarLayoutConditional].self, from: blobs.v7) == [rule.v7Compatible])
        #expect(MenuBarLayoutPersistence.preferredLibrary(
            current: [rule], v7: [rule.v7Compatible], legacy: nil) == [rule])
        settings.menuBarLayoutConditionals = [rule]
        let withRules = testSettingsStore(suiteName: "circle-rules-reload", userDefaults: defaults)
        #expect(withRules.menuBarLayoutConditionals == [rule])
        let oldDefaults = InMemoryUserDefaults()
        try oldDefaults.set(JSONEncoder().encode(bars), forKey: "menuBarLayoutV7")
        try oldDefaults.set(JSONEncoder().encode(["claude": bars]), forKey: "menuBarLayoutOverridesV7")
        oldDefaults.set(blobs.v7, forKey: "menuBarLayoutConditionalsV7")
        let upgraded = testSettingsStore(suiteName: "circle-upgrade", userDefaults: oldDefaults)
        #expect(upgraded.menuBarLayout == bars)
        #expect(upgraded.menuBarLayoutOverrides[.claude] == bars)
        #expect(upgraded.menuBarLayoutConditionals == [rule.v7Compatible])
        for key in ["menuBarLayoutV8", "menuBarLayoutOverridesV8", "menuBarLayoutConditionalsV8"] {
            #expect(oldDefaults.data(forKey: key) != nil)
        }
    }

    private struct V7Layout: Decodable {
        let lines: [[Token]]
        enum Token: Decodable {
            case progressBar(window: PercentWindow)
        }
    }

    @Test
    func `frozen V7 decoder accepts projections and rejects new discriminators`() throws {
        let layout = MenuBarLayout(lines: [Self.windows.map { .iconUsageCircle(window: $0) }])
        let blobs = try MenuBarLayoutPersistence.encoded(layout)
        #expect(try JSONDecoder().decode(V7Layout.self, from: blobs.v7).lines.first?.count == 4)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(V7Layout.self, from: blobs.current)
        }
    }

    @Test
    func `ring fill increases and provider glyph fallback preserves warning flashes`() throws {
        func pixels(_ image: NSImage) throws -> NSBitmapImageRep {
            let data = try #require(image.tiffRepresentation)
            return try #require(NSBitmapImageRep(data: data))
        }
        func alpha(_ bitmap: NSBitmapImageRep) -> Double {
            (0..<bitmap.pixelsWide).reduce(0) { total, x in
                total + (0..<bitmap.pixelsHigh).reduce(0) { subtotal, y in
                    subtotal + Double(bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0)
                }
            }
        }
        let empty = try pixels(MenuBarLayoutRenderer.usageCircleImage(
            fillPercent: 0, size: 64, icon: nil, tint: .black, stale: false))
        let quarter = try pixels(MenuBarLayoutRenderer.usageCircleImage(
            fillPercent: 25, size: 64, icon: nil, tint: .black, stale: false))
        let full = try pixels(MenuBarLayoutRenderer.usageCircleImage(
            fillPercent: 100, size: 64, icon: nil, tint: .black, stale: false))
        #expect(alpha(empty) < alpha(quarter))
        #expect(alpha(quarter) < alpha(full))
        // A clockwise quarter arc occupies the top-right quadrant in bitmap coordinates.
        #expect((quarter.colorAt(x: 53, y: 10)?.alphaComponent ?? 0)
            > (quarter.colorAt(x: 10, y: 53)?.alphaComponent ?? 0))
        let fixtures = MenuBarLayoutRendererTests()
        let layout = MenuBarLayout(lines: [[.iconUsageCircle(window: .session)]])
        func attachment(_ provider: UsageProvider, incoming: NSImage?) throws -> NSImage {
            let title = MenuBarLayoutRenderer().render(
                layout: layout,
                data: fixtures.data(provider: provider),
                icon: incoming,
                options: fixtures.options()).attributedTitle
            var image: NSImage?
            title.enumerateAttribute(.attachment, in: NSRange(location: 0, length: title.length)) { value, _, _ in
                if let attachment = value as? NSTextAttachment { image = attachment.image }
            }
            return try #require(image)
        }
        let codex = try attachment(.codex, incoming: nil).tiffRepresentation
        let brand = try #require(ProviderBrandIcon.image(for: .codex))
        let flash = StatusItemController.quotaWarningFlashImage(base: brand)
        #expect(try attachment(.codex, incoming: brand).tiffRepresentation == codex)
        #expect(try attachment(.codex, incoming: flash).tiffRepresentation != codex)
        #expect(try attachment(.claude, incoming: nil).tiffRepresentation != codex)
    }

    @Test
    func `provider glyph paints in the center after drawing appearance changes`() throws {
        let icon = try #require(ProviderBrandIcon.image(for: .codex))
        var images: [NSImage] = []
        NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance {
            images = [icon, nil].map { glyph in
                MenuBarLayoutRenderer.usageCircleImage(
                    fillPercent: 25, size: 18, icon: glyph, tint: .controlTextColor, stale: false)
            }
        }
        var representations: [Data?] = []
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
            representations = images.map { image in
                let proof = NSImage(size: image.size, flipped: false) { rect in
                    NSColor.white.setFill()
                    rect.fill()
                    image.draw(in: rect)
                    return true
                }
                return proof.tiffRepresentation
            }
        }
        let bitmaps = try representations.map { representation in
            let data = try #require(representation)
            return try #require(NSBitmapImageRep(data: data))
        }
        try #require(bitmaps.count == 2)
        let centerX = (bitmaps[0].pixelsWide * 5 / 18)..<(bitmaps[0].pixelsWide * 13 / 18)
        let centerY = (bitmaps[0].pixelsHigh * 5 / 18)..<(bitmaps[0].pixelsHigh * 13 / 18)
        let paintedCenter = centerX.reduce(0) { total, x in
            total + centerY.filter { y in
                let glyph = bitmaps[0].colorAt(x: x, y: y)?.brightnessComponent ?? 1
                let empty = bitmaps[1].colorAt(x: x, y: y)?.brightnessComponent ?? 1
                return glyph < empty - 0.05
            }.count
        }
        #expect(paintedCenter > 3)
    }

    @Test(arguments: [20.0, 80.0])
    func `glyph artwork fills the ring regardless of padding or off center placement`(canvas: Double) throws {
        let icon = NSImage(size: NSSize(width: canvas, height: canvas), flipped: false) { _ in
            NSColor.black.setFill()
            let origin = canvas == 20 ? NSPoint(x: 4, y: 3) : NSPoint(x: 50, y: 30)
            NSBezierPath(ovalIn: NSRect(origin: origin, size: NSSize(width: 8, height: 8))).fill()
            return true
        }
        let images = [icon, nil].map {
            MenuBarLayoutRenderer.usageCircleImage(
                fillPercent: 50, size: 20, icon: $0, tint: .black, stale: false)
        }
        let bitmaps = try images.map { image in
            let data = try #require(image.tiffRepresentation)
            return try #require(NSBitmapImageRep(data: data))
        }
        var painted: [NSPoint] = []
        for y in 0..<bitmaps[0].pixelsHigh {
            for x in 0..<bitmaps[0].pixelsWide {
                let glyph = bitmaps[0].colorAt(x: x, y: y)?.alphaComponent ?? 0
                let empty = bitmaps[1].colorAt(x: x, y: y)?.alphaComponent ?? 0
                if glyph > empty + 0.5 { painted.append(NSPoint(x: x, y: y)) }
            }
        }
        let minX = try #require(painted.map(\.x).min())
        let maxX = try #require(painted.map(\.x).max())
        let minY = try #require(painted.map(\.y).min())
        let maxY = try #require(painted.map(\.y).max())
        let scale = CGFloat(bitmaps[0].pixelsWide) / 20
        #expect((maxX - minX + 1) / scale >= 14)
        #expect((maxY - minY + 1) / scale >= 14)
        // A 20pt ring has a 1.25pt stroke and the same clearance: artwork fits a 15pt disk.
        #expect((maxX - minX + 1) / scale <= 15.5)
        #expect((maxY - minY + 1) / scale <= 15.5)
        #expect(abs((minX + maxX + 1) / 2 / scale - 10) < 1)
        #expect(abs((minY + maxY + 1) / 2 / scale - 10) < 1)
    }

    @Test
    func `same circle draws at standard and Retina display resolutions`() throws {
        let icon = try #require(ProviderBrandIcon.image(for: .codex))
        let image = MenuBarLayoutRenderer.usageCircleImage(
            fillPercent: 25, size: 20, icon: icon, tint: .black, stale: false)
        for scale in [1, 2] {
            let context = try #require(CGContext(
                data: nil,
                width: 20 * scale,
                height: 20 * scale,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(NSColor.white.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 20 * scale, height: 20 * scale))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
            image.draw(in: NSRect(x: 0, y: 0, width: 20, height: 20))
            NSGraphicsContext.restoreGraphicsState()
            let cgImage = try #require(context.makeImage())
            let bitmap = NSBitmapImageRep(cgImage: cgImage)
            #expect(bitmap.pixelsWide == 20 * scale)
            #expect(bitmap.pixelsHigh == 20 * scale)
            let center = (5 * scale)..<(15 * scale)
            let painted = center.reduce(0) { count, y in
                count + center.filter { x in
                    (bitmap.colorAt(x: x, y: y)?.brightnessComponent ?? 1) < 0.5
                }.count
            }
            #expect(painted > 10 * scale * scale)
            if let directory = ProcessInfo.processInfo.environment["CODEXBAR_CIRCLE_PROOF_DIR"] {
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: URL(fileURLWithPath: directory)
                    .appendingPathComponent("native-\(scale)x.png"))
            }
        }
    }

    @Test(arguments: Self.windows, [true, false])
    func `circle windows and accessibility follow bars`(window: PercentWindow, showUsed: Bool) throws {
        let fixtures = MenuBarLayoutRendererTests()
        let data = fixtures.data()
        let renderer = MenuBarLayoutRenderer()
        let options = fixtures.options(showUsed: showUsed)
        let circle = renderer.render(
            layout: MenuBarLayout(lines: [[.iconUsageCircle(window: window)]]),
            data: data,
            icon: nil,
            options: options)
        let bar = renderer.render(
            layout: MenuBarLayout(lines: [[.progressBar(window: window)]]),
            data: data,
            icon: nil,
            options: options)
        #expect(circle.accessibilityLabel == bar.accessibilityLabel)
        #expect(circle.attributedTitle.string == bar.attributedTitle.string)
        #expect(circle.attributedTitle.containsAttachments)
        if let directory = ProcessInfo.processInfo.environment["CODEXBAR_CIRCLE_PROOF_DIR"] {
            let button = NSButton(frame: NSRect(x: 0, y: 0, width: 180, height: 22))
            button.isBordered = false
            button.imageScaling = .scaleNone
            button.appearance = NSAppearance(named: .aqua)
            let width = StatusItemController.applyMenuBarLayoutContent(circle, for: button, gap: .regular)
            button.setFrameSize(NSSize(width: width, height: 22))
            let cell = try #require(button.cell)
            let proof = NSImage(size: NSSize(width: max(120, width + 16), height: 44), flipped: false) { rect in
                NSColor.white.setFill()
                rect.fill()
                cell.draw(withFrame: NSRect(x: 8, y: 10, width: width, height: 22), in: button)
                return true
            }
            var representation: Data?
            button.effectiveAppearance.performAsCurrentDrawingAppearance {
                representation = proof.tiffRepresentation
            }
            let data = try #require(representation)
            let bitmap = try #require(NSBitmapImageRep(data: data))
            try #require(bitmap.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: directory)
                    .appendingPathComponent("title-\(window.rawValue)-\(showUsed ? "used" : "remaining").png"))
        }
        let unavailable = renderer.render(
            layout: MenuBarLayout(lines: [[.iconUsageCircle(window: .session)]]),
            data: fixtures.data(omitsSession: true),
            icon: nil,
            options: options)
        #expect(!unavailable.attributedTitle.containsAttachments)
        let balance = renderer.render(
            layout: MenuBarLayout(lines: [[.iconUsageCircle(window: .automatic)]]),
            data: fixtures.data(automaticText: "$12"),
            icon: nil,
            options: options)
        #expect(balance.attributedTitle.string == "$12")
    }

    @Test(arguments: MenuBarLayoutSize.allCases, [false, true])
    func `circle titles support stacked sizes and native color states`(size: MenuBarLayoutSize, stacked: Bool) throws {
        let fixtures = MenuBarLayoutRendererTests()
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for stale in [false, true] {
                let title = MenuBarLayoutRenderer().render(
                    layout: MenuBarLayout(lines: [[.iconUsageCircle(window: .weekly)]]),
                    data: fixtures.data(provider: .claude),
                    icon: nil,
                    options: fixtures.options(
                        size: size,
                        isStale: stale,
                        colorByProvider: true,
                        appearanceName: appearance.rawValue,
                        forceStackedStyle: stacked))
                var attachment: NSTextAttachment?
                title.attributedTitle.enumerateAttribute(
                    .attachment, in: NSRange(location: 0, length: title.attributedTitle.length))
                { value, _, _ in
                    attachment = value as? NSTextAttachment ?? attachment
                }
                let bounds = try #require(attachment).bounds
                #expect(bounds.width == (stacked ? (size == .large ? 10 : 9) : 20))
                #expect(bounds.width == bounds.height)
                #expect(bounds.origin.y.isFinite)
                if let directory = ProcessInfo.processInfo.environment["CODEXBAR_CIRCLE_PROOF_DIR"] {
                    let proof = NSImage(size: NSSize(width: 120, height: 44), flipped: false) { rect in
                        (appearance == .darkAqua ? NSColor.black : .white).setFill()
                        rect.fill()
                        title.attributedTitle.draw(at: NSPoint(x: 12, y: 16))
                        return true
                    }
                    var representation: Data?
                    NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
                        representation = proof.tiffRepresentation
                    }
                    let data = try #require(representation)
                    let bitmap = try #require(NSBitmapImageRep(data: data))
                    let name = "claude-\(size.rawValue)-\(stacked)-\(appearance.rawValue)-\(stale).png"
                    try #require(bitmap.representation(using: .png, properties: [:]))
                        .write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
                }
            }
        }
    }

    @Test(arguments: MenuBarLayoutSize.allCases, [false, true])
    func `circle rows paint inside a native menu bar button`(size: MenuBarLayoutSize, stacked: Bool) throws {
        let fixtures = MenuBarLayoutRendererTests()
        let output = MenuBarLayoutRenderer().render(
            layout: MenuBarLayout(lines: stacked
                ? [[.iconUsageCircle(window: .session)], [.iconUsageCircle(window: .weekly)]]
                : [[.iconUsageCircle(window: .session)]]),
            data: fixtures.data(),
            icon: nil,
            options: fixtures.options(size: size))
        let button = NSButton(frame: NSRect(x: 0, y: 0, width: 100, height: 22))
        button.isBordered = false
        button.appearance = NSAppearance(named: .aqua)
        let width = StatusItemController.applyMenuBarLayoutContent(output, for: button, gap: .regular)
        button.setFrameSize(NSSize(width: width, height: 22))
        let cell = try #require(button.cell)
        let image = NSImage(size: button.bounds.size, flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            cell.draw(withFrame: rect, in: button)
            return true
        }
        var representation: Data?
        button.effectiveAppearance.performAsCurrentDrawingAppearance { representation = image.tiffRepresentation }
        let data = try #require(representation)
        let bitmap = try #require(NSBitmapImageRep(data: data))
        let midpoint = bitmap.pixelsHigh / 2
        for rows in [0..<midpoint, midpoint..<bitmap.pixelsHigh] {
            let painted = rows.reduce(0) { count, y in
                count + (0..<bitmap.pixelsWide).filter { x in
                    (bitmap.colorAt(x: x, y: y)?.brightnessComponent ?? 1) < 0.9
                }.count
            }
            #expect(painted > 5)
        }
        if let directory = ProcessInfo.processInfo.environment["CODEXBAR_CIRCLE_PROOF_DIR"] {
            try #require(bitmap.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: directory)
                    .appendingPathComponent("\(stacked ? "stacked" : "single")-\(size.rawValue).png"))
        }
    }

    @Test(arguments: [1.0, 10, 18, 64], [0.0, 25, 100, -10, 120, .nan])
    func `ring geometry remains finite and exports deterministic proof`(size: Double, percent: Double) throws {
        let icon = try #require(ProviderBrandIcon.image(for: .codex))
        let image = MenuBarLayoutRenderer.usageCircleImage(
            fillPercent: percent, size: size, icon: icon, tint: .black, stale: false)
        #expect(image.size == NSSize(width: size, height: size))
        let bitmap = try NSBitmapImageRep(data: #require(image.tiffRepresentation))
        #expect(bitmap != nil)
        if let directory = ProcessInfo.processInfo.environment["CODEXBAR_CIRCLE_PROOF_DIR"], percent.isFinite {
            let proof = NSImage(size: image.size, flipped: false) { rect in
                NSColor.white.setFill()
                rect.fill()
                image.draw(in: rect)
                return true
            }
            let data = try #require(proof.tiffRepresentation)
            let opaque = try #require(NSBitmapImageRep(data: data))
            let png = try #require(opaque.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: directory)
                .appendingPathComponent("ring-\(Int(size))-\(Int(percent)).png"))
        }
    }

    @Test
    func `usage palette exports an isolated SwiftUI fixture`() throws {
        guard let directory = ProcessInfo.processInfo.environment["CODEXBAR_CIRCLE_PROOF_DIR"] else { return }
        let settings = testSettingsStore(suiteName: #function, userDefaults: InMemoryUserDefaults())
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing)
        defer { store.stopSharedSpendDashboardPublication() }
        let editor = MenuBarLayoutEditor(settings: settings, store: store)
        let content = editor.palette(MenuBarLayoutPaletteGroup(
            id: "usage",
            title: "Usage",
            tokens: MenuBarLayoutPaletteTokens.usage(provider: .codex, snapshot: nil),
            includesLineBreak: false))
            .frame(width: 600, alignment: .leading).padding(20).background(.white)
        let renderer = ImageRenderer(content: content.preferredColorScheme(.light))
        renderer.scale = 2
        let bitmap = try NSBitmapImageRep(cgImage: #require(renderer.cgImage))
        try #require(bitmap.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: directory).appendingPathComponent("usage-palette.png"))
    }
}
