import AppKit
import SwiftUI
import Testing
@testable import CodexBar

/// Offscreen production settings rendering with dictionary-backed defaults; never opens the app or a visible window.
@MainActor
struct StayAwakeNotificationProofTests {
    @Test
    func `render synthetic settings when requested`() throws {
        guard let directory = ProcessInfo.processInfo.environment["CODEXBAR_STAY_AWAKE_PROOF_DIR"] else { return }
        let settings = testSettingsStore(suiteName: #function, userDefaults: InMemoryUserDefaults())
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try self.capture(Form {
            AgentSessionsSettingsSection(settings: settings)
        }.formStyle(.grouped).toggleStyle(.switch), to: output.appendingPathComponent("sessions.png"))
        try self.capture(NotificationsPane(settings: settings), to: output.appendingPathComponent("notifications.png"))
    }

    private func capture(_ content: some View, to destination: URL) throws {
        let view = NSHostingView(rootView: content.frame(width: 700, height: 540).background(Color.white))
        view.frame = NSRect(x: 0, y: 0, width: 700, height: 540)
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = view
        defer { window.contentView = nil }
        window.layoutIfNeeded()
        view.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: destination)
    }
}
