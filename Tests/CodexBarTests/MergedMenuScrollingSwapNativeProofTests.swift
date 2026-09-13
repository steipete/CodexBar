import AppKit
import XCTest
@testable import CodexBar
@testable import CodexBarCore

/// Native proof for #3549: merged-menu tab swaps between cards of different heights.
///
/// Opens the production merged menu with six synthetic providers whose cards deliberately differ in height (Overview
/// also exceeds the screen and scrolls), then switches tabs from a common-modes timer while the menu tracks. AppKit's
/// table-backed menu keeps a reused row's measured height, so an in-place payload swap into a row of another height
/// left empty space or clipped cards. Each phase records menu, table and row geometry with item identity, asserts
/// that no row keeps a stale height, and captures the menu window. Opt-in via `CODEXBAR_MENU_SWAP_PROOF_DIR`;
/// `CODEXBAR_MENU_SWAP_COST=1` adds cost sections and `CODEXBAR_MENU_SWAP_POPUP=1` opens from a window popUp instead of
/// the status item.
/// Synthetic accounts only; no provider transport, credential or Keychain access.
@MainActor
final class MergedMenuScrollingSwapNativeProofTests: XCTestCase {
    func test_tabSwapsWhileScrolling() throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["CODEXBAR_MENU_SWAP_PROOF_DIR"] else {
            throw XCTSkip("Set CODEXBAR_MENU_SWAP_PROOF_DIR for the merged-menu swap diagnostic")
        }
        guard env["CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS"] == "1",
              env[CodexCredentialFileAccess.isolationEnvironmentKey] == "1",
              env["CODEXBAR_TEST_SESSION_FILE_ISOLATION"] == "1"
        else { return XCTFail("Use credential isolation") }
        let output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let fixture = try Self.makeFixture()
        defer { fixture.cleanup() }
        let app = NSApplication.shared
        guard app.delegate == nil else { return XCTFail("Use a standalone test host") }
        let oldPolicy = app.activationPolicy()
        let previous = NSWorkspace.shared.frontmostApplication
        _ = app.setActivationPolicy(.regular)
        app.finishLaunching()
        let previousRendering = StatusItemController.menuCardRenderingEnabled
        let previousRefresh = StatusItemController.menuRefreshEnabled
        StatusItemController.menuCardRenderingEnabled = true
        StatusItemController.setMenuRefreshEnabledForTesting(true)
        defer {
            StatusItemController.menuCardRenderingEnabled = previousRendering
            StatusItemController.setMenuRefreshEnabledForTesting(previousRefresh)
        }
        let controller = fixture.makeController()
        defer {
            controller.releaseStatusItemsForTesting()
            _ = app.setActivationPolicy(oldPolicy)
            previous?.activate()
        }
        let menu = try XCTUnwrap(controller.mergedMenu)

        // Anchor the popup near the top of the screen, like a status item menu.
        let screen = try XCTUnwrap(NSScreen.main)
        let host = NSWindow(
            contentRect: NSRect(
                x: screen.visibleFrame.minX + 80,
                y: screen.visibleFrame.maxY - 60,
                width: 360,
                height: 40),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        host.isReleasedWhenClosed = false
        host.orderFront(nil)
        app.activate(ignoringOtherApps: true)
        defer { host.close() }

        let driver = MergedMenuSwapDriver(menu: menu, output: output, settings: fixture.settings)
        let timer = Timer(timeInterval: 0.5, repeats: true) { _ in
            MainActor.assumeIsolated { driver.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        defer { timer.invalidate() }
        if env["CODEXBAR_MENU_SWAP_POPUP"] == "1" {
            // Window-anchored popUp tracking can end early when a tab swap resizes the menu (seen with and without
            // the #3549 fix), so it is an optional variant; the status item path below is what users open.
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: 0), in: host.contentView)
        } else {
            let button = try XCTUnwrap(controller.statusItem.button)
            button.performClick(nil)
        }

        XCTAssertEqual(driver.phases.count, MergedMenuSwapDriver.script.count, "Timer must fire during tracking")
        for phase in driver.phases {
            let label = phase["phase"] as? String ?? "?"
            let selection = try XCTUnwrap(label.split(separator: "-").dropFirst().first)
            XCTAssertEqual(phase["overviewSelected"] as? Bool, selection == "overview", label)
            if selection != "overview" {
                XCTAssertEqual(phase["selectedProvider"] as? String, String(selection), label)
            }
            // #3549: every table row must match its item's view, and the table must match the menu.
            let table = try XCTUnwrap(phase["tableHeight"] as? Double, label)
            let size = try XCTUnwrap(phase["menuSize"] as? String, label)
            XCTAssertGreaterThan(table, 0, label)
            XCTAssertEqual(table, Double(NSSizeFromString(size).height), accuracy: 1.5, "\(label): stale table height")
            let items = try XCTUnwrap(phase["menuItems"] as? [[String: Any]], label)
            let cards = items.filter {
                guard let row = $0["row"] as? String, row != "none" else { return false }
                return $0["isCard"] as? Bool == true
            }
            XCTAssertFalse(cards.isEmpty, "\(label): missing attached card rows")
            for card in cards {
                let row = try XCTUnwrap(card["row"] as? String, label)
                let intrinsic = try XCTUnwrap(card["intrinsic"] as? String, label)
                XCTAssertGreaterThan(NSRectFromString(row).height, 0, label)
                XCTAssertEqual(
                    NSRectFromString(row).height,
                    NSSizeFromString(intrinsic).height,
                    accuracy: 1.5,
                    "\(label): card row differs from its measured content")
            }
            for item in items {
                guard let row = item["row"] as? String, row != "none", let view = item["viewFrame"] as? String
                else { continue }
                XCTAssertEqual(
                    NSRectFromString(row).height,
                    NSRectFromString(view).height,
                    accuracy: 1.5,
                    "\(label): row \(item["id"] ?? "?") keeps a stale height")
            }
        }
        try JSONSerialization.data(
            withJSONObject: [
                "syntheticOnly": true,
                "screenVisibleFrame": NSStringFromRect(screen.visibleFrame),
                "phases": driver.phases,
            ],
            options: [.sortedKeys, .prettyPrinted])
            .write(to: output.appendingPathComponent("geometry.json"), options: .atomic)
    }

    // MARK: - Fixture

    private static func makeFixture() throws -> CodexWorkspacesNavigationFixture {
        let fixture = try CodexWorkspacesNavigationFixture(userDefaults: InMemoryUserDefaults())
        fixture.settings.mergeIcons = true
        fixture.settings.multiAccountMenuLayout = .segmented
        fixture.settings.selectedMenuProvider = .codex
        let now = Date()
        func window(_ used: Double, _ minutes: Int) -> RateWindow {
            RateWindow(
                usedPercent: used,
                windowMinutes: minutes,
                resetsAt: now.addingTimeInterval(TimeInterval(minutes * 30)),
                resetDescription: nil)
        }
        /// Deliberately uneven card heights: tab swaps must grow and shrink by different amounts.
        func snapshot(windows: Int) -> UsageSnapshot {
            UsageSnapshot(
                primary: window(25, 300),
                secondary: windows >= 2 ? window(40, 7 * 24 * 60) : nil,
                tertiary: windows >= 3 ? window(10, 7 * 24 * 60) : nil,
                updatedAt: now)
        }
        // Every provider the swap script selects must be enabled here.
        let windowsByProvider: [(UsageProvider, Int)] = [
            (.codex, 3), (.claude, 1), (.cursor, 3), (.gemini, 2), (.copilot, 1), (.zai, 3),
        ]
        for (provider, windows) in windowsByProvider {
            fixture.settings.setProviderEnabled(
                provider: provider,
                metadata: ProviderDescriptorRegistry.descriptor(for: provider).metadata,
                enabled: true)
            fixture.store._setSnapshotForTesting(snapshot(windows: windows), provider: provider)
        }
        if ProcessInfo.processInfo.environment["CODEXBAR_MENU_SWAP_COST"] == "1" {
            // Cost sections and the Overview spend summary add rows whose heights differ per provider.
            fixture.settings.costUsageEnabled = true
            for (provider, days) in [(UsageProvider.codex, 30), (.claude, 3), (.cursor, 12)] {
                let daily = (0..<days).map { offset in
                    CostUsageDailyReport.Entry(
                        date: Self.dayString(now.addingTimeInterval(TimeInterval(-offset * 86400))),
                        inputTokens: 1000 * (offset + 1),
                        outputTokens: 500,
                        totalTokens: 1500 + 1000 * offset,
                        costUSD: Double(offset + 1) * 1.25,
                        modelsUsed: ["synthetic-model"],
                        modelBreakdowns: nil)
                }
                fixture.store._setTokenSnapshotForTesting(
                    CostUsageTokenSnapshot(
                        sessionTokens: 12000,
                        sessionCostUSD: 3.5,
                        last30DaysTokens: 900_000,
                        last30DaysCostUSD: Double(days) * 4.2,
                        historyDays: days,
                        daily: daily,
                        updatedAt: now),
                    provider: provider)
            }
        }
        fixture.store.claudeSwapAccountSnapshots = (1...3).map { slot in
            ProviderAccountUsageSnapshot(
                id: ProviderAccountIdentity(source: "claude-swap", opaqueID: String(slot)),
                provider: .claude,
                displayLabel: "synthetic\(slot)@example.com",
                isActive: slot == 1,
                canActivate: slot != 1,
                snapshot: snapshot(windows: slot),
                error: nil,
                sourceLabel: "claude-swap")
        }
        return fixture
    }

    private static func dayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    // MARK: - Geometry

    static func phaseReceipt(menu: NSMenu, label: String, settings: SettingsStore) -> [String: Any] {
        let anyView = menu.items.lazy.compactMap(\.view).first { $0.window != nil }
        let window = anyView?.window
        var receipt: [String: Any] = [
            "phase": label,
            "selectedProvider": settings.selectedMenuProvider?.rawValue ?? "none",
            "overviewSelected": settings.mergedMenuLastSelectedWasOverview,
            "items": menu.numberOfItems,
            "menuSize": NSStringFromSize(menu.size),
            "window": window.map { NSStringFromRect($0.frame) } ?? "none",
        ]
        guard let anyView else { return receipt }
        var chain: [String] = []
        var representation: NSView?
        var clip: NSView?
        var node: NSView? = anyView.superview
        while let current = node {
            let name = String(describing: type(of: current))
            chain.append("\(name) \(NSStringFromRect(current.frame)) bounds=\(NSStringFromRect(current.bounds))")
            if representation == nil, name.contains("MenuRepresentation") { representation = current }
            if clip == nil, current is NSClipView { clip = current }
            node = current.superview
        }
        receipt["ancestorChain"] = chain
        receipt["menuItems"] = menu.items.enumerated().compactMap { index, item -> [String: Any]? in
            guard let view = item.view else { return nil }
            var rowFrame = "none"
            var node: NSView? = view.superview
            while let current = node {
                if current is NSTableRowView {
                    rowFrame = NSStringFromRect(current.frame)
                    break
                }
                node = current.superview
            }
            return [
                "index": index,
                "itemObject": String(UInt(bitPattern: ObjectIdentifier(item).hashValue), radix: 16),
                "viewObject": String(UInt(bitPattern: ObjectIdentifier(view).hashValue), radix: 16),
                "id": (item.representedObject as? String) ?? item.title,
                "view": String(describing: type(of: view)),
                "isCard": view is ErasedMenuCardHostingView,
                "viewFrame": NSStringFromRect(view.frame),
                "intrinsic": NSStringFromSize(view.intrinsicContentSize),
                "fitting": NSStringFromSize(view.fittingSize),
                "row": rowFrame,
            ]
        }
        receipt["tableHeight"] = representation.map { Double($0.frame.height) } ?? -1
        receipt["clipHeight"] = clip.map { Double($0.frame.height) } ?? -1
        receipt["clipOffsetY"] = clip.map { Double($0.bounds.minY) } ?? -1
        if let representation {
            let rows = representation.subviews.sorted { $0.frame.minY < $1.frame.minY }
            receipt["rowCount"] = rows.count
            receipt["rowHeightSum"] = Double(rows.reduce(0) { $0 + $1.frame.height })
            receipt["rows"] = rows.map { row -> [String: Any] in
                let content = Self.deepestCustomView(in: row)
                var entry: [String: Any] = [
                    "class": String(describing: type(of: row)),
                    "frame": NSStringFromRect(row.frame),
                ]
                if let content {
                    entry["content"] = String(describing: type(of: content))
                    entry["contentFrame"] = NSStringFromRect(content.frame)
                    entry["contentFitting"] = NSStringFromSize(content.fittingSize)
                    entry["contentIntrinsic"] = NSStringFromSize(content.intrinsicContentSize)
                    entry["rowMinusContentHeight"] = Double(row.frame.height - content.frame.height)
                }
                return entry
            }
        }
        return receipt
    }

    /// The menu item's own view inside a custom row (skipping AppKit's wrapper views).
    private static func deepestCustomView(in row: NSView) -> NSView? {
        var queue = row.subviews
        while !queue.isEmpty {
            let view = queue.removeFirst()
            let name = String(describing: type(of: view))
            if !name.hasPrefix("NS") || name.contains("Hosting") { return view }
            queue.append(contentsOf: view.subviews)
        }
        return nil
    }

    static func capture(menu: NSMenu, to url: URL) {
        guard let window = menu.items.lazy.compactMap({ $0.view?.window }).first else { return }
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-o", "-l", String(window.windowNumber), url.path]
        try? capture.run()
        capture.waitUntilExit()
        if capture.terminationStatus != 0 {
            let note = "screencapture exit \(capture.terminationStatus) window \(window.windowNumber) " +
                "frame \(NSStringFromRect(window.frame))"
            try? note.write(to: url.appendingPathExtension("txt"), atomically: true, encoding: .utf8)
        }
    }
}

/// Runs the swap script from inside the menu's tracking run loop, recording each phase after it settles.
@MainActor
private final class MergedMenuSwapDriver {
    /// (label, switcher segment title to select before recording; nil records the initial state)
    static let script: [(String, String?)] = [
        ("01-codex-open", nil),
        ("02-overview", "Overview"),
        ("03-claude", "Claude"),
        ("04-overview-again", "Overview"),
        ("05-codex-again", "Codex"),
        ("06-copilot", "Copilot"),
        ("07-zai", "z.ai / GLM"),
        ("08-claude-again", "Claude"),
        ("09-cursor", "Cursor"),
        ("10-overview-final", "Overview"),
        ("11-copilot-final", "Copilot"),
    ]
    private static let settleTicks = 6

    private let menu: NSMenu
    private let output: URL
    private let settings: SettingsStore
    private var ticks = 0
    private var step = 0
    private(set) var phases: [[String: Any]] = []

    init(menu: NSMenu, output: URL, settings: SettingsStore) {
        self.menu = menu
        self.output = output
        self.settings = settings
    }

    func tick() {
        self.ticks += 1
        guard self.ticks.isMultiple(of: Self.settleTicks) else { return }
        guard self.step < Self.script.count else {
            self.menu.cancelTracking()
            return
        }
        let (label, _) = Self.script[self.step]
        self.phases.append(MergedMenuScrollingSwapNativeProofTests.phaseReceipt(
            menu: self.menu, label: label, settings: self.settings))
        MergedMenuScrollingSwapNativeProofTests.capture(
            menu: self.menu, to: self.output.appendingPathComponent("\(label).png"))
        self.step += 1
        guard self.step < Self.script.count, let title = Self.script[self.step].1 else { return }
        guard let switcher = self.menu.items.lazy.compactMap({ $0.view as? ProviderSwitcherView }).first,
              let index = switcher._test_segmentTitles().firstIndex(of: title)
        else {
            self.phases.append(["error": "segment \(title) not found"])
            return
        }
        _ = switcher.handleKeyboardSelection(at: index)
    }
}
