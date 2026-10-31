import AppKit
import CodexBarCore

@MainActor
final class PluginMenuBarSummaryRenderer {
    struct Element: Hashable {
        let iconProvider: UsageProvider?
        let value: String
        let accessibility: String
    }

    struct Options: Equatable {
        let sourceHash: String
        let monospaced: Bool
        let highContrast: Bool
        let appearance: String
    }

    private struct Key: Equatable {
        let elements: [Element]
        let options: Options
    }

    private var cached: (Key, MenuBarLayoutRenderedTitle)?
    private(set) var lastAccessibilityLabel: String?

    func removeAll() {
        self.cached = nil
    }

    static func elements(snapshot: UsageSnapshot, showUsed: Bool) -> [Element] {
        snapshot.menuBarItems.map { item in
            let used = item.window(in: snapshot).map { min(100, max(0, $0.usedPercent)) }
            let value = used.map { UsageFormatter.percentString(showUsed ? $0 : 100 - $0) } ?? "—"
            let usage = used.map { UsageFormatter.usageLine(remaining: 100 - $0, used: $0, showUsed: showUsed) } ?? "—"
            return Element(
                iconProvider: item.iconProvider,
                value: value,
                accessibility: "\(item.title): \(usage)")
        }
    }

    func render(elements: [Element], options: Options, fallbackIcon: () -> NSImage) -> MenuBarLayoutRenderedTitle {
        let key = Key(elements: elements, options: options)
        if let cached, cached.0 == key { return cached.1 }
        let font = options.monospaced
            ? NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            : NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
        let title = NSMutableAttributedString(string: "")
        for element in elements {
            if title.length > 0 { title.append(NSAttributedString(string: "   ", attributes: attributes)) }
            let attachment = NSTextAttachment()
            attachment.image = element.iconProvider.flatMap { ProviderBrandIcon.image(for: $0) } ?? fallbackIcon()
            attachment.bounds = NSRect(x: 0, y: ((font.capHeight - 16) / 2).rounded(), width: 16, height: 16)
            let icon = NSMutableAttributedString(attachment: attachment)
            icon.addAttributes(attributes, range: NSRange(location: 0, length: icon.length))
            title.append(icon)
            title.append(NSAttributedString(string: "\u{2009}" + element.value, attributes: attributes))
        }
        let rendered = MenuBarLayoutRenderer.pluginSummaryTitle(
            title,
            accessibilityLabel: elements.map(\.accessibility).joined(separator: "; "),
            highContrast: options.highContrast)
        self.lastAccessibilityLabel = rendered.accessibilityLabel
        self.cached = (key, rendered)
        return rendered
    }
}
