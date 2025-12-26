import AppKit
import CodexBarCore

enum ProviderBrandIcon {
    private static let size = NSSize(width: 16, height: 16)

    static func image(for provider: UsageProvider) -> NSImage? {
        let baseName = self.resourceName(for: provider)
        let url1x = Bundle.main.url(forResource: baseName, withExtension: "png")
        let url2x = Bundle.main.url(forResource: baseName + "@2x", withExtension: "png")

        let image = NSImage(size: self.size)
        var added = false

        if let url1x,
           let data1x = try? Data(contentsOf: url1x),
           let rep1x = NSBitmapImageRep(data: data1x)
        {
            rep1x.size = self.size
            image.addRepresentation(rep1x)
            added = true
        }

        if let url2x,
           let data2x = try? Data(contentsOf: url2x),
           let rep2x = NSBitmapImageRep(data: data2x)
        {
            rep2x.size = self.size
            image.addRepresentation(rep2x)
            added = true
        }

        guard added else { return nil }
        image.isTemplate = true
        return image
    }

    private static func resourceName(for provider: UsageProvider) -> String {
        switch provider {
        case .codex: "ProviderIcon-codex"
        case .claude: "ProviderIcon-claude"
        case .zai: "ProviderIcon-zai"
        case .cursor: "ProviderIcon-cursor"
        case .factory: "ProviderIcon-factory"
        case .gemini: "ProviderIcon-gemini"
        case .antigravity: "ProviderIcon-antigravity"
        }
    }
}
