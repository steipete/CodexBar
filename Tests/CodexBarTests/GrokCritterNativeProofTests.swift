import AppKit
import XCTest
@testable import CodexBar
@testable import CodexBarCore

@MainActor
final class GrokCritterNativeProofTests: XCTestCase {
    func test_interactiveGrokLayouts() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["CODEXBAR_GROK_CRITTER_PROOF_DIR"] else {
            throw XCTSkip("Set CODEXBAR_GROK_CRITTER_PROOF_DIR for signed synthetic proof")
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
        let app = NSApplication.shared
        guard app.delegate == nil else { return XCTFail("Use a standalone test host") }
        let previousApp = NSWorkspace.shared.frontmostApplication
        let policy = app.activationPolicy()
        let host = GrokCritterProofHost(output: output)
        defer {
            host.close()
            _ = app.setActivationPolicy(policy)
            previousApp?.activate()
        }
        _ = app.setActivationPolicy(.regular)
        app.finishLaunching()
        host.show()
        let deadline = Date().addingTimeInterval(900)
        while !FileManager.default.fileExists(atPath: output.appendingPathComponent("done").path), Date() < deadline {
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
}

@MainActor
private final class GrokCritterProofHost: NSObject {
    let output: URL
    let window: NSWindow
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let hide = NSButton(
        checkboxWithTitle: "Hide Critters",
        target: nil,
        action: nil)
    let dark = NSButton(
        checkboxWithTitle: "Dark appearance",
        target: nil,
        action: nil)
    let stale = NSButton(
        checkboxWithTitle: "Stale usage",
        target: nil,
        action: nil)
    let examples = NSStackView()

    init(output: URL) {
        self.output = output
        self.window = NSWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: 740,
                height: 440),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        super.init()
        self.window.title = "CodexBar — Synthetic Grok Critter Proof"
        self.window.isReleasedWhenClosed = false
        self.examples.orientation = .horizontal
        self.examples.spacing = 35
        let toggles = NSStackView(views: [self.hide, self.dark, self.stale])
        toggles.spacing = 24
        for button in [self.hide, self.dark, self.stale] {
            button.target = self
            button.action = #selector(self.changed)
        }
        let stack = NSStackView(views: [
            NSTextField(labelWithString: "Production renderer • native 18 pt and enlarged samples"),
            toggles, self.examples,
        ])
        stack.orientation = .vertical
        stack.spacing = 24
        stack.edgeInsets = NSEdgeInsets(
            top: 25,
            left: 25,
            bottom: 25,
            right: 25)
        self.window.contentView = stack
        self.item.autosaveName = "codexbar-synthetic-grok-b7"
    }

    func show() {
        self.window.center()
        self.window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        self.changed()
    }

    func close() {
        NSStatusBar.system.removeStatusItem(self.item)
        self.window.close()
    }

    @objc private func changed() {
        let appearance = NSAppearance(named: self.dark.state == .on ? .darkAqua : .aqua)
        self.window.appearance = appearance
        self.item.button?.appearance = appearance
        for view in self.examples.arrangedSubviews {
            self.examples.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for (index, values) in [(60.0 as Double?, nil as Double?), (nil, 60.0), (60.0, 40.0)].enumerated() {
            let image = IconRenderer.makeIcon(
                primaryRemaining: values.0,
                weeklyRemaining: values.1,
                creditsRemaining: nil,
                stale: self.stale.state == .on,
                style: .grok,
                hideCritters: self.hide.state == .on)
            if index == 0 {
                self.item.button?.image = image
            }
            let native = NSImageView(image: image)
            native.widthAnchor.constraint(equalToConstant: 18).isActive = true
            native.heightAnchor.constraint(equalToConstant: 18).isActive = true
            let enlarged = NSImageView(image: image)
            enlarged.imageScaling = .scaleProportionallyUpOrDown
            enlarged.widthAnchor.constraint(equalToConstant: 180).isActive = true
            enlarged.heightAnchor.constraint(equalToConstant: 180).isActive = true
            let column = NSStackView(views: [
                NSTextField(labelWithString: ["Primary only", "Secondary only", "Two meters"][index]), native, enlarged,
            ])
            column.orientation = .vertical
            column.spacing = 15
            self.examples.addArrangedSubview(column)
        }
        let record: [String: Any] = [
            "pid": ProcessInfo.processInfo.processIdentifier, "window": self.window.windowNumber,
            "hideCritters": self.hide.state == .on, "dark": self.dark.state == .on, "stale": self.stale.state == .on,
        ]
        do {
            try JSONSerialization.data(withJSONObject: record).write(
                to: self.output.appendingPathComponent("state.json"),
                options: .atomic)
        } catch {
            XCTFail("Could not write synthetic proof receipt")
        }
    }
}
