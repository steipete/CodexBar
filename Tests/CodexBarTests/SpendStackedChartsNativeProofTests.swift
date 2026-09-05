import AppKit
import CodexBarCore
import SwiftUI
import XCTest
@testable import CodexBar

@MainActor
final class SpendStackedChartsNativeProofTests: XCTestCase {
    func test_productionDailyAndHourlyStackedCharts() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let output = environment["CODEXBAR_STACKED_CHART_PROOF_DIRECTORY"] else {
            throw XCTSkip("Set CODEXBAR_STACKED_CHART_PROOF_DIRECTORY for signed synthetic chart proof")
        }
        guard environment["CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS"] == "1",
              environment[CodexCredentialFileAccess.isolationEnvironmentKey] == "1",
              environment["CODEXBAR_TEST_SESSION_FILE_ISOLATION"] == "1",
              environment["CODEXBAR_ALLOW_TEST_KEYCHAIN_ACCESS"] != "1"
        else { return XCTFail("Native chart proof requires credential and session isolation") }
        let phase = try XCTUnwrap(environment["CODEXBAR_STACKED_CHART_PROOF_PHASE"])
        guard ["before", "after"].contains(phase) else { return XCTFail("Unknown proof phase") }
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let group = try self.fixture()
        XCTAssertEqual(group.dailyPoints.count, 18)
        XCTAssertEqual(group.hourlyPoints.count, 18)
        XCTAssertEqual(try XCTUnwrap(group.totalCost), 137.15, accuracy: 0.000_001)
        XCTAssertEqual(group.hourlyPoints.reduce(0) { $0 + $1.cost }, 74.4, accuracy: 0.000_001)
        XCTAssertEqual(Set(group.providers.map(\.provider)), [.claude, .codex, .cursor])
        for points in Dictionary(grouping: group.dailyPoints, by: \.day).values {
            self.verifyOffsets(points.map { ($0.stackStart, $0.stackEnd, $0.cost) })
        }
        for points in Dictionary(grouping: group.hourlyPoints, by: \.hour).values {
            self.verifyOffsets(points.map { ($0.stackStart, $0.stackEnd, $0.cost) })
        }

        let app = NSApplication.shared
        guard app.delegate == nil else { return XCTFail("Requires a standalone test application") }
        let previousPolicy = app.activationPolicy()
        let previousApplication = NSWorkspace.shared.frontmostApplication
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 650),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.title = "CodexBar stacked charts — synthetic fixture"
        defer {
            window.close()
            _ = app.setActivationPolicy(previousPolicy)
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
                previousApplication?.activate()
            }
        }
        window.contentView = NSHostingView(rootView: StackedChartProofView(group: group, phase: phase))
        _ = app.setActivationPolicy(.regular)
        app.finishLaunching()
        window.center()
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        try await Task.sleep(for: .seconds(2))
        XCTAssertTrue(window.isVisible)

        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = [
            "-x", "-o", "-l", String(window.windowNumber),
            directory.appendingPathComponent("stacked-charts-\(phase).png").path,
        ]
        try capture.run()
        capture.waitUntilExit()
        XCTAssertEqual(capture.terminationStatus, 0)
    }

    private func verifyOffsets(_ points: [(start: Double, end: Double, cost: Double)]) {
        var end = 0.0
        for point in points {
            XCTAssertEqual(point.start, end, accuracy: 0.000_001)
            XCTAssertEqual(point.end - point.start, point.cost, accuracy: 0.000_001)
            end = point.end
        }
    }

    private func fixture() throws -> SpendDashboardModel.CurrencyGroup {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 5, hour: 18)))
        let dayKeys = ["2026-08-31", "2026-09-01", "2026-09-02", "2026-09-03", "2026-09-04", "2026-09-05"]
        let daily = [[10.0, 6, 4], [10, 8, 0.75], [10, 0, 0], [10, 0, 4], [0, 0, 0], [40, 22.2, 12.2]]
        let hourly = [[10.0, 6, 4], [10, 8, 0.2], [10, 0, 0], [0, 8, 0], [0, 0, 0], [10, 0.2, 8]]
        let providers: [UsageProvider] = [.claude, .codex, .cursor]
        let names = ["Claude", "Codex", "Cursor"]
        let inputs = try providers.enumerated().map { index, provider in
            let entries = zip(dayKeys, daily).map { day, costs in
                CostUsageDailyReport.Entry(
                    date: day,
                    inputTokens: nil,
                    outputTokens: nil,
                    totalTokens: 100,
                    costUSD: costs[index],
                    modelsUsed: nil,
                    modelBreakdowns: nil)
            }
            let hours = try hourly.enumerated().map { offset, costs in
                let date = try XCTUnwrap(calendar.date(
                    from: DateComponents(year: 2026, month: 9, day: 5, hour: 9 + offset)))
                return CostUsageHourlyEntry(hour: date, totalTokens: 100, costUSD: costs[index])
            }
            let total = daily.reduce(0) { $0 + $1[index] }
            let snapshot = CostUsageTokenSnapshot(
                sessionTokens: 100,
                sessionCostUSD: daily[5][index],
                last30DaysTokens: 600,
                last30DaysCostUSD: total,
                historyDays: 7,
                costProvenance: .listPriceEstimate,
                daily: entries,
                hourly: hours,
                updatedAt: now)
            return SpendDashboardModel.ProviderInput(provider: provider, displayName: names[index], snapshot: snapshot)
        }
        let model = SpendDashboardModel.build(inputs: inputs, requestedDays: 7, now: now, calendar: calendar)
        return try XCTUnwrap(model.groups.first)
    }
}

private struct StackedChartProofView: View {
    let group: SpendDashboardModel.CurrencyGroup
    let phase: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(self.phase.capitalized): daily and hourly stacked spend").font(.headline)
            Text("Synthetic data · three providers · zero and thin segments").font(.caption)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack {
                        SpendDashboardCurrencySection(group: self.group, requestedDays: 7, hidePersonalInfo: true)
                        Color.clear.frame(height: 1).id("charts-bottom")
                    }
                }
                .task {
                    try? await Task.sleep(for: .milliseconds(250))
                    proxy.scrollTo("charts-bottom", anchor: .bottom)
                }
            }
        }
        .padding(20)
        .environment(\.locale, Locale(identifier: "en_US_POSIX"))
        .environment(\.timeZone, .gmt)
        .preferredColorScheme(.light)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
