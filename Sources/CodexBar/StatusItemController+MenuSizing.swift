import AppKit
import CodexBarCore

extension StatusItemController {
    func menuCardWidth(
        for providers: [UsageProvider],
        sections: [MenuDescriptor.Section]) -> CGFloat
    {
        _ = providers
        let baselineWidth = Self.menuCardBaseWidth
        return max(baselineWidth, self.measuredStandardMenuWidth(for: sections, baseWidth: baselineWidth))
    }

    func resolvedMenuWidth(
        enabledProviders: [UsageProvider],
        sections: [MenuDescriptor.Section],
        menu: NSMenu,
        mode: MenuPopulateMode)
        -> CGFloat
    {
        if mode == .preserveExistingSwitcherWidth,
           let switcherView = menu.items.first?.view as? ProviderSwitcherView,
           switcherView.frame.width > 0
        {
            return switcherView.frame.width
        }
        return self.menuCardWidth(for: enabledProviders, sections: sections)
    }

    private func measuredStandardMenuWidth(for sections: [MenuDescriptor.Section], baseWidth: CGFloat) -> CGFloat {
        let menuFont = NSFont.menuFont(ofSize: NSFont.systemFontSize)
        let secondaryFont = NSFont.menuFont(ofSize: NSFont.smallSystemFontSize)
        let persistentActionPadding: CGFloat = 88
        let standardActionPadding: CGFloat = 56
        let textPadding: CGFloat = 36
        var measuredWidth = baseWidth

        for section in sections {
            for entry in section.entries {
                switch entry {
                case let .action(title, action):
                    let titleWidth = self.textWidth(L(title), font: menuFont)
                    let padding = self.usesPersistentMenuActionItem(for: action)
                        ? persistentActionPadding
                        : standardActionPadding
                    measuredWidth = max(measuredWidth, titleWidth + padding)
                case let .submenu(title, _, _):
                    measuredWidth = max(measuredWidth, self.textWidth(title, font: menuFont) + standardActionPadding)
                case let .text(text, style):
                    let font = style == .secondary ? secondaryFont : menuFont
                    measuredWidth = max(measuredWidth, min(self.textWidth(text, font: font) + textPadding, baseWidth))
                case .divider:
                    continue
                }
            }
        }

        return ceil(measuredWidth)
    }

    private func textWidth(_ text: String, font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }
}
