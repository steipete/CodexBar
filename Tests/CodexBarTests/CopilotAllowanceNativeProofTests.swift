import AppKit
import SwiftUI
import XCTest
@testable import CodexBar
@testable import CodexBarCore

@MainActor
final class CopilotAllowanceNativeProofTests: XCTestCase {
    func test_offlineAllowanceEditing() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["CODEXBAR_COPILOT_ALLOWANCE_PROOF_DIR"] else {
            throw XCTSkip("Set CODEXBAR_COPILOT_ALLOWANCE_PROOF_DIR for signed synthetic proof")
        }
        guard SettingsStore.isRunningTests,
              env["CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS"] == "1",
              env[CodexCredentialFileAccess.isolationEnvironmentKey] == "1",
              env["CODEXBAR_TEST_SESSION_FILE_ISOLATION"] == "1",
              env["CODEXBAR_ALLOW_TEST_KEYCHAIN_ACCESS"] != "1"
        else { return XCTFail("Use a credential-isolated test host") }
        let output = URL(
            fileURLWithPath: path,
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: output,
            withIntermediateDirectories: true)
        let fixture = CopilotAllowanceFixture()
        let zeroCreditsProof = env["CODEXBAR_COPILOT_ZERO_CREDITS"] == "1"
        if !zeroCreditsProof {
            fixture.settings.copilotSeatCreditEntitlementRaw = "3000"
            try fixture.seedAccounts()
            fixture.store.setCopilotSeatCreditEntitlement("")
        }
        defer { fixture.stop() }
        let app = NSApplication.shared
        guard app.delegate == nil else { return XCTFail("Use a standalone test host") }
        let previousApp = NSWorkspace.shared.frontmostApplication
        let policy = app.activationPolicy()
        let window = NSWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: 780,
                height: 560),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.title = "CodexBar — Synthetic Offline Copilot Allowance"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: CopilotAllowanceProofView(fixture: fixture))
        defer {
            window.close()
            _ = app.setActivationPolicy(policy)
            previousApp?.activate()
        }
        _ = app.setActivationPolicy(.regular)
        app.finishLaunching()
        window.center()
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        if zeroCreditsProof {
            let receipt = try await CopilotZeroAllowanceProof.run(fixture: fixture, clearAtEnd: false)
            XCTAssertTrue(receipt.values.allSatisfy(\.self))
            try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent("zero-credits.json"))
        }
        if env["CODEXBAR_COPILOT_DELAYED_SUCCESS"] == "1" {
            try await self.verifyDelayedSuccessfulRefresh(fixture: fixture, output: output)
        }
        if let mode = env["CODEXBAR_COPILOT_STACKED_OUTCOME"] {
            let receipt = try await CopilotStackedAllowanceProof.run(fixture: fixture, succeed: mode == "success")
            XCTAssertTrue(receipt.values.allSatisfy(\.self))
            try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent("stacked-outcome.json"))
            fixture.settings.multiAccountMenuLayout = .segmented
        }
        let deadline = Date().addingTimeInterval(900)
        var nextRefresh = Date.distantPast
        var refreshCount = 0
        while !FileManager.default.fileExists(atPath: output.appendingPathComponent("done").path), Date() < deadline {
            if Date() >= nextRefresh {
                await fixture.store.refreshProvider(
                    .copilot,
                    allowDisabled: true)
                refreshCount += 1
                nextRefresh = Date().addingTimeInterval(0.5)
                let row = fixture.row
                let receipt: [String: Any] = [
                    "pid": ProcessInfo.processInfo.processIdentifier, "window": window.windowNumber,
                    "account": fixture.settings.effectiveSelectedTokenAccount(for: .copilot)?.label ?? "none",
                    "used": row?.usageValue ?? -1, "allowance": row?.progress?.total ?? -1,
                    "updatedAt": fixture.store.snapshots[.copilot]?.updatedAt.timeIntervalSince1970 ?? -1,
                    "failedRefreshes": refreshCount, "error": fixture.store.errors[.copilot] ?? "none",
                ]
                try JSONSerialization.data(withJSONObject: receipt).write(
                    to: output.appendingPathComponent("state.json"),
                    options: .atomic)
            }
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
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.appendingPathComponent("done").path))
    }

    private func verifyDelayedSuccessfulRefresh(fixture: CopilotAllowanceFixture, output: URL) async throws {
        let old = try XCTUnwrap(fixture.store.snapshots[.copilot])
        let fetched = UsageSnapshot(
            primary: nil,
            secondary: nil,
            details: old.details,
            updatedAt: old.updatedAt.addingTimeInterval(60))
        let gate = CopilotAllowanceResponseGate()
        fixture.store._test_providerFetchOutcomeOverride = { _ in
            await gate.wait()
            return ProviderFetchOutcome(
                result: .success(ProviderFetchResult(
                    usage: fetched,
                    credits: nil,
                    dashboard: nil,
                    sourceLabel: "fixture",
                    strategyID: "fixture",
                    strategyKind: .web)), attempts: [])
        }
        let refresh = Task { await fixture.store.refreshProvider(.copilot, allowDisabled: true) }
        while !gate.started {
            await Task.yield()
        }
        let action = try XCTUnwrap(fixture.field?.actions.first { $0.id == "copilot-clear-default-allowance" })
        await action.perform()
        gate.resume()
        await refresh.value
        fixture.store._test_providerFetchOutcomeOverride = { _ in
            ProviderFetchOutcome(result: .failure(URLError(.notConnectedToInternet)), attempts: [])
        }
        await fixture.store.refreshProvider(.copilot, allowDisabled: true)
        let snapshots = [
            fixture.store.snapshots[.copilot],
            fixture.store.lastKnownResetSnapshots[.copilot],
            fixture.store.accountSnapshots[.copilot]?.first?.snapshot,
        ]
        for snapshot in snapshots {
            let snapshot = try XCTUnwrap(snapshot)
            let row = try XCTUnwrap(snapshot.details.flatMap(\.rows).first)
            XCTAssertNil(row.progress)
            XCTAssertEqual(row.usageValue, 123)
            XCTAssertEqual(snapshot.updatedAt, fetched.updatedAt)
        }
        try JSONSerialization.data(withJSONObject: [
            "delayedSuccessPublished": true, "clearedAllowanceStayedAbsent": true,
            "liveResetAndAccountCacheVerified": true, "subsequentFailurePreservedUsage": true,
        ], options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("delayed-success.json"))
    }
}

@MainActor
private struct CopilotAllowanceProofView: View {
    let fixture: CopilotAllowanceFixture

    var body: some View {
        HStack(
            alignment: .top,
            spacing: 20)
        {
            Form {
                Section("Synthetic account") {
                    Button("Account 1") { self.select(0) }
                    Button("Account 2") { self.select(1) }
                }
                if let field = self.fixture.field {
                    ProviderSettingsFieldRowView(field: field)
                }
            }.formStyle(.grouped).frame(width: 360)
            VStack(
                alignment: .leading,
                spacing: 15)
            {
                Text("Every refresh fails offline").font(.headline)
                Text("Production settings binding and menu card").font(.caption)
                UsageMenuCardView(
                    model: self.model,
                    width: 350)
            }
        }.padding(20)
    }

    private func select(_ index: Int) {
        self.fixture.settings.setActiveTokenAccountIndex(
            index,
            for: .copilot)
        self.fixture.reconcile()
    }

    private var model: UsageMenuCardView.Model {
        UsageMenuCardView.Model.make(.init(
            provider: .copilot,
            metadata: ProviderDefaults.metadata[.copilot]!,
            snapshot: self.fixture.store.snapshots[.copilot],
            credits: nil,
            creditsError: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(
                email: nil,
                plan: nil),
            isRefreshing: false,
            lastError: self.fixture.store.errors[.copilot],
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: true,
            now: Date()))
    }
}
