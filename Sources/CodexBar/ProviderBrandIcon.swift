import AppKit
import CodexBarCore

enum ProviderBrandIcon {
    private static let size = NSSize(width: 16, height: 16)

    static func image(for provider: UsageProvider) -> NSImage? {
        let baseName = ProviderDescriptorRegistry.descriptor(for: provider).branding.iconResourceName
        guard let url = Bundle.main.url(forResource: baseName, withExtension: "svg"),
              let image = NSImage(contentsOf: url)
        else {
            return nil
        }

        image.size = self.size
        image.isTemplate = true
        return image
    }
}
