import AppKit

@MainActor
enum StatusMenuAppearance {
    static func pin(_ menu: NSMenu) {
        self.pin(menu, to: NSApplication.shared.effectiveAppearance)
    }

    static func pin(_ menu: NSMenu, to appearance: NSAppearance?) {
        // The exact effective appearance carries accessibility attributes that its name can omit.
        menu.appearance = appearance
        for item in menu.items {
            if let submenu = item.submenu {
                // Previously opened submenus must inherit the refreshed root instead of an old override.
                self.pin(submenu, to: nil)
            }
        }
    }
}

@MainActor
final class StatusMenuAppearanceObserver {
    private let refresh: @MainActor () -> Void
    private var observation: NSKeyValueObservation?
    private var refreshScheduled = false

    convenience init(controller: StatusItemController) {
        self.init(source: NSApplication.shared, appearance: \NSApplication.effectiveAppearance) { [weak controller] in
            controller?.pinKnownMenus(to: $0)
        }
    }

    init<Source: NSObject>(
        source: Source,
        appearance: KeyPath<Source, NSAppearance>,
        refresh: @escaping @MainActor (NSAppearance) -> Void)
    {
        self.refresh = { refresh(source[keyPath: appearance]) }
        self.observation = source.observe(
            appearance,
            options: [.new])
        { [weak self] _, _ in
            DispatchQueue.main.async { [weak self] in
                self?.handleAppearanceChange()
            }
        }
    }

    func stop() {
        self.observation?.invalidate()
        self.observation = nil
        self.refreshScheduled = false
    }

    private func handleAppearanceChange() {
        guard self.observation != nil else { return }
        self.refresh()
        guard self.observation != nil, !self.refreshScheduled else { return }
        self.refreshScheduled = true

        // AppKit may update menu tracking after the appearance change, so re-pin next turn.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.observation != nil else { return }
            self.refreshScheduled = false
            self.refresh()
        }
    }
}

extension StatusItemController {
    fileprivate func pinKnownMenus(to appearance: NSAppearance) {
        let menus = [self.mergedMenu, self.fallbackMenu] + self.providerMenus.values.map(Optional.some)
        for menu in menus.compactMap(\.self) {
            StatusMenuAppearance.pin(menu, to: appearance)
        }
    }
}
