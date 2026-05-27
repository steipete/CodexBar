import AppKit
import CodexBarCore

enum ProviderBrandIcon {
    private static let size = NSSize(width: 16, height: 16)

    /// Lazy-loaded resource bundle for provider icons.
    private static let resourceBundle: Bundle? = {
        // SwiftPM creates a CodexBar_CodexBar.bundle for resources in the CodexBar target.
        if let bundleURL = Bundle.main.url(forResource: "CodexBar_CodexBar", withExtension: "bundle"),
           let bundle = Bundle(url: bundleURL)
        {
            return bundle
        }
        // Fallback to main bundle for development/testing.
        return Bundle.main
    }()

    @MainActor
    static func appIconImage() -> NSImage? {
        if let image = NSApplication.shared.applicationIconImage {
            return image
        }
        if let image = self.resourceImage(named: "Icon-classic", fileExtension: "icns") {
            return image
        }
        return NSImage(named: NSImage.applicationIconName)
    }

    static func image(for provider: UsageProvider) -> NSImage? {
        let baseName = ProviderDescriptorRegistry.descriptor(for: provider).branding.iconResourceName
        return self.resourceImage(
            named: baseName,
            fileExtension: "svg",
            size: self.size,
            isTemplate: true)
    }

    private static func resourceImage(
        named name: String,
        fileExtension: String,
        subdirectory: String? = nil,
        size: NSSize? = nil,
        isTemplate: Bool = false)
        -> NSImage?
    {
        guard let bundle = self.resourceBundle,
              let url = bundle.url(
                  forResource: name,
                  withExtension: fileExtension,
                  subdirectory: subdirectory),
              let image = NSImage(contentsOf: url)
        else { return nil }

        if let size {
            image.size = size
        }
        image.isTemplate = isTemplate
        return image
    }
}
