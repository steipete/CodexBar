import AppKit
import Observation
import SwiftUI
import XCTest
@testable import CodexBar
@testable import CodexBarCore

/// Opt-in computer-use proof. Uses only in-memory synthetic input and production card views.
@MainActor
final class QuotaWindowNativeProofTests: XCTestCase {
    func test_interactiveQuotaCards() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["CODEXBAR_QUOTA_NATIVE_DIR"] else {
            throw XCTSkip("Set CODEXBAR_QUOTA_NATIVE_DIR for local quota-window proof")
        }
        guard SettingsStore.isRunningTests,
              environment["CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS"] == "1",
              environment[CodexCredentialFileAccess.isolationEnvironmentKey] == "1",
              environment["CODEXBAR_TEST_SESSION_FILE_ISOLATION"] == "1"
        else { return XCTFail("Native proof requires credential and session isolation") }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let state = QuotaNativeState()
        let app = NSApplication.shared
        guard app.delegate == nil else { return XCTFail("Requires a standalone test application") }
        let previousApp = NSWorkspace.shared.frontmostApplication
        let oldPolicy = app.activationPolicy()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 430, height: 870),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.title = "CodexBar — Synthetic Quota History"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: QuotaNativeView(state: state))
        window.center()
        defer {
            window.close()
            _ = app.setActivationPolicy(oldPolicy)
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
                previousApp?.activate()
            }
        }
        XCTAssertTrue(app.setActivationPolicy(.regular))
        app.finishLaunching()
        app.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        let timer = Timer(timeInterval: 0.2, repeats: true) { _ in
            MainActor.assumeIsolated {
                let receipt: [String: Any] = [
                    "pid": ProcessInfo.processInfo.processIdentifier,
                    "window": window.windowNumber,
                    "provider": state.provider.rawValue,
                    "scenario": state.scenario,
                    "dark": state.dark,
                    "kpis": state.model.inlineUsageDashboard?.kpis.map {
                        ["title": $0.title, "value": $0.value]
                    } ?? [],
                ]
                do {
                    try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys, .prettyPrinted])
                        .write(to: root.appendingPathComponent("state.json"), options: .atomic)
                } catch { XCTFail("Could not write native proof receipt") }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        defer { timer.invalidate() }
        let done = root.appendingPathComponent("done").path
        let deadline = Date().addingTimeInterval(900)
        while !FileManager.default.fileExists(atPath: done), Date() < deadline {
            if let event = app.nextEvent(
                matching: .any, until: Date().addingTimeInterval(0.02), inMode: .default, dequeue: true)
            { app.sendEvent(event) }
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: done), "Native proof timed out")
    }
}

@MainActor
@Observable
private final class QuotaNativeState {
    var provider = UsageProvider.codex
    var scenario = "Complete"
    var dark = false

    var model: UsageMenuCardView.Model {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Self.date("2026-07-15T12:00:00Z")
        let partial = self.scenario == "Partial price"
        let currentCost = partial ? 4.0 : 10.0
        let history = CostUsageTokenSnapshot(
            sessionTokens: 600,
            sessionCostUSD: currentCost,
            last30DaysTokens: 1000,
            last30DaysCostUSD: 4 + currentCost,
            historyDays: 30,
            daily: [
                .init(
                    date: "2026-07-08",
                    inputTokens: 300,
                    outputTokens: 100,
                    totalTokens: 400,
                    costUSD: 4,
                    modelsUsed: nil,
                    modelBreakdowns: nil),
                .init(
                    date: "2026-07-15",
                    inputTokens: 500,
                    outputTokens: 100,
                    totalTokens: 600,
                    costUSD: currentCost,
                    modelsUsed: nil,
                    modelBreakdowns: partial ? [
                        .init(modelName: "fixture-priced", costUSD: 4, totalTokens: 400),
                        .init(modelName: "fixture-unpriced", costUSD: nil, totalTokens: 200),
                    ] : nil,
                    unpricedRequestCount: partial ? 1 : nil),
            ], updatedAt: now)
        let snapshot = UsageSnapshot(
            primary: .init(
                usedPercent: 20,
                windowMinutes: 300,
                resetsAt: now.addingTimeInterval(3600),
                resetDescription: nil),
            secondary: .init(
                usedPercent: 50,
                windowMinutes: 10080,
                resetsAt: self.scenario == "No reset" ? nil : Self.date("2026-07-18T15:00:00Z"),
                resetDescription: nil),
            updatedAt: now)
        return UsageMenuCardView.Model.make(.init(
            provider: self.provider,
            metadata: ProviderDefaults.metadata[self.provider]!,
            snapshot: snapshot,
            credits: nil,
            creditsError: nil,
            dashboardError: nil,
            tokenSnapshot: history,
            tokenError: nil,
            account: AccountInfo(
                email: nil,
                plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: true,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: true,
            costUsageBucketCalendar: calendar,
            now: now))
    }

    private static func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }
}

@MainActor
private struct QuotaNativeView: View {
    @Bindable var state: QuotaNativeState

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Button("Codex") { self.state.provider = .codex }
                Button("Claude") { self.state.provider = .claude }
                Toggle("Dark", isOn: self.$state.dark).toggleStyle(.checkbox)
            }
            HStack {
                ForEach(["Complete", "Partial price", "No reset"], id: \.self) { scenario in
                    Button(scenario) { self.state.scenario = scenario }
                }
            }
            Text("Synthetic local history · \(self.state.scenario)")
                .font(.caption).foregroundStyle(.secondary)
            UsageMenuCardView(model: self.state.model, width: 320)
                .frame(width: 320)
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(width: 430, height: 870, alignment: .top)
        .environment(\.locale, Locale(identifier: "en_US_POSIX"))
        .environment(\.colorScheme, self.state.dark ? .dark : .light)
        .background(self.state.dark ? Color(nsColor: .init(white: 0.12, alpha: 1)) : Color.white)
    }
}
