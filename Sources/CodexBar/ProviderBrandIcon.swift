import AppKit
import CodexBarCore

@MainActor
enum ProviderBrandIcon {
    private static let size = NSSize(width: 16, height: 16)
    private static var cache: [UsageProvider: NSImage] = [:]

    /// Lazy-loaded resource bundle for provider icons.
    private static let resourceBundle: Bundle? = {
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

    static func image(for provider: UsageProvider) -> NSImage? {
        if let cached = self.cache[provider] {
            return cached
        }

        let baseName = ProviderDescriptorRegistry.descriptor(for: provider).branding.iconResourceName
        guard let bundle = self.resourceBundle else {
            return nil
        }
        guard let url = bundle.url(forResource: baseName, withExtension: "svg"),
              let vectorImage = NSImage(contentsOf: url)
        else {
            return nil
        }

        // ponytail: NSTouchBar's rendering pipeline doesn't reliably draw a lazy
        // vector-backed NSImage under SwiftUI's .renderingMode(.template) clip mask
        // (blank/invisible instead of an error, so it silently falls back to the
        // letter avatar). Rasterizing eagerly to a @2x bitmap at load time sidesteps that.
        let scale: CGFloat = 2
        let pixelSize = NSSize(width: self.size.width * scale, height: self.size.height * scale)
        guard
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(pixelSize.width),
                pixelsHigh: Int(pixelSize.height),
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0)
        else {
            return nil
        }
        rep.size = self.size

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        vectorImage.draw(in: NSRect(origin: .zero, size: self.size))
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: self.size)
        image.addRepresentation(rep)
        image.isTemplate = true
        self.cache[provider] = image
        return image
    }

    static func resetCacheForTesting() {
        self.cache.removeAll()
    }
}
