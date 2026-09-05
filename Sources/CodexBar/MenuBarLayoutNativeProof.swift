#if DEBUG
import AppKit
import CodexBarCore

/// Opt-in synthetic status-item proof, entered before settings or provider startup.
@MainActor
enum MenuBarLayoutNativeProof {
    static func runIfRequested() -> Bool {
        guard CommandLine.arguments.contains("--menu-layout-proof") else { return false }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = Delegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
        return true
    }

    @MainActor
    private final class Delegate: NSObject, NSApplicationDelegate {
        private let renderer = MenuBarLayoutRenderer()
        private var item: NSStatusItem?
        private var mode = "Baseline"
        private var adjustment = 0

        func applicationDidFinishLaunching(_ notification: Notification) {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            self.item = item
            item.button?.setAccessibilityIdentifier("codexbar-synthetic-layout-proof")
            let menu = NSMenu(title: "Synthetic layout proof")
            let label = NSMenuItem(title: "Synthetic data only", action: nil, keyEquivalent: "")
            menu.addItem(label)
            menu.addItem(.separator())
            for title in ["Baseline", "Cached", "Stale", "High contrast", "Move up", "Move down", "Reset position"] {
                let entry = NSMenuItem(title: title, action: #selector(self.selectMode(_:)), keyEquivalent: "")
                entry.target = self
                menu.addItem(entry)
            }
            menu.addItem(.separator())
            let quit = NSMenuItem(title: "Quit proof", action: #selector(self.quit), keyEquivalent: "")
            quit.target = self
            menu.addItem(quit)
            item.menu = menu
            self.refresh()
        }

        @objc private func selectMode(_ sender: NSMenuItem) {
            switch sender.title {
            case "Move up": self.adjustment = 2
            case "Move down": self.adjustment = -2
            case "Reset position": self.adjustment = 0
            default: self.mode = sender.title
            }
            self.refresh()
        }

        @objc private func quit() {
            if let item {
                NSStatusBar.system.removeStatusItem(item)
            }
            NSApplication.shared.terminate(nil)
        }

        private func refresh() {
            guard let item, let button = item.button else { return }
            let data = MenuBarLayoutRenderData(
                provider: .codex,
                iconKey: "synthetic-layout-proof",
                providerName: "Codex",
                accountLabel: nil,
                laneLabels: MenuBarLayoutLaneLabels(provider: .codex, snapshot: nil),
                primary: nil,
                secondary: nil,
                tertiary: nil,
                session: nil,
                weekly: nil,
                scopedWeekly: nil,
                scopedWeeklyTitle: nil,
                automatic: nil,
                automaticText: "82%",
                sessionPace: nil,
                weeklyPace: "+11%",
                automaticPace: nil,
                runsOut: "Runs out in 2d 2h",
                balance: nil,
                costToday: nil,
                cost30d: nil,
                metrics: .unavailable)
            let rendered = self.renderer.render(
                layout: MenuBarLayout(lines: [[.percent(window: .automatic), .pace(window: .weekly), .runsOutCompact]]),
                data: data,
                icon: nil,
                options: MenuBarLayoutRenderOptions(
                    size: .regular,
                    highContrast: self.mode == "High contrast",
                    showUsed: true,
                    conditionals: [],
                    appearanceName: button.effectiveAppearance.name.rawValue,
                    isDebugApp: false,
                    isStale: self.mode == "Stale",
                    now: Date(timeIntervalSince1970: 1_788_000_000),
                    verticalAdjustment: self.adjustment))
            let output = self.mode == "Baseline"
                ? MenuBarLayoutRenderedTitle(
                    attributedTitle: rendered.attributedTitle,
                    accessibilityLabel: rendered.accessibilityLabel,
                    leadingIcon: rendered.leadingIcon)
                : rendered
            item.length = StatusItemController.applyMenuBarLayoutContent(output, for: button, gap: .regular)
            let receipt = "layout-proof mode=\(self.mode) width=\(item.length) "
                + "titleLength=\(button.attributedTitle.length) "
                + "template=\(button.image?.isTemplate ?? false) adjustment=\(self.adjustment)\n"
            FileHandle.standardOutput.write(Data(receipt.utf8))
        }
    }
}
#endif
