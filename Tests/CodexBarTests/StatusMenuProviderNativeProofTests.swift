import AppKit
import Foundation
import QuartzCore
import XCTest
@testable import CodexBar
@testable import CodexBarCore

/// Opt-in native menu proof with disposable settings and no provider transports.
@MainActor
final class StatusMenuProviderNativeProofTests: XCTestCase {
    func test_warmedStatusProviderMenu() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let directoryPath = environment["CODEXBAR_STATUS_PROVIDER_PROOF_DIR"] else {
            throw XCTSkip("Set CODEXBAR_STATUS_PROVIDER_PROOF_DIR for isolated native UI proof.")
        }
        guard SettingsStore.isRunningTests,
              environment["CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS"] == "1",
              environment[CodexCredentialFileAccess.isolationEnvironmentKey] == "1",
              environment["CODEXBAR_TEST_SESSION_FILE_ISOLATION"] == "1",
              environment["CODEXBAR_ALLOW_TEST_KEYCHAIN_ACCESS"] != "1",
              environment["CODEXBAR_TEST_CODEX_FILE_FIXTURES"] == nil
        else {
            return XCTFail("Native proof requires credential and session isolation.")
        }
        let directory = URL(fileURLWithPath: directoryPath, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fixture = try CodexWorkspacesNavigationFixture(userDefaults: InMemoryUserDefaults())
        defer { fixture.cleanup() }
        let overview = environment["CODEXBAR_STATUS_PROVIDER_PROOF_OVERVIEW"] == "1"
        let compact = environment["CODEXBAR_STATUS_PROVIDER_PROOF_COMPACT"] == "1"
        Self.seedProviderMenu(in: fixture, overview: overview, compact: compact)

        let oldRendering = StatusItemController.menuCardRenderingEnabled
        let oldRefresh = StatusItemController.menuRefreshEnabled
        StatusItemController.menuCardRenderingEnabled = true
        StatusItemController.setMenuRefreshEnabledForTesting(true)
        defer {
            StatusItemController.menuCardRenderingEnabled = oldRendering
            StatusItemController.setMenuRefreshEnabledForTesting(oldRefresh)
        }
        let controller = fixture.makeController()
        defer { controller.releaseStatusItemsForTesting() }
        let menu: NSMenu = if compact {
            controller.makeMenu(for: .claude)
        } else {
            try XCTUnwrap(controller.mergedMenu)
        }
        let application = NSApplication.shared
        guard application.delegate == nil, UserDefaults.standard.object(forKey: "NSOpen") == nil else {
            return XCTFail("Native proof requires a standalone test application.")
        }
        let oldPolicy = application.activationPolicy()
        let previousApplication = NSWorkspace.shared.frontmostApplication
        let host = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: compact ? 900 : 160),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        host.title = "CodexBar Synthetic Status Proof"
        host.isReleasedWhenClosed = false
        host.center()
        let button = StatusProviderProofButton(frame: NSRect(x: 140, y: 65, width: 200, height: 32))
        button.title = "Open provider menu"
        button.keyEquivalent = "\r"
        button.proofMenu = menu
        button.target = button
        button.action = #selector(StatusProviderProofButton.openMenu)
        host.contentView?.addSubview(button)
        defer {
            menu.cancelTracking()
            host.close()
            _ = application.setActivationPolicy(oldPolicy)
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
                previousApplication?.activate()
            }
        }
        XCTAssertTrue(application.setActivationPolicy(.regular))
        application.finishLaunching()
        application.activate(ignoringOtherApps: true)
        host.makeKeyAndOrderFront(nil)
        if environment["CODEXBAR_STATUS_PROVIDER_PROOF_BENCHMARK"] == "1" {
            controller.menuWillOpen(menu)
            defer { controller.menuDidClose(menu) }
            try Self.measureHighlights(in: menu, host: host, directory: directory)
            return
        }

        var sawExpandedAccount = false
        var sawCollapsedAccount = false
        var targetCompactID: String?
        let deadline = Date().addingTimeInterval(600)
        // Common-mode receipts keep updating while the external driver interacts with NSMenu.
        let timer = Timer(timeInterval: 0.1, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard let menu = button.proofMenu else { return }
                if targetCompactID == nil {
                    targetCompactID = menu.items.compactMap { $0.representedObject as? String }
                        .first { $0.contains("Compact-") }
                }
                let targetCardID = targetCompactID?.replacingOccurrences(of: "Compact-", with: "Card-")
                if let targetCompactID, let targetCardID,
                   controller.openMenus[ObjectIdentifier(menu)] != nil
                {
                    if menu.items.contains(where: { ($0.representedObject as? String) == targetCardID }) {
                        sawExpandedAccount = true
                    } else if sawExpandedAccount,
                              menu.items.contains(where: { ($0.representedObject as? String) == targetCompactID })
                    {
                        sawCollapsedAccount = true
                    }
                }
                var receipt = Self.nativeReceipt(menu: menu, host: host, fixture: fixture, controller: controller)
                if let row = menu.items.first(where: {
                    guard let id = $0.representedObject as? String else { return false }
                    return id == targetCompactID || id == targetCardID
                })?.view, let window = row.window {
                    let rect = window.convertToScreen(row.convert(row.bounds, to: nil))
                    receipt["targetRect"] = NSStringFromRect(rect)
                    receipt["screenHeight"] = String(Double(NSScreen.screens.first?.frame.maxY ?? 0))
                }
                receipt["configuredAccounts"] = String(fixture.settings.tokenAccounts(for: .claude).count)
                receipt["validAccountSnapshots"] = String(fixture.store.validTokenAccountSnapshots(
                    provider: .claude, accounts: fixture.settings.tokenAccounts(for: .claude)).count)
                receipt["expandedAccounts"] = String(controller.compactAccountExpandedIDs.count)
                receipt["sawExpansion"] = String(sawExpandedAccount)
                receipt["sawCollapse"] = String(sawCollapsedAccount)
                receipt["compactRows"] = String(menu.items.count(where: {
                    ($0.representedObject as? String)?.contains("Compact-") == true
                }))
                do {
                    try JSONEncoder().encode(receipt).write(
                        to: directory.appendingPathComponent("state.json"), options: .atomic)
                } catch {
                    XCTFail("Could not write native proof receipt: \(error)")
                }
                if FileManager.default.fileExists(atPath: directory.appendingPathComponent("done").path)
                    || Date() >= deadline
                {
                    menu.cancelTracking()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        defer { timer.invalidate() }
        let done = directory.appendingPathComponent("done").path
        while !FileManager.default.fileExists(atPath: done), Date() < deadline {
            if let event = application.nextEvent(
                matching: .any, until: Date().addingTimeInterval(0.02), inMode: .default, dequeue: true)
            {
                application.sendEvent(event)
            }
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: done), "Native proof timed out")
        if compact {
            XCTAssertTrue(sawExpandedAccount, "Expand one inactive account through its real menu row")
            XCTAssertTrue(sawCollapsedAccount, "Collapse the expanded account again")
        }
    }

    private static func seedProviderMenu(
        in fixture: CodexWorkspacesNavigationFixture,
        overview: Bool,
        compact: Bool)
    {
        let providers: [UsageProvider] = compact ? [.claude] : [.claude, .codex, .grok]
        for provider in providers {
            fixture.settings.setProviderEnabled(
                provider: provider,
                metadata: ProviderDescriptorRegistry.descriptor(for: provider).metadata,
                enabled: true)
            _ = fixture.settings.setMergedOverviewProviderSelection(
                provider: provider,
                isSelected: overview,
                activeProviders: providers)
        }
        fixture.settings.mergeIcons = true
        fixture.settings.selectedMenuProvider = .claude
        fixture.settings.mergedMenuLastSelectedWasOverview = overview
        fixture.settings.statusChecksEnabled = true
        for provider in providers {
            fixture.store._setSnapshotForTesting(
                UsageSnapshot(
                    primary: RateWindow(
                        usedPercent: 25,
                        windowMinutes: 300,
                        resetsAt: Date().addingTimeInterval(3600),
                        resetDescription: nil),
                    secondary: nil,
                    updatedAt: Date()),
                provider: provider)
        }
        if overview { Self.seedOverviewHistory(in: fixture) }
        if compact {
            fixture.settings.setProviderEnabled(
                provider: .codex,
                metadata: ProviderDescriptorRegistry.descriptor(for: .codex).metadata,
                enabled: false)
            Self.seedCompactAccounts(in: fixture)
            if ProcessInfo.processInfo.environment["CODEXBAR_STATUS_PROVIDER_PROOF_HIDE_SESSION"] == "1" {
                fixture.settings.setUsageItemVisible(false, itemID: .metric("primary"), for: .claude)
            }
        }
        fixture.store.statusComponents[.claude] = [
            ProviderStatusComponent(id: "claude", name: "Claude.ai", indicator: .none, status: "operational"),
        ]
        fixture.store.statusComponents[.codex] = [
            ProviderStatusComponent(id: "codex", name: "Codex", indicator: .none, status: "operational"),
        ]
    }

    private static func nativeReceipt(
        menu: NSMenu,
        host: NSWindow,
        fixture: CodexWorkspacesNavigationFixture,
        controller: StatusItemController) -> [String: String]
    {
        let overviewRow = menu.items.first {
            ($0.representedObject as? String) == "overviewRow-codex"
        }?.view as? MenuRowContainerView
        let contentHost = overviewRow?.subviews.last
        let statusItem = menu.items.first { $0.title == L("Status Page") }
        let submenu = statusItem?.submenu
        return [
            "outerVibrancy": String(overviewRow?.allowsVibrancy ?? false),
            "innerVibrancy": String(contentHost?.allowsVibrancy ?? false),
            "swiftUIHighlighted": String(overviewRow?.highlightState.isHighlighted ?? false),
            "pid": String(ProcessInfo.processInfo.processIdentifier),
            "window": String(host.windowNumber),
            "selected": fixture.settings.selectedMenuProvider?.rawValue ?? "none",
            "overview": String(fixture.settings.mergedMenuLastSelectedWasOverview),
            "highlighted": menu.highlightedItem?.representedObject as? String ?? "none",
            "overviewSubmenus": String(menu.items.count(where: {
                ($0.representedObject as? String)?.hasPrefix("overviewRow-") == true && $0.submenu != nil
            })),
            "statusProvider": submenu?.items.first?.toolTip
                ?? submenu?.items.last?.identifier?.rawValue ?? "website-only",
            "cachedSelections": String(controller.mergedSwitcherContentCaches[ObjectIdentifier(menu)]?
                .count ?? 0),
        ]
    }

    private static func measureHighlights(in menu: NSMenu, host: NSWindow, directory: URL) throws {
        let item = try XCTUnwrap(menu.items.first { ($0.representedObject as? String) == "overviewRow-codex" })
        let row = try XCTUnwrap(item.view as? MenuRowContainerView)
        let width = max(300, row.frame.width)
        let size = NSSize(width: width, height: row.measuredHeight(width: width))
        host.setContentSize(size)
        host.contentView = row
        row.frame = NSRect(origin: .zero, size: size)
        row.layoutSubtreeIfNeeded()
        row.displayIfNeeded()
        CATransaction.flush()
        func toggle(_ selected: Bool) -> Double {
            let start = DispatchTime.now().uptimeNanoseconds
            row.setHighlighted(selected)
            row.layoutSubtreeIfNeeded()
            row.displayIfNeeded()
            CATransaction.flush()
            _ = RunLoop.main.run(mode: .default, before: Date())
            return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        }
        let first = toggle(true)
        var samples: [Double] = []
        var swiftUIChanges = 0
        for index in 0..<200 {
            samples.append(autoreleasepool { toggle(index % 2 != 0) })
            if row.highlightState.isHighlighted { swiftUIChanges += 1 }
        }
        let sorted = samples.sorted()
        let receipt: [String: Any] = [
            "firstMilliseconds": first,
            "averageMilliseconds": samples.reduce(0, +) / Double(samples.count),
            "p95Milliseconds": sorted[189],
            "maxMilliseconds": sorted[199],
            "toggles": samples.count,
            "samplesMilliseconds": samples,
            "swiftUIHighlightChanges": swiftUIChanges,
            "outerVibrancy": row.allowsVibrancy,
            "innerVibrancy": row.subviews.last?.allowsVibrancy ?? false,
        ]
        try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("benchmark.json"), options: .atomic)
    }

    private static func seedCompactAccounts(in fixture: CodexWorkspacesNavigationFixture) {
        fixture.settings.multiAccountMenuLayout = .stacked
        for index in 0..<5 {
            fixture.settings.addTokenAccount(
                provider: .claude, label: "Synthetic Account \(index + 1)", token: "fixture-oauth-\(index)")
        }
        fixture.settings.setActiveTokenAccountIndex(0, for: .claude)
        let accounts = fixture.settings.tokenAccounts(for: .claude)
        let now = Date()
        fixture.store.accountSnapshots[.claude] = accounts.enumerated().map { index, account in
            TokenAccountUsageSnapshot(
                account: account,
                snapshot: UsageSnapshot(
                    primary: RateWindow(
                        usedPercent: index == 0 ? 20 : Double(99 - index),
                        windowMinutes: 300,
                        resetsAt: now.addingTimeInterval(Double(index + 1) * 3600),
                        resetDescription: nil),
                    secondary: RateWindow(
                        usedPercent: Double(85 - index * 5),
                        windowMinutes: 10080,
                        resetsAt: now.addingTimeInterval(Double(index + 1) * 86400),
                        resetDescription: nil),
                    updatedAt: now),
                error: nil,
                sourceLabel: "synthetic",
                cacheKey: fixture.store.tokenAccountSnapshotCacheKey(provider: .claude, account: account))
        }
    }

    private static func seedOverviewHistory(in fixture: CodexWorkspacesNavigationFixture) {
        fixture.settings.costUsageEnabled = true
        fixture.settings.costSummaryDisplayStyle = .both
        let now = Date()
        let day = CostUsageScanner.CostUsageDayRange.dayKey(from: now)
        for provider in [UsageProvider.claude, .codex] {
            fixture.store._setTokenSnapshotForTesting(
                CostUsageTokenSnapshot(
                    sessionTokens: 100,
                    sessionCostUSD: 1.5,
                    last30DaysTokens: 100,
                    last30DaysCostUSD: 1.5,
                    daily: [.init(
                        date: day,
                        inputTokens: 70,
                        outputTokens: 30,
                        totalTokens: 100,
                        costUSD: 1.5,
                        modelsUsed: nil,
                        modelBreakdowns: nil)],
                    updatedAt: now),
                provider: provider)
        }
    }
}

@MainActor
private final class StatusProviderProofButton: NSButton {
    var proofMenu: NSMenu?

    @objc func openMenu() {
        self.proofMenu?.popUp(positioning: nil, at: NSPoint(x: 0, y: self.bounds.maxY), in: self)
    }
}
