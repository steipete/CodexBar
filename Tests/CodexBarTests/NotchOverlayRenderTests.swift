import AppKit
import CodexBarCore
import KeyboardShortcuts
import SwiftUI
import XCTest
@testable import CodexBar

@MainActor
final class NotchOverlayRenderTests: XCTestCase {
    func test_renderSyntheticOverlay() throws {
        guard let directory = ProcessInfo.processInfo.environment["CODEXBAR_NOTCH_RENDER_DIR"] else {
            throw XCTSkip("Set CODEXBAR_NOTCH_RENDER_DIR to render synthetic notch proof.")
        }
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let settings = testSettingsStore(
            suiteName: "NotchOverlayRenderTests",
            userDefaults: InMemoryUserDefaults(),
            config: CodexBarConfig(providers: [
                ProviderConfig(id: .claude, enabled: true),
                ProviderConfig(id: .gemini, enabled: true),
            ]))
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        let now = Date()
        for provider in [UsageProvider.claude, .gemini] {
            store._setSnapshotForTesting(UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 20,
                    windowMinutes: 300,
                    resetsAt: now.addingTimeInterval(3600),
                    resetDescription: nil),
                secondary: RateWindow(
                    usedPercent: 40,
                    windowMinutes: 10080,
                    resetsAt: now.addingTimeInterval(86400),
                    resetDescription: nil),
                updatedAt: now), provider: provider)
        }
        settings.notchColumnCount = 2
        settings.setUsageItemVisible(false, itemID: .metric("primary"), for: .claude)
        let state = NotchUsageOverlayViewState()
        state.isExpanded = true
        for (name, appearance, brand) in [
            ("dark-brand", NSAppearance.Name.darkAqua, true),
            ("light-mono", NSAppearance.Name.aqua, false),
        ] {
            settings.menuBarShowsBrandIconWithPercent = brand
            let model = NotchUsageOverlayModel.make(store: store, settings: settings, now: now)
            let content = NotchUsageOverlayContent(model: model)
            let view = AnyView(VStack(alignment: .leading, spacing: 16) {
                Text("Notch usage · synthetic data").font(.caption).foregroundStyle(.secondary)
                content.grid
            }
            .padding(20)
            .frame(width: 700)
            .background(Color(nsColor: .windowBackgroundColor)))
            try Self.render(view, appearance: appearance, to: output.appendingPathComponent("\(name).png"))
        }
        let overlay = AnyView(NotchUsageOverlayView(
            store: store, settings: settings, agentSessions: nil, viewState: state)
            .frame(width: 700, height: 220)
            .background(Color(nsColor: .windowBackgroundColor)))
        try Self.render(overlay, appearance: .darkAqua, to: output.appendingPathComponent("overlay.png"))
        settings.agentSessionsEnabled = true
        settings.notchShowsAgentSessions = true
        settings.notchSessionsMaxHeight = 1600
        let sessions = AgentSessionsStore(settings: settings)
        sessions.applyLocalScanResult((1...80).map { index in
            AgentSession(
                id: "fixture-\(index)",
                provider: .codex,
                source: .cli,
                state: .active,
                pid: Int32(index),
                cwd: "/tmp/notch-fixture",
                projectName: "Synthetic session \(index)",
                startedAt: now,
                lastActivityAt: now,
                transcriptPath: nil,
                host: "local")
        })
        let tall = AnyView(NotchUsageOverlayView(
            store: store, settings: settings, agentSessions: sessions, viewState: state)
            .frame(width: 700, height: 400)
            .background(Color(nsColor: .windowBackgroundColor)))
        try Self.render(tall, appearance: .darkAqua, to: output.appendingPathComponent("tall-sessions.png"))
        let pane = AnyView(NotchPane(settings: settings, store: store)
            .frame(width: 650, height: 920))
        try Self.render(pane, appearance: .darkAqua, to: output.appendingPathComponent("settings.png"))
    }

    func test_notchRecorderLocalizesAndDisables() throws {
        try CodexBarLocalizationOverride.$appLanguage.withValue("en") {
            let hosting = NSHostingView(rootView: SettingsShortcutRecorder(
                shortcutName: .showNotchOverlay,
                isEnabled: false))
            hosting.frame = CGRect(x: 0, y: 0, width: 200, height: 40)
            let window = NSWindow(
                contentRect: hosting.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false)
            window.contentView = hosting
            defer { window.contentView = nil }
            hosting.layoutSubtreeIfNeeded()
            @MainActor func recorder(in view: NSView) -> KeyboardShortcuts.RecorderCocoa? {
                if let recorder = view as? KeyboardShortcuts.RecorderCocoa { return recorder }
                return view.subviews.lazy.compactMap { recorder(in: $0) }.first
            }
            let control = try XCTUnwrap(recorder(in: hosting))
            XCTAssertFalse(control.isEnabled)
            XCTAssertEqual(control.placeholderString, "Record Shortcut")
        }
    }

    private static func render(_ view: AnyView, appearance: NSAppearance.Name, to url: URL) throws {
        let hosting = NSHostingView(rootView: view)
        hosting.appearance = NSAppearance(named: appearance)
        let size = hosting.fittingSize
        XCTAssertGreaterThan(size.width, 0)
        XCTAssertGreaterThan(size.height, 0)
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = hosting.appearance
        window.contentView = hosting
        defer { window.contentView = nil }
        window.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }
}
