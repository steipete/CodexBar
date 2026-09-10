import AppKit
import SwiftUI
import XCTest
@testable import CodexBar
@testable import CodexBarCore

@MainActor
final class SpendDailyLedgerNativeProofTests: XCTestCase {
    func test_settingsWidthAndUnknownSpend() throws {
        guard let path = ProcessInfo.processInfo.environment["CODEXBAR_LEDGER_NATIVE_DIR"] else {
            throw XCTSkip("Set CODEXBAR_LEDGER_NATIVE_DIR for native ledger proof")
        }
        let output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let group = try Self.group()
        let app = NSApplication.shared
        guard app.delegate == nil else { return XCTFail("Requires a standalone test application") }
        let previousPolicy = app.activationPolicy()
        let previousApp = NSWorkspace.shared.frontmostApplication
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 700),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "CodexBar Synthetic Ledger Proof"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 800, height: 500)
        window.contentView = NSHostingView(rootView: HStack(spacing: 0) {
            Text("Synthetic settings sidebar").frame(width: 260, height: 700)
                .background(Color(nsColor: .controlBackgroundColor))
            ScrollViewReader { proxy in
                ScrollView {
                    VStack {
                        SpendDashboardCurrencySection(group: group, requestedDays: 3, hidePersonalInfo: true)
                        Color.clear.frame(height: 1).id("bottom")
                    }.padding(20)
                }.task { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }.preferredColorScheme(.light))
        defer {
            window.close()
            _ = app.setActivationPolicy(previousPolicy)
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
                previousApp?.activate()
            }
        }
        _ = app.setActivationPolicy(.regular)
        app.finishLaunching()
        window.center()
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        let deadline = Date().addingTimeInterval(600)
        let done = output.appendingPathComponent("done").path
        while !FileManager.default.fileExists(atPath: done), Date() < deadline {
            let receipt = [
                "pid": String(ProcessInfo.processInfo.processIdentifier),
                "window": String(window.windowNumber),
                "contentSize": NSStringFromSize(window.contentView?.bounds.size ?? .zero),
                "ledgerDays": String(group.dailySummaries.count),
                "unknownDay": String(group.dailySummaries.last?.totalCost == nil),
            ]
            try JSONEncoder().encode(receipt).write(to: output.appendingPathComponent("state.json"), options: .atomic)
            if let event = app.nextEvent(
                matching: .any, until: Date().addingTimeInterval(0.02), inMode: .default, dequeue: true)
            {
                app.sendEvent(event)
            }
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: done), "Native proof timed out")
    }

    func test_remoteCostControls() async throws {
        guard let path = ProcessInfo.processInfo.environment["CODEXBAR_REMOTE_COST_NATIVE_DIR"] else {
            throw XCTSkip("Set CODEXBAR_REMOTE_COST_NATIVE_DIR for native remote-cost proof")
        }
        let output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let settings = testSettingsStore(suiteName: "RemoteCostNativeProof")
        let costs = RemoteCodexCostStore { host, _, _ in
            if host == "offline" { throw RemoteCodexCostError.unavailable }
            return RemoteCodexCostFetcherTests.summary()
        }
        let app = NSApplication.shared
        guard app.delegate == nil else { return XCTFail("Requires a standalone test application") }
        let previousPolicy = app.activationPolicy()
        let previousApp = NSWorkspace.shared.frontmostApplication
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 620),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.title = "CodexBar Remote Cost Proof — Synthetic Data"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: VStack(alignment: .leading, spacing: 24) {
            RemoteCodexCostHostsEditor(settings: settings)
            Divider()
            RemoteCodexCostView(costs: costs, hidePersonalInfo: false)
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .preferredColorScheme(.light))
        defer {
            costs.cancel()
            window.close()
            _ = app.setActivationPolicy(previousPolicy)
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
                previousApp?.activate()
            }
        }
        _ = app.setActivationPolicy(.regular)
        app.finishLaunching()
        window.center()
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        let deadline = Date().addingTimeInterval(600)
        let done = output.appendingPathComponent("done").path
        while !FileManager.default.fileExists(atPath: done), Date() < deadline {
            costs.refresh(hosts: settings.codexRemoteCostHosts, historyDays: 30)
            let receipt = [
                "pid": String(ProcessInfo.processInfo.processIdentifier),
                "hosts": settings.codexRemoteCostHosts,
                "reports": String(costs.reports.count),
                "errors": String(costs.reports.count(where: { $0.error != nil })),
            ]
            try JSONEncoder().encode(receipt).write(to: output.appendingPathComponent("state.json"), options: .atomic)
            let capture = output.appendingPathComponent("capture")
            if FileManager.default.fileExists(atPath: capture.path), let view = window.contentView,
               let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
            {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?
                    .write(to: output.appendingPathComponent("remote-costs.png"))
                try FileManager.default.removeItem(at: capture)
            }
            if let event = app.nextEvent(
                matching: .any, until: Date(), inMode: .default, dequeue: true)
            {
                app.sendEvent(event)
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: done), "Native proof timed out")
    }

    private static func group() throws -> SpendDashboardModel.CurrencyGroup {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 16, hour: 12)))
        let entries: [CostUsageDailyReport.Entry] = [
            .init(
                date: "2026-07-14",
                inputTokens: 5,
                outputTokens: 5,
                totalTokens: 10,
                requestCount: 1,
                costUSD: 2,
                modelsUsed: ["fixture-priced"],
                modelBreakdowns: [.init(modelName: "fixture-priced", costUSD: 2, totalTokens: 10)]),
            .init(
                date: "2026-07-16",
                inputTokens: 10,
                outputTokens: 10,
                totalTokens: 20,
                requestCount: 2,
                costUSD: nil,
                modelsUsed: ["fixture-unpriced"],
                modelBreakdowns: [.init(modelName: "fixture-unpriced", costUSD: nil, totalTokens: 20)]),
        ]
        let snapshot = CostUsageTokenSnapshot(
            sessionTokens: 20,
            sessionCostUSD: nil,
            last30DaysTokens: 30,
            last30DaysCostUSD: nil,
            historyDays: 3,
            daily: entries,
            updatedAt: now)
        let model = SpendDashboardModel.build(
            inputs: [.init(provider: .codex, displayName: "Synthetic Codex", snapshot: snapshot)],
            requestedDays: 3,
            now: now,
            calendar: calendar)
        let group = try XCTUnwrap(model.groups.first)
        XCTAssertEqual(group.dailySummaries.count, 3)
        XCTAssertEqual(group.dailySummaries.first?.totalCost, 2)
        XCTAssertEqual(group.dailySummaries[1].totalCost, 0)
        XCTAssertNil(group.dailySummaries.last?.totalCost)
        return group
    }
}
