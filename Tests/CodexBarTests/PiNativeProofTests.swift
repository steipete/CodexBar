import AppKit
import SwiftUI
import WidgetKit
import XCTest
@testable import CodexBar
@testable import CodexBarCore
@testable import CodexBarWidget

@MainActor
final class PiNativeProofTests: XCTestCase {
    func test_interactiveLocalHistory() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["CODEXBAR_PI_NATIVE_PROOF_DIR"] else {
            throw XCTSkip("Set CODEXBAR_PI_NATIVE_PROOF_DIR for signed synthetic Pi proof")
        }
        let output = URL(fileURLWithPath: path, isDirectory: true).resolvingSymlinksInPath()
        let parent = output.deletingLastPathComponent()
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).resolvingSymlinksInPath()
        guard SettingsStore.isRunningTests,
              environment["CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS"] == "1",
              environment[CodexCredentialFileAccess.isolationEnvironmentKey] == "1",
              environment["CODEXBAR_TEST_SESSION_FILE_ISOLATION"] == "1",
              environment["CODEXBAR_ALLOW_TEST_KEYCHAIN_ACCESS"] != "1",
              environment["CODEXBAR_TEST_CODEX_FILE_FIXTURES"] == nil,
              parent.pathComponents.count >= 3,
              home.path.hasPrefix(parent.path + "/")
        else { return XCTFail("Use a contained home and credential/session isolation") }
        let application = NSApplication.shared
        guard application.delegate == nil else { return XCTFail("Use a standalone native test host") }
        let oldRendering = StatusItemController.menuCardRenderingEnabled
        let oldRefresh = StatusItemController.menuRefreshEnabled
        StatusItemController.menuCardRenderingEnabled = true
        StatusItemController.setMenuRefreshEnabledForTesting(true)
        defer {
            StatusItemController.menuCardRenderingEnabled = oldRendering
            StatusItemController.setMenuRefreshEnabledForTesting(oldRefresh)
        }
        let session = try PiNativeProofSession(output: output)
        let oldPolicy = application.activationPolicy()
        let previousApplication = NSWorkspace.shared.frontmostApplication
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 810),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "CodexBar — Synthetic Pi Live Proof"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 1100, height: 650)
        window.contentView = NSHostingView(rootView: PiNativeProofView(session: session))
        session.window = window
        let timer = Timer(timeInterval: 0.25, repeats: true) { _ in
            MainActor.assumeIsolated { session.record() }
        }
        defer {
            timer.invalidate()
            session.stop()
            window.close()
            _ = application.setActivationPolicy(oldPolicy)
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
                previousApplication?.activate()
            }
        }
        _ = application.setActivationPolicy(.regular)
        application.finishLaunching()
        window.center()
        window.makeKeyAndOrderFront(nil)
        application.activate(ignoringOtherApps: true)
        RunLoop.main.add(timer, forMode: .common)
        session.run("startup")
        let deadline = Date().addingTimeInterval(1200)
        while !session.finished, Date() < deadline {
            if let event = application.nextEvent(
                matching: .any, until: Date().addingTimeInterval(0.02), inMode: .default, dequeue: true)
            {
                application.sendEvent(event)
            }
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        XCTAssertTrue(session.finished, "Click Finish before the native proof deadline")
        XCTAssertNil(session.failure)
    }
}

@MainActor
private struct PiNativeProofView: View {
    @Bindable var session: PiNativeProofSession

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Refresh") { self.session.run("refresh") }
                Button("Toggle Pi") { self.session.run("toggle") }
                Button("Pi menu") { self.session.showMenu(provider: .pi) }.disabled(!self.session.piEnabled)
                Button("Overview") { self.session.showMenu(provider: nil) }
                Button("Root offline") { self.session.run("offline") }
                    .disabled(!self.session.piEnabled || self.session.corpus.isOffline)
                Button("Restore + append 10,000") { self.session.run("restore-append") }
                    .disabled(!self.session.piEnabled)
                Spacer()
                Button("Finish") { self.session.finish() }
            }
            .disabled(self.session.busy)
            .padding(12)
            HStack {
                if self.session.busy {
                    ProgressView().controlSize(.small)
                }
                Text(self.session.statusText).font(.callout)
                Spacer()
                Text("Synthetic local files · no provider connections").foregroundStyle(.secondary)
            }.padding(.horizontal, 16).padding(.bottom, 8)
            Divider()
            HStack(alignment: .top, spacing: 0) {
                SpendDashboardPane(settings: self.session.settings, store: self.session.store)
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    Text("Pi widget view").font(.headline)
                    Text("AppKit host; persisted production snapshot.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let snapshot = session.widgetSnapshot,
                       let entry = snapshot.entries.first(where: { $0.provider == UsageProvider.pi.instanceID })
                    {
                        UsageTile(entry: entry, size: .small) {
                            TileHeader(provider: entry.provider, updatedAt: entry.updatedAt, size: .small)
                        }
                        .environment(\.widgetUsageShowsUsed, snapshot.usageBarsShowUsed)
                        .frame(width: 190, height: 190)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
                    }
                    Text("Initial: 240,000 tokens · $0.72\nAfter append: 250,000 tokens · $0.75")
                        .font(.caption).monospacedDigit()
                    Text("Toggle Pi changes ownership. Refresh and relaunch reuse the same corpus and cache.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }.padding(18).frame(width: 245)
            }
        }
    }
}
