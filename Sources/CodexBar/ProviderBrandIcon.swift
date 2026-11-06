import AppKit
import CodexBarCore

@MainActor
enum ProviderBrandIcon {
    enum Style: Hashable {
        case monochrome
        case brand
    }

    private static let size = NSSize(width: 18, height: 18)
    private static var cache: [Style: [UsageProvider: NSImage]] = [:]
    private static var pluginCache: [String: NSImage] = [:]

    /// Lazy-loaded resource bundle for provider icons.
    private static let resourceBundle: Bundle = {
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            return Bundle.module
        }
        // SwiftPM creates a CodexBar_CodexBar.bundle for resources in the CodexBar target.
        if let bundleURL = Bundle.main.url(forResource: "CodexBar_CodexBar", withExtension: "bundle"),
           let bundle = Bundle(url: bundleURL)
        {
            return bundle
        }
        // Fallback to main bundle for development/testing.
        return Bundle.main
    }()

    static func image(for provider: UsageProvider, style: Style = .monochrome) -> NSImage? {
        if let cached = self.cache[style]?[provider] {
            return cached
        }

        let baseName = ProviderDescriptorRegistry.descriptor(for: provider).branding.iconResourceName
        let bundle = self.resourceBundle
        // Only explicitly curated brand assets have reliable original colors. Existing provider
        // SVGs are often white silhouettes, so they must remain templates in both appearances.
        // Providers can share a monochrome resource while representing different products.
        let brandResourceName = "Brand-ProviderIcon-" + provider.rawValue
        let brandImage: NSImage? = style == .brand ? ["svg", "png"].lazy.compactMap { fileExtension in
            bundle.url(forResource: brandResourceName, withExtension: fileExtension)
                .flatMap { NSImage(contentsOf: $0) }
        }.first : nil
        guard let image = brandImage ?? bundle.url(forResource: baseName, withExtension: "svg")
            .flatMap({ NSImage(contentsOf: $0) }) else { return nil }

        image.size = self.size
        image.isTemplate = brandImage == nil
        self.cache[style, default: [:]][provider] = image
        return image
    }

    /// The plugin's validated SVG as a template image, or nil when it has none or it does not decode.
    static func image(for plugin: UserProviderPlugin) -> NSImage? {
        guard let svg = plugin.manifest.icon.svg else { return nil }
        if let cached = self.pluginCache[svg] { return cached }
        guard let source = NSImage(data: Data(svg.utf8)),
              source.size.width.isFinite, source.size.height.isFinite,
              source.size.width > 0, source.size.height > 0,
              source.size.width <= CGFloat(ProviderPluginIconSVG.maximumCanvasDimension),
              source.size.height <= CGFloat(ProviderPluginIconSVG.maximumCanvasDimension),
              let bitmap = NSBitmapImageRep(
                  bitmapDataPlanes: nil,
                  pixelsWide: 32,
                  pixelsHigh: 32,
                  bitsPerSample: 8,
                  samplesPerPixel: 4,
                  hasAlpha: true,
                  isPlanar: false,
                  colorSpaceName: .deviceRGB,
                  bytesPerRow: 0,
                  bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap)
        else { return nil }
        let scale = 32 / max(source.size.width, source.size.height)
        guard scale.isFinite else { return nil }
        source.size = NSSize(width: source.size.width * scale, height: source.size.height * scale)
        let rect = NSRect(
            x: (32 - source.size.width) / 2,
            y: (32 - source.size.height) / 2,
            width: source.size.width,
            height: source.size.height)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        context.cgContext.clear(NSRect(x: 0, y: 0, width: 32, height: 32))
        source.draw(in: rect)
        bitmap.size = NSSize(width: 16, height: 16)
        let image = NSImage(size: bitmap.size)
        image.addRepresentation(bitmap)
        image.isTemplate = true
        // Every plugin raster is a fixed 16pt/32px template; key the evaluated SVG, which may vary by engine.
        if self.pluginCache.count >= 64 { self.pluginCache.removeAll(keepingCapacity: true) }
        self.pluginCache[svg] = image
        return image
    }

    static func resetCacheForTesting() {
        self.cache.removeAll()
        self.pluginCache.removeAll()
    }
}
