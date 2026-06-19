import AppKit
import SwiftUI
import Testing
@testable import CodexBar

@MainActor
struct SettingsWindowAppearanceTests {
    @Test
    func `bridge pulses exact effective appearance then restores inheritance`() {
        let application = NSApplication.shared
        let effectiveAppearance = application.effectiveAppearance
        let staleSource = NSView()
        staleSource.appearance = NSAppearance(named: .aqua)
        let resetCapture = ResetCapture()
        let bridge = SettingsWindowAppearanceView { resetCapture.actions.append($0) }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.appearanceSource = staleSource
        window.contentView = bridge

        let pulseMatchesEffectiveAppearance = window.appearance === effectiveAppearance
        let sourceIsApplication = (window.appearanceSource as AnyObject?) === application
        #expect(pulseMatchesEffectiveAppearance)
        #expect(sourceIsApplication)
        #expect(resetCapture.actions.count == 1)

        resetCapture.actions[0]()

        #expect(window.appearance == nil)
        #expect(window.viewsNeedDisplay)
    }

    @Test
    func `repeated theme updates cannot leave an explicit appearance`() {
        let resetCapture = ResetCapture()
        let bridge = SettingsWindowAppearanceView { resetCapture.actions.append($0) }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false)
        window.contentView = bridge

        bridge.refreshWindowAppearance(for: .light)
        bridge.refreshWindowAppearance(for: .light)
        bridge.refreshWindowAppearance(for: .dark)
        #expect(resetCapture.actions.count == 3)
        for action in resetCapture.actions {
            action()
        }

        let sourceIsApplication = (window.appearanceSource as AnyObject?) === NSApplication.shared
        #expect(window.appearance == nil)
        #expect(sourceIsApplication)
    }
}

@MainActor
private final class ResetCapture {
    var actions: [SettingsWindowAppearance.ResetAction] = []
}
