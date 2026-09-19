import AppKit
import CodexBarCore
import Observation
import SwiftUI
import WidgetKit
import XCTest
@testable import CodexBarWidget

@MainActor
final class WidgetReadabilityNativeProofTests: XCTestCase {
    func test_syntheticWidgetViews() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["CODEXBAR_WIDGET_READABILITY_PROOF_DIR"] else {
            throw XCTSkip("Set CODEXBAR_WIDGET_READABILITY_PROOF_DIR for signed native widget proof")
        }
        guard environment["CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS"] == "1",
              environment["CODEXBAR_TEST_CODEX_FILE_ISOLATION"] == "1",
              environment["CODEXBAR_TEST_SESSION_FILE_ISOLATION"] == "1",
              environment["CODEXBAR_ALLOW_TEST_KEYCHAIN_ACCESS"] != "1"
        else { return XCTFail("Native widget proof requires credential and session isolation") }
        let output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let application = NSApplication.shared
        guard application.delegate == nil else { return XCTFail("Use a standalone native test host") }
        let previousPolicy = application.activationPolicy()
        let previousApplication = NSWorkspace.shared.frontmostApplication
        let model = WidgetReadabilityProofModel()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 950, height: 475),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.title = "CodexBar — Synthetic Widget Proof"
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = NSHostingView(rootView: WidgetReadabilityProofView(model: model))
        defer {
            window.close()
            _ = application.setActivationPolicy(previousPolicy)
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
                previousApplication?.activate()
            }
        }
        _ = application.setActivationPolicy(.regular)
        application.finishLaunching()
        window.center()
        window.makeKeyAndOrderFront(nil)
        application.activate(ignoringOtherApps: true)
        let done = output.appendingPathComponent("done").path
        let deadline = Date().addingTimeInterval(1800)
        while !FileManager.default.fileExists(atPath: done), Date() < deadline {
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            try JSONSerialization.data(withJSONObject: [
                "pid": ProcessInfo.processInfo.processIdentifier,
                "window": window.windowNumber,
                "fixture": model.fixture,
                "selected": model.selected.rawValue,
                "pagerChanges": model.pagerChanges,
                "mode": model.mode,
                "showUsed": model.showUsed,
                "margin": model.margin,
                "syntheticOnly": true,
                "simulatedWidgetKitMargins": true,
                "realWidgetKitCompositor": false,
            ], options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent("state.json"), options: .atomic)
            if let event = application.nextEvent(
                matching: .any, until: Date().addingTimeInterval(0.05), inMode: .default, dequeue: true)
            {
                application.sendEvent(event)
            }
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: done), "Native widget proof timed out")
        XCTAssertGreaterThan(model.pagerChanges, 0, "Exercise the actual pager button in the native view")
    }
}

@MainActor
@Observable
private final class WidgetReadabilityProofModel {
    var fixture = "Quotas"
    var selected: UsageProvider = .codex
    var mode = "Color"
    var showUsed = false
    var margin: Double = 14
    var pagerChanges = 0
    let now = Date()
    let providers: [UsageProvider] = [.codex, .claude, .alibabatokenplan, .kimi]

    var renderingMode: WidgetRenderingMode {
        switch self.mode {
        case "Monochrome": .vibrant
        case "Tinted": .accented
        default: .fullColor
        }
    }

    func selectFixture(_ fixture: String) {
        self.fixture = fixture
        self.selected = fixture == "Long name" ? .alibabatokenplan : fixture == "Tokens only" ? .claude : .codex
    }

    var snapshot: WidgetSnapshot {
        let entries = self.providers.map { provider -> WidgetSnapshot.ProviderEntry in
            let tokensOnly = self.fixture == "Tokens only"
            let stale = self.fixture == "Long name"
            let primary = RateWindow(
                usedPercent: 1,
                windowMinutes: 300,
                resetsAt: self.now.addingTimeInterval(3600),
                resetDescription: nil)
            let weekly = RateWindow(
                usedPercent: 96,
                windowMinutes: 10080,
                resetsAt: self.now.addingTimeInterval(86400),
                resetDescription: nil)
            let primaryID = provider == .codex ? "session" : "primary"
            let weeklyID = provider == .codex ? "weekly" : "secondary"
            var rows: [WidgetSnapshot.WidgetUsageRowSnapshot] = tokensOnly ? [] : [
                .init(id: primaryID, title: "Session", percentLeft: 99, window: primary),
                .init(id: weeklyID, title: "Weekly", percentLeft: 4, window: weekly),
            ]
            if provider == .kimi, !tokensOnly {
                rows.append(.init(id: "kimi-monthly", title: "Monthly", percentLeft: 40))
                rows.append(.init(id: "kimi-code-7d", title: "Code 7d", percentLeft: 1))
            }
            return WidgetSnapshot.ProviderEntry(
                provider: provider,
                updatedAt: stale ? self.now.addingTimeInterval(-172_800) : self.now,
                primary: tokensOnly ? nil : primary,
                secondary: tokensOnly ? nil : weekly,
                tertiary: nil,
                usageRows: rows,
                creditsRemaining: nil,
                codeReviewRemainingPercent: provider == .codex && !tokensOnly ? 0 : nil,
                tokenUsage: .init(
                    sessionCostUSD: tokensOnly ? nil : 1.5,
                    sessionTokens: 1200,
                    last30DaysCostUSD: tokensOnly ? nil : 30,
                    last30DaysTokens: 24000,
                    sessionLabel: "Today",
                    updatedAt: self.now),
                dailyUsage: [])
        }
        return WidgetSnapshot(entries: entries, usageBarsShowUsed: self.showUsed, generatedAt: self.now)
    }
}

@MainActor
private struct WidgetReadabilityProofView: View {
    @Bindable var model: WidgetReadabilityProofModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                ForEach(["Quotas", "Long name", "Tokens only"], id: \.self) { name in
                    Button(name) { self.model.selectFixture(name) }
                }
                Button("Appearance: \(self.model.mode)") {
                    self.model.mode = self.model.mode == "Color" ? "Monochrome"
                        : self.model.mode == "Monochrome" ? "Tinted" : "Color"
                }
                Toggle("Show used", isOn: self.$model.showUsed)
                Button("Margins: \(Int(self.model.margin)) pt") {
                    self.model.margin = self.model.margin == 14 ? 16 : 14
                }
            }
            HStack(alignment: .top, spacing: 24) {
                self.tile(tileSize: .small, size: CGSize(width: 155, height: 155))
                self.tile(tileSize: .medium, size: CGSize(width: 329, height: 155))
                self.tile(tileSize: .large, size: CGSize(width: 329, height: 345))
            }
            Spacer(minLength: 0)
            Text("Production widget views · synthetic data · simulated WidgetKit margins and appearance")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
    }

    @ViewBuilder
    private func tile(tileSize: WidgetTileSize, size: CGSize) -> some View {
        if let entry = self.model.snapshot.entries.first(where: { $0.provider == self.model.selected.instanceID }) {
            UsageTile(entry: entry, size: tileSize) {
                ProviderPagerHeader(
                    providers: self.model.providers,
                    selected: self.model.selected,
                    updatedAt: entry.updatedAt,
                    size: tileSize)
            }
            .environment(\.widgetUsageShowsUsed, self.model.showUsed)
            .environment(\.widgetRenderingModeOverride, self.model.renderingMode)
            .environment(\.widgetProviderSelectionOverride) { provider in
                self.model.selected = provider
                self.model.pagerChanges += 1
            }
            .frame(width: size.width - self.model.margin * 2, height: size.height - self.model.margin * 2)
            .padding(self.model.margin)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(.gray.opacity(0.2)))
        }
    }
}
