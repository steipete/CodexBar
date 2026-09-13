import AppKit
import XCTest
@testable import CodexBar
@testable import CodexBarCore

/// Signed synthetic proof that claude-swap account segments select details without activating.
///
/// Renders the production `ClaudeSwapAccountSwitcherView` with fictional accounts and captures it,
/// so the reviewed behavior is observable without any real account, credential, or `cswap` run.
/// Follows `CodexSwitcherPrivacyNativeProofTests`.
@MainActor
final class ClaudeSwapViewOnlyNativeProofTests: XCTestCase {
    private struct ProofSetupError: Error, CustomStringConvertible {
        let description: String
    }

    private func proofOutputDirectory() throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["CODEXBAR_CLAUDE_SWAP_VIEW_PROOF_DIR"] else {
            throw XCTSkip("Set CODEXBAR_CLAUDE_SWAP_VIEW_PROOF_DIR for signed synthetic UI proof")
        }
        let output = URL(fileURLWithPath: path, isDirectory: true)
        // Same credential/session isolation requirements as CodexSwitcherPrivacyNativeProofTests.
        //
        // That test additionally requires NSHomeDirectory() to sit inside the output's parent.
        // NSHomeDirectory() reads the passwd database rather than $HOME, so that check only holds
        // under a sandbox or container that rewrites the user record; it is deliberately NOT
        // claimed here. Instead the output must live outside the real home, so a run cannot write
        // artifacts into user space. No case needs credentials: accounts are synthetic, and the only
        // executable ever run is a stub script written into the output directory.
        guard environment["CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS"] == "1",
              environment[CodexCredentialFileAccess.isolationEnvironmentKey] == "1",
              environment["CODEXBAR_TEST_SESSION_FILE_ISOLATION"] == "1",
              environment["CODEXBAR_ALLOW_TEST_KEYCHAIN_ACCESS"] != "1",
              !output.path.hasPrefix(NSHomeDirectory() + "/")
        else {
            throw ProofSetupError(
                description: "Use credential/session isolation and an output path outside the home directory")
        }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        return output
    }

    func test_viewOnlyAccountSelection() throws {
        let output = try self.proofOutputDirectory()
        let app = NSApplication.shared
        guard app.delegate == nil else { return XCTFail("Use a standalone test host") }
        let previousApp = NSWorkspace.shared.frontmostApplication
        let previousPolicy = app.activationPolicy()
        let host = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 340),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        host.title = "CodexBar — Synthetic claude-swap View-Only Selection"
        host.isReleasedWhenClosed = false
        defer {
            host.close()
            _ = app.setActivationPolicy(previousPolicy)
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
                previousApp?.activate()
            }
        }
        _ = app.setActivationPolicy(.regular)
        app.finishLaunching()
        host.center()
        host.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)

        // Activation is measured against the production owner in test_menuSegmentClicksNeverActivate.
        var receipt: [String: Any] = ["syntheticOnly": true]
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            host.appearance = NSAppearance(named: appearance)
            let content = NSView(frame: NSRect(x: 0, y: 0, width: 720, height: 340))
            host.contentView = content
            Self.addLabel(
                "Production claude-swap switcher · synthetic accounts · ● marks the active account",
                y: 296,
                to: content)

            var rows: [[String: Any]] = []
            // Slot 2 is the account claude-swap reports active; each row views a different slot,
            // so the capture shows the viewed highlight moving while ● stays put.
            for (index, viewed) in ["2", "7", "9"].enumerated() {
                let y = CGFloat(230 - index * 96)
                let note = switch viewed {
                case "2": "Viewing the active account"
                case "7": "Viewing a healthy inactive account — no activation"
                default: "Viewing an unavailable account — inspectable, not activatable"
                }
                Self.addLabel("\(note) · hidePersonalInfo on", y: y + 30, to: content)
                rows.append(self.addSwitcher(viewedSlot: viewed, y: y, to: content))
            }
            content.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))

            let capture = Process()
            capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = [
                "-x", "-o", "-l", String(host.windowNumber),
                output.appendingPathComponent("claude-swap-view-only-\(appearance.rawValue).png").path,
            ]
            try capture.run()
            capture.waitUntilExit()
            XCTAssertEqual(capture.terminationStatus, 0)
            receipt[appearance.rawValue] = rows
        }
        try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys, .prettyPrinted])
            .write(to: output.appendingPathComponent("state.json"), options: .atomic)
    }

    /// Drives the production menu: each click goes through the real switcher view's button action and
    /// `onSelect` wiring into `handleClaudeSwapAccountSelection`. Activation is measured, not assumed:
    /// on the store's switch owner after every click, and on a logging stub standing in for cswap.
    func test_menuSegmentClicksNeverActivate() throws {
        let output = try self.proofOutputDirectory()
        let stub = try Self.writeStub(
            named: "menu-owner",
            listJSON: Self.listJSON(slots: [2, 7, 9], active: 2),
            in: output)
        let (controller, store) = self.makeController(executablePath: stub.executable.path)
        defer { controller.releaseStatusItemsForTesting() }
        let menu = controller.makeMenu(for: .claude)
        controller.menuWillOpen(menu)

        var clicks: [[String: Any]] = []
        for slot in ["7", "9", "2"] {
            let switcher = try XCTUnwrap(menu.items.lazy.compactMap { $0.view as? ClaudeSwapAccountSwitcherView }.first)
            let button = try XCTUnwrap(switcher._test_buttons().first { $0.title.hasSuffix(slot) })
            button.performClick(nil)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
            controller.populateMenu(menu, provider: .claude)

            let viewed = try XCTUnwrap(store.claudeSwapAccountSnapshots.first {
                $0.id == controller.claudeSwapViewedAccountID
            })
            XCTAssertEqual(viewed.id.opaqueID, slot)
            clicks.append([
                "clickedSlot": slot,
                "viewedSlot": viewed.id.opaqueID,
                "activeSlot": store.claudeSwapAccountSnapshots.first(where: \.isActive)?.id.opaqueID ?? NSNull(),
                "switchTaskRunning": store.claudeSwapTransientState.task != nil,
                "switchingSlot": store.claudeSwapTransientState.switchingAccountID?.opaqueID ?? NSNull(),
                "cardActionLabel": controller.claudeSwapAccountActionLabel(viewed) ?? NSNull(),
                "cardSwitchActionAvailable": controller.claudeSwapAccountSwitchAction(viewed, menu: menu) != nil,
            ])
        }
        // Give any activation a segment click might have scheduled time to reach the subprocess.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 1))
        let invocations = Self.invocations(of: stub)
        let switchInvocations = invocations.filter { $0.contains("--switch-to") }
        let activationsStarted = clicks.count(where: {
            $0["switchTaskRunning"] as? Bool == true || !($0["switchingSlot"] is NSNull)
        }) + switchInvocations.count

        XCTAssertEqual(activationsStarted, 0)
        XCTAssertTrue(clicks.allSatisfy { $0["activeSlot"] as? String == "2" })
        // The explicit card action is still offered exactly where activation is possible.
        XCTAssertEqual(clicks.map { $0["cardSwitchActionAvailable"] as? Bool }, [true, false, false])
        XCTAssertEqual(clicks.map { $0["cardActionLabel"] as? String }, ["Switch Account...", nil, "Active"])

        let receipt: [String: Any] = [
            "syntheticOnly": true,
            "path": "production menu → ClaudeSwapAccountSwitcherView button → handleClaudeSwapAccountSelection",
            "clicks": clicks,
            "stubInvocations": invocations,
            "activationsStarted": activationsStarted,
            "cardActionInvoked": false,
        ]
        try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys, .prettyPrinted])
            .write(to: output.appendingPathComponent("menu-owner.json"), options: .atomic)
    }

    /// Executable discovery through the production config loader, shared resolver and account reader,
    /// against synthetic stubs. Only the default install location is injected, since the real one is the
    /// user's ~/.local/bin/cswap; explicit paths are also checked against
    /// `ProviderConfig.resolvedClaudeSwapExecutablePath`, the property both the app and the CLI read.
    func test_executableDiscovery() async throws {
        let output = try self.proofOutputDirectory()
        let installed = try Self.writeStub(
            named: "default-install", listJSON: Self.listJSON(slots: [2, 7, 9], active: 2), in: output)
        let explicit = try Self.writeStub(
            named: "explicit", listJSON: Self.listJSON(slots: [4], active: 4), in: output)
        let missing = output.appendingPathComponent("stubs/missing/cswap").path
        let enabled = #""id":"claude","claudeSwapEnabled":true"#

        let scenarios: [(name: String, claude: String, defaultPath: String, expected: String)] = [
            ("fresh config, cswap installed at the default", enabled, installed.executable.path, "listed 3"),
            ("fresh config, nothing at the default", enabled, missing, "idle"),
            (
                "upgraded config that saved an empty path, cswap installed at the default",
                enabled + #","claudeSwapExecutablePath":"""#,
                installed.executable.path,
                "listed 3"),
            (
                "explicit path, default also installed",
                enabled + #","claudeSwapExecutablePath":"\#(explicit.executable.path)""#,
                installed.executable.path,
                "listed 1"),
            (
                "explicit path that does not exist, default installed",
                enabled + #","claudeSwapExecutablePath":"\#(missing)""#,
                installed.executable.path,
                "error"),
        ]

        let configs = output.appendingPathComponent("configs", isDirectory: true)
        try FileManager.default.createDirectory(at: configs, withIntermediateDirectories: true)
        var rows: [[String: Any]] = []
        for (index, scenario) in scenarios.enumerated() {
            let file = configs.appendingPathComponent("scenario-\(index + 1).json")
            try #"{"version":1,"providers":[{\#(scenario.claude)}]}"#.write(to: file, atomically: true, encoding: .utf8)
            let provider = try XCTUnwrap(CodexBarConfigStore(fileURL: file).load()?.providerConfig(for: .claude))
            let configured = provider.sanitizedClaudeSwapExecutablePath
            let resolved = ClaudeSwapExecutableResolver.resolve(
                configured: configured, defaultPath: scenario.defaultPath)
            if configured != nil {
                XCTAssertEqual(resolved, provider.resolvedClaudeSwapExecutablePath)
            }

            let result: String
            if resolved.isEmpty {
                result = "idle: no executable resolved, nothing run"
            } else {
                do {
                    let list = try await ClaudeSwapAccountReader.readAccountList(executablePath: resolved)
                    result = "listed \(list.accounts.count) account(s), active slot "
                        + (list.activeAccountNumber.map(String.init) ?? "none")
                } catch {
                    result = "error: " + Self.redact(error.localizedDescription, output: output)
                }
            }
            XCTAssertTrue(result.hasPrefix(scenario.expected), "\(scenario.name): \(result)")
            try rows.append([
                "scenario": scenario.name,
                "config": Self.redact(String(contentsOf: file, encoding: .utf8), output: output),
                "defaultPath": Self.redact(scenario.defaultPath, output: output),
                "resolvedPath": resolved.isEmpty ? NSNull() : Self.redact(resolved, output: output),
                "result": result,
            ])
        }

        // The default stub ran only for the two scenarios that resolved to it; an explicit path,
        // even a missing one, never fell back to it.
        XCTAssertEqual(Self.invocations(of: installed).count, 2)
        XCTAssertEqual(Self.invocations(of: explicit).count, 1)

        let receipt: [String: Any] = [
            "syntheticOnly": true,
            "scenarios": rows,
            "stubInvocations": [
                "default-install": Self.invocations(of: installed),
                "explicit": Self.invocations(of: explicit),
            ],
            "thisMachine": [
                "productionDefaultPath": ClaudeSwapExecutableResolver.defaultExecutablePathPlaceholder,
                "installed": FileManager.default.isExecutableFile(
                    atPath: ClaudeSwapExecutableResolver.defaultExecutablePath),
            ],
        ]
        try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys, .prettyPrinted])
            .write(to: output.appendingPathComponent("discovery.json"), options: .atomic)
    }

    private func makeController(executablePath: String) -> (controller: StatusItemController, store: UsageStore) {
        StatusItemController.menuCardRenderingEnabled = false
        StatusItemController.setMenuRefreshEnabledForTesting(false)
        let settings = testSettingsStore(
            suiteName: "ClaudeSwapViewOnlyNativeProofTests",
            tokenAccountStore: InMemoryTokenAccountStore())
        settings.providerDetectionCompleted = true
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false
        settings.multiAccountMenuLayout = .segmented
        settings.hidePersonalInfo = true
        let registry = ProviderRegistry.shared
        for provider in UsageProvider.allCases {
            guard let metadata = registry.metadata[provider] else { continue }
            settings.setProviderEnabled(provider: provider, metadata: metadata, enabled: provider == .claude)
        }
        settings.claudeSwapEnabled = true
        settings.claudeSwapExecutablePath = executablePath

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        store.claudeSwapAccountSnapshots = Self.accounts()
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: testStatusBar())
        return (controller, store)
    }

    private struct Stub {
        let executable: URL
        let log: URL
    }

    /// A synthetic claude-swap stand-in: logs its arguments and prints a fixed schema-v1 list.
    /// It holds no credentials and cannot switch anything.
    private static func writeStub(named name: String, listJSON: String, in output: URL) throws -> Stub {
        let directory = output.appendingPathComponent("stubs/\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("cswap")
        let log = directory.appendingPathComponent("invocations.log")
        try? FileManager.default.removeItem(at: log)
        let script = """
        #!/bin/sh
        echo "$*" >> '\(log.path)'
        if [ "$1" = "--list" ]; then
        cat <<'JSON'
        \(listJSON)
        JSON
        exit 0
        fi
        exit 64
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return Stub(executable: executable, log: log)
    }

    private static func invocations(of stub: Stub) -> [String] {
        ((try? String(contentsOf: stub.log, encoding: .utf8)) ?? "")
            .split(separator: "\n")
            .map(String.init)
    }

    private static func listJSON(slots: [Int], active: Int) -> String {
        let rows = slots.map { slot in
            #"{"number":\#(slot),"email":"synthetic.\#(slot)@example.com","active":\#(slot == active),"#
                + #""usageStatus":"ok","usage":{"fiveHour":{"pct":10},"sevenDay":{"pct":20}}}"#
        }
        return #"{"schemaVersion":1,"activeAccountNumber":\#(active),"accounts":[\#(rows.joined(separator: ","))]}"#
    }

    private static func redact(_ text: String, output: URL) -> String {
        text.replacingOccurrences(of: output.path, with: "$PROOF_DIR")
            .replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    private func addSwitcher(viewedSlot: String, y: CGFloat, to content: NSView) -> [String: Any] {
        let accounts = Self.accounts()
        let display = ClaudeSwapAccountMenuDisplay(
            accounts: accounts,
            layout: .segmented,
            switchingAccountID: nil,
            errorAccountID: nil,
            viewedAccountID: ProviderAccountIdentity(source: "claude-swap", opaqueID: viewedSlot))
        var selected: [String] = []
        let view = ClaudeSwapAccountSwitcherView(
            display: display,
            hidePersonalInfo: true,
            width: 320,
            onSelect: { selected.append($0.opaqueID) })
        view.setFrameOrigin(NSPoint(x: 28, y: y))
        content.addSubview(view)
        view.layoutSubtreeIfNeeded()

        let titles = view._test_titles
        let tips = view._test_toolTips
        XCTAssertEqual(titles.count, accounts.count)
        XCTAssertEqual(tips.count, accounts.count)

        // Privacy: slot ordinals only, never the display email.
        XCTAssertFalse((titles + tips).contains { $0.contains("@") })
        XCTAssertTrue(titles.allSatisfy { !$0.isEmpty })

        // The ● marker tracks claude-swap's active slot, independent of what is being viewed.
        let marker = ClaudeSwapAccountSwitcherView.activeMarker
        XCTAssertEqual(titles.count(where: { $0.hasPrefix(marker) }), 1)
        XCTAssertTrue(titles.first { $0.hasPrefix(marker) }?.contains("2") == true)

        // The filled highlight tracks the viewed slot, which may differ from the active one.
        XCTAssertEqual(view._test_selectedTitles.count, 1)
        XCTAssertTrue(view._test_selectedTitles[0].contains(viewedSlot))

        // Record the highlight before exercising clicks: `performClick` toggles each button's
        // state, so reading it afterwards would contradict the captured image.
        let highlighted = view._test_selectedTitles

        // Exercise clicks on a separate instance so the captured window keeps its real state.
        // Every segment reports a selection and starts no activation: the view has no path to
        // `switchClaudeSwapAccount`, and `onSelect` is the only thing it can call.
        var clicked: [String] = []
        let clickProbe = ClaudeSwapAccountSwitcherView(
            display: display,
            hidePersonalInfo: true,
            width: 320,
            onSelect: { clicked.append($0.opaqueID) })
        clickProbe.layoutSubtreeIfNeeded()
        for button in clickProbe._test_buttons() {
            button.performClick(nil)
        }
        XCTAssertEqual(clicked, accounts.map(\.id.opaqueID))
        XCTAssertTrue(selected.isEmpty, "The captured view must not be mutated by the click probe")

        return [
            "viewedSlot": viewedSlot,
            "titles": titles,
            "toolTips": tips,
            "highlighted": highlighted,
            "clickedSlots": clicked,
        ]
    }

    /// Slot 2 active, slot 7 healthy inactive, slot 9 unavailable (expired credentials).
    private static func accounts() -> [ProviderAccountUsageSnapshot] {
        [("2", true, true), ("7", false, true), ("9", false, false)].map { slot, isActive, canActivate in
            ProviderAccountUsageSnapshot(
                id: ProviderAccountIdentity(source: "claude-swap", opaqueID: slot),
                provider: .claude,
                displayLabel: "synthetic.\(slot)@example.com",
                isActive: isActive,
                canActivate: !isActive && canActivate,
                snapshot: nil,
                error: nil,
                sourceLabel: "claude-swap")
        }
    }

    private static func addLabel(_ text: String, y: CGFloat, to content: NSView) {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 14)
        label.frame = NSRect(x: 28, y: y, width: 660, height: 28)
        content.addSubview(label)
    }
}
