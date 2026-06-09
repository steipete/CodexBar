import AppKit

extension StatusItemController {
    private static let measuredStandardMenuWidthCacheLimit = 96

    func measuredStandardMenuWidth(for sections: [MenuDescriptor.Section], baseWidth: CGFloat) -> CGFloat {
        let cacheKey = self.measuredStandardMenuWidthCacheKey(for: sections, baseWidth: baseWidth)
        if let cached = self.measuredStandardMenuWidthCache[cacheKey] {
            return cached
        }

        let measuringMenu = NSMenu()
        measuringMenu.autoenablesItems = false
        self.addActionableSections(sections, to: measuringMenu, width: baseWidth)
        let measured = ceil(measuringMenu.size.width)
        if self.measuredStandardMenuWidthCache.count >= Self.measuredStandardMenuWidthCacheLimit {
            self.measuredStandardMenuWidthCache.removeAll(keepingCapacity: true)
        }
        self.measuredStandardMenuWidthCache[cacheKey] = measured
        return measured
    }

    private func measuredStandardMenuWidthCacheKey(
        for sections: [MenuDescriptor.Section],
        baseWidth: CGFloat) -> String
    {
        var parts = [
            "base=\(Int((baseWidth * 100).rounded()))",
            "font=\(Self.menuCardHeightTextScaleToken())",
            self.menuLocalizationSignature(),
        ]
        for section in sections {
            parts.append("[")
            for entry in section.entries {
                parts.append(self.measuredStandardMenuWidthCacheToken(for: entry))
            }
            parts.append("]")
        }
        return parts.joined(separator: "\u{1f}")
    }

    private func measuredStandardMenuWidthCacheToken(for entry: MenuDescriptor.Entry) -> String {
        switch entry {
        case let .text(text, style):
            "text:\(style):\(text)"
        case let .action(title, action):
            "action:\(title):\(self.measuredStandardMenuWidthCacheToken(for: action))"
        case let .submenu(title, systemImageName, submenuItems):
            "submenu:\(title):\(systemImageName ?? ""):" + submenuItems.map { item in
                [
                    item.title,
                    item.isEnabled ? "1" : "0",
                    item.isChecked ? "1" : "0",
                    item.action.map(self.measuredStandardMenuWidthCacheToken(for:)) ?? "",
                ].joined(separator: ":")
            }.joined(separator: ",")
        case .divider:
            "divider"
        }
    }

    private func measuredStandardMenuWidthCacheToken(for action: MenuDescriptor.MenuAction) -> String {
        switch action {
        case .installUpdate:
            "installUpdate"
        case .refresh:
            "refresh"
        case .refreshAugmentSession:
            "refreshAugmentSession"
        case .dashboard:
            "dashboard"
        case .statusPage:
            "statusPage"
        case .changelog:
            "changelog"
        case .addCodexAccount:
            "addCodexAccount:\(self.codexAddAccountSubtitle() ?? "")"
        case let .requestCodexSystemPromotion(id):
            "requestCodexSystemPromotion:\(id)"
        case let .addProviderAccount(provider):
            "addProviderAccount:\(provider.rawValue)"
        case let .switchAccount(provider):
            "switchAccount:\(provider.rawValue):\(self.switchAccountSubtitle(for: provider) ?? "")"
        case let .openTerminal(command):
            "openTerminal:\(command)"
        case let .loginToProvider(url):
            "loginToProvider:\(url)"
        case .settings:
            "settings"
        case .about:
            "about"
        case .quit:
            "quit"
        case let .copyError(message):
            "copyError:\(message)"
        }
    }
}
