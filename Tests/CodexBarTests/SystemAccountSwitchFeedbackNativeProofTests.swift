import AppKit
import CodexBarCore
import SwiftUI
import Vision
import XCTest
@testable import CodexBar

/// Opt-in native rendering with fictional accounts. The alert case injects delivery failure; it does not claim
/// to exercise macOS notification authorization or delivery. No real credentials or provider transport is used.
@MainActor
final class SystemAccountSwitchFeedbackNativeProofTests: XCTestCase {
    func test_renderCodexFeedback() throws {
        let output = try self.outputDirectory()
        let fixture = try CodexWorkspacesNavigationFixture(userDefaults: InMemoryUserDefaults())
        defer { fixture.cleanup() }
        let controller = fixture.makeController()
        defer { controller.releaseStatusItemsForTesting() }
        let managedID = UUID()
        let account = CodexVisibleAccount(
            id: "fictional-account",
            email: "person@example.com",
            authFingerprint: "fixture-auth",
            storedAccountID: managedID,
            selectionSource: .managedAccount(id: managedID),
            isActive: false,
            isLive: false,
            canReauthenticate: true,
            canRemove: true)
        var evidence: [[String: String]] = []
        for dark in [false, true] {
            fixture.settings.hidePersonalInfo = false
            controller.systemAccountSwitchFeedback.begin(
                provider: .codex, accountID: account.id, label: account.email, cliName: "Codex")
            for phase in ["loading", "private-loading", "success", "failure"] {
                switch phase {
                case "private-loading": fixture.settings.hidePersonalInfo = true
                case "success": controller.systemAccountSwitchFeedback.finish(provider: .codex, outcome: .succeeded)
                case "failure":
                    controller.systemAccountSwitchFeedback.begin(
                        provider: .codex, accountID: account.id, label: account.email, cliName: "Codex")
                    controller.systemAccountSwitchFeedback.finish(
                        provider: .codex,
                        outcome: .failed(title: "Could not switch system account", message: "Synthetic switch failure"))
                default: break
                }
                let model = try XCTUnwrap(controller.codexAccountMenuCardModel(for: account, accountSnapshot: nil))
                let view = UsageMenuCardView(model: model, width: 360)
                    .environment(\.menuCardRefreshMonitor, controller.menuCardRefreshMonitor)
                    .environment(\.locale, Locale(identifier: "en_US_POSIX"))
                    .environment(\.colorScheme, dark ? .dark : .light)
                    .background(Color(nsColor: dark ? .darkGray : .white))
                let hosting = NSHostingView(rootView: view)
                hosting.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                let png = try XCTUnwrap(MenuLayoutScreenshotRenderTests.pngDataWithWindow(hosting: hosting))
                let name = "codex-\(phase)-\(dark ? "dark" : "light").png"
                try png.write(to: output.appendingPathComponent(name))
                let text = try self.visibleText(in: png)
                let expected = switch phase {
                case "success": "is now the System account"
                case "failure": "Synthetic switch failure"
                default: "Switching Codex to"
                }
                XCTAssertTrue(text.contains(expected), text)
                if fixture.settings.hidePersonalInfo {
                    XCTAssertFalse(text.contains("person@example.com"), text)
                }
                evidence.append(["image": name, "visibleText": text, "subtitle": model.subtitleText])
            }
        }
        try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("codex-feedback.json"))
    }

    func test_renderAlertAfterSimulatedDeliveryFailure() async throws {
        let output = try self.outputDirectory()
        let fixture = try CodexWorkspacesNavigationFixture(userDefaults: InMemoryUserDefaults())
        defer { fixture.cleanup() }
        let executable = fixture.files.root.appendingPathComponent("cswap")
        try """
        #!/bin/sh
        echo '{"schemaVersion":1,"error":{"type":"SwitchError","message":"Synthetic switch failure"}}'
        exit 1

        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try fixture.settings.setProviderEnabled(
            provider: .claude, metadata: XCTUnwrap(ProviderRegistry.shared.metadata[.claude]), enabled: true)
        fixture.settings.claudeSwapEnabled = true
        fixture.settings.claudeSwapExecutablePath = executable.path
        fixture.settings.hidePersonalInfo = true
        fixture.store.claudeSwapAccountSnapshots = ["1", "2"].map { slot in
            ProviderAccountUsageSnapshot(
                id: .init(source: ClaudeSwapAccountProjection.sourceName, opaqueID: slot),
                provider: .claude,
                displayLabel: "person.\(slot)@example.com",
                isActive: slot == "1",
                canActivate: slot == "2",
                snapshot: nil,
                error: nil,
                sourceLabel: ClaudeSwapAccountProjection.sourceLabel)
        }
        fixture.store._test_providerRefreshOverride = { _ in }
        let controller = fixture.makeController()
        defer { controller.releaseStatusItemsForTesting() }
        controller._test_systemAccountNoticeDelivery = { _ in false }
        let captureURL = output.appendingPathComponent("alert-after-simulated-delivery-failure.png")
        var captureStatus: Int32?
        var alertFirstSeen: Date?
        let timer = Timer(timeInterval: 0.2, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard let window = NSApplication.shared.modalWindow else { return }
                guard let firstSeen = alertFirstSeen else {
                    alertFirstSeen = Date()
                    return
                }
                // Wait for the native presentation animation before capturing the compositor's window image.
                guard Date().timeIntervalSince(firstSeen) >= 1 else { return }
                defer { NSApplication.shared.stopModal() }
                window.layoutIfNeeded()
                let capture = Process()
                capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                capture.arguments = ["-x", "-o", "-l", String(window.windowNumber), captureURL.path]
                do {
                    try capture.run()
                    capture.waitUntilExit()
                    captureStatus = capture.terminationStatus
                } catch {
                    XCTFail("Could not capture the native alert: \(error)")
                }
            }
        }
        RunLoop.main.add(timer, forMode: .modalPanel)
        defer { timer.invalidate() }

        let task = try XCTUnwrap(controller.startSystemAccountSwitch(provider: .claude, accountID: "2"))
        await task.value

        XCTAssertEqual(captureStatus, 0, "The production fallback must present a capturable native alert")
        let png = try Data(contentsOf: captureURL)
        let text = try self.visibleText(in: png)
        XCTAssertTrue(text.contains("Could not switch system account"), text)
        XCTAssertTrue(text.contains("Synthetic switch failure"), text)
    }

    private func outputDirectory() throws -> URL {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["CODEXBAR_SYSTEM_SWITCH_PROOF_DIR"] else {
            throw XCTSkip("Set CODEXBAR_SYSTEM_SWITCH_PROOF_DIR for isolated native feedback proof")
        }
        guard env["CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS"] == "1",
              env[CodexCredentialFileAccess.isolationEnvironmentKey] == "1",
              env["CODEXBAR_TEST_SESSION_FILE_ISOLATION"] == "1",
              !path.hasPrefix(NSHomeDirectory() + "/")
        else { throw XCTSkip("Native proof requires credential isolation and output outside the home directory") }
        let output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        return output
    }

    private func visibleText(in png: Data) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(data: png).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
    }
}
