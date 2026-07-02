import AppKit
import CodexBarCore
import SwiftUI

struct QuotaWarningAlertPresentationState {
    struct Presentation: Equatable {
        let generation: UInt
        let title: String
        let message: String
    }

    private(set) var current: Presentation?
    private var nextGeneration: UInt = 0

    mutating func present(title: String, message: String) -> Presentation {
        self.nextGeneration &+= 1
        let presentation = Presentation(
            generation: self.nextGeneration,
            title: title,
            message: message)
        self.current = presentation
        return presentation
    }

    mutating func dismiss(generation: UInt) -> Bool {
        guard self.current?.generation == generation else { return false }
        self.current = nil
        return true
    }

    mutating func dismiss() {
        self.current = nil
    }
}

/// Presents a transient, centered text alert when a quota warning threshold is crossed.
///
/// Modeled after ``ScreenConfettiOverlayController``: it shows a borderless, click-through
/// panel above all spaces and auto-dismisses after a short lifetime, so it never steals focus
/// or blocks the user's work.
@MainActor
final class QuotaWarningAlertOverlayController {
    private static let overlayLifetime: TimeInterval = 4.5

    private let logger = CodexBarLog.logger(LogCategories.sessionQuotaNotifications)
    private var presentationState = QuotaWarningAlertPresentationState()
    private var window: NSWindow?
    private var dismissalTask: Task<Void, Never>?

    func show(title: String, message: String) {
        self.dismiss()

        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            self.logger.error("Cannot present quota warning overlay because no screens were found")
            return
        }

        let presentation = self.presentationState.present(title: title, message: message)

        let frame = screen.frame
        let contentView = QuotaWarningAlertOverlayView(title: title, message: message)
            .allowsHitTesting(false)
        let hostingView = NSHostingView(rootView: contentView)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor

        let window = ClickThroughAlertPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false,
            screen: screen)
        window.contentView = hostingView
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.acceptsMouseMovedEvents = false
        window.isMovable = false
        window.isReleasedWhenClosed = false
        window.canHide = false
        window.hidesOnDeactivate = false
        window.becomesKeyOnlyIfNeeded = false
        window.isExcludedFromWindowsMenu = true
        window.setFrame(frame, display: false)
        window.orderFrontRegardless()
        self.window = window

        self.logger.info("Presenting quota warning overlay")

        self.dismissalTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.overlayLifetime))
            guard !Task.isCancelled else { return }
            guard let self, self.presentationState.dismiss(generation: presentation.generation) else { return }
            self.closeWindow()
        }
    }

    func dismiss() {
        self.dismissalTask?.cancel()
        self.dismissalTask = nil
        self.presentationState.dismiss()
        self.closeWindow()
    }

    private func closeWindow() {
        guard let window = self.window else { return }
        window.orderOut(nil)
        window.close()
        self.window = nil
    }
}

private final class ClickThroughAlertPanel: NSPanel {
    override var canBecomeKey: Bool {
        false
    }

    override var canBecomeMain: Bool {
        false
    }

    override var acceptsFirstResponder: Bool {
        false
    }
}

private struct QuotaWarningAlertOverlayView: View {
    let title: String
    let message: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title2)
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 4) {
                Text(self.title)
                    .font(.headline)
                Text(self.message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 20)
        .frame(maxWidth: 420, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.25), radius: 24, y: 8)
        .scaleEffect(self.reduceMotion || self.appeared ? 1 : 0.92)
        .opacity(self.reduceMotion || self.appeared ? 1 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .padding(40)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(self.title)
        .accessibilityValue(self.message)
        .task {
            guard !self.reduceMotion else {
                self.appeared = true
                return
            }
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                self.appeared = true
            }
        }
    }
}
