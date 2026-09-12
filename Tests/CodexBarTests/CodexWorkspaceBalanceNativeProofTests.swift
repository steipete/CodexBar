import AppKit
import SwiftUI
import XCTest
@testable import CodexBar
@testable import CodexBarCore

@MainActor
final class CodexWorkspaceBalanceNativeProofTests: XCTestCase {
    func test_workspaceObservationsInCardsAndBalanceTokens() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["CODEXBAR_WORKSPACE_BALANCE_PROOF_DIR"] else {
            throw XCTSkip("Set CODEXBAR_WORKSPACE_BALANCE_PROOF_DIR for signed synthetic proof")
        }
        guard env["CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS"] == "1",
              env[CodexCredentialFileAccess.isolationEnvironmentKey] == "1",
              env["CODEXBAR_TEST_SESSION_FILE_ISOLATION"] == "1"
        else { return XCTFail("Use credential isolation") }
        let output = URL(
            fileURLWithPath: path,
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: output,
            withIntermediateDirectories: true)
        var authorityReceipts: [String: [String: Bool]] = [:]
        for scenario in ["matching", "different", "unscoped", "stale"] {
            let receipt = try await CodexWorkspaceAuthorityProof.run(scenario: scenario)
            XCTAssertTrue(receipt.values.allSatisfy { $0 == (scenario == "matching") })
            authorityReceipts[scenario] = receipt
            let unavailable = try await CodexWorkspaceAuthorityProof.run(scenario: scenario, unavailable: true)
            XCTAssertTrue(unavailable.values.allSatisfy { $0 == (scenario == "matching") })
            authorityReceipts[scenario + "Unavailable"] = unavailable
        }
        let rejectsUnscopedOAuth = try await CodexWorkspaceAuthorityProof.unscopedOAuthBalanceIsRejected()
        XCTAssertTrue(rejectsUnscopedOAuth)
        authorityReceipts["oauthMissingResponseAccount"] = ["rejected": rejectsUnscopedOAuth]
        try JSONSerialization.data(withJSONObject: authorityReceipts, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("authority.json"))
        let modelFixture = CodexExtraUsageFreshnessTests()
        let old = CreditsSnapshot(
            remaining: 1234.73,
            events: [],
            updatedAt: modelFixture.now.addingTimeInterval(-60),
            creditsAvailable: true,
            balanceIsWorkspace: true)
        let layout = MenuBarLayout(lines: [[.balance]])
        let base = CodexExtraUsageCost.attaching(
            to: modelFixture.usage(),
            credits: old)
        let observations = [
            old,
            CreditsSnapshot(
                remaining: 0,
                events: [],
                updatedAt: modelFixture.now,
                balanceReadSucceeded: false,
                creditsAvailable: true),
            CreditsSnapshot(
                remaining: 0,
                events: [],
                updatedAt: modelFixture.now,
                creditsAvailable: true,
                balanceIsWorkspace: true),
        ]
        var fixtures: [CodexWorkspacesNavigationFixture] = []
        var models: [UsageMenuCardView.Model] = []
        var values: [String] = []
        for observation in observations {
            let fixture = try CodexWorkspacesNavigationFixture(userDefaults: InMemoryUserDefaults())
            let snapshot = CodexExtraUsageCost.attaching(
                to: base,
                credits: observation)
            fixture.settings.mergeIcons = true
            fixture.settings.selectedMenuProvider = .codex
            fixture.settings.setMenuBarLayout(
                layout,
                for: nil)
            fixture.store._setSnapshotForTesting(
                snapshot,
                provider: .codex)
            fixture.store.credits = old
            let preview = MenuBarLayoutPreview(
                layout: layout,
                provider: .codex,
                settings: fixture.settings,
                store: fixture.store)
            values.append(preview.liveData(
                provider: .codex,
                snapshot: snapshot).balance ?? "unavailable")
            try models.append(modelFixture.card(
                snapshot: snapshot,
                live: old))
            fixtures.append(fixture)
        }
        defer { fixtures.forEach { $0.cleanup() } }
        XCTAssertEqual(values, ["1,235", "unavailable", "0"])
        let app = NSApplication.shared
        guard app.delegate == nil else { return XCTFail("Use a standalone test host") }
        let oldPolicy = app.activationPolicy()
        let previous = NSWorkspace.shared.frontmostApplication
        _ = app.setActivationPolicy(.regular)
        app.finishLaunching()
        let controller = try XCTUnwrap(fixtures.first).makeController()
        defer { controller.releaseStatusItemsForTesting() }
        let window = NSWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: 1090,
                height: 480),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.title = "CodexBar — Synthetic Workspace Credit Observations"
        window.isReleasedWhenClosed = false
        let titles = ["Workspace balance", "Newer unavailable balance", "Confirmed zero balance"]
        window.contentView = NSHostingView(rootView: HStack(
            alignment: .top,
            spacing: 24)
        {
            ForEach(
                models.indices,
                id: \.self)
            { index in
                VStack(
                    alignment: .leading,
                    spacing: 18)
                {
                    Text(titles[index]).font(.headline)
                    MenuBarLayoutPreview(
                        layout: layout,
                        provider: .codex,
                        settings: fixtures[index].settings,
                        store: fixtures[index].store)
                    UsageMenuCardView(
                        model: models[index],
                        width: 320)
                }
            }
        }.padding(24))
        defer { window.close(); _ = app.setActivationPolicy(oldPolicy); previous?.activate() }
        window.center()
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        try JSONSerialization.data(withJSONObject: [
            "pid": ProcessInfo.processInfo.processIdentifier, "window": window.windowNumber,
            "balances": values,
        ]).write(to: output.appendingPathComponent("state.json"))
        let deadline = Date().addingTimeInterval(600)
        while Date() < deadline, !FileManager.default.fileExists(atPath: output.appendingPathComponent("done").path) {
            if let event = app.nextEvent(
                matching: .any,
                until: Date().addingTimeInterval(0.02),
                inMode: .default,
                dequeue: true)
            {
                app.sendEvent(event)
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
