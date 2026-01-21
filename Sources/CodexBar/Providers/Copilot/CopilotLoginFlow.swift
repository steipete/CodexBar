import AppKit
import CodexBarCore
import SwiftUI

@MainActor
struct CopilotLoginFlow {
    static func run(settings: SettingsStore) async {
        let flow = CopilotDeviceFlow()

        do {
            let code = try await flow.requestDeviceCode()

            // Copy code to clipboard
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(code.userCode, forType: .string)

            let alert = NSAlert()
            alert.messageText = "GitHub Copilot Login"
            alert.informativeText = """
            A device code has been copied to your clipboard: \(code.userCode)

            Please verify it at: \(code.verificationUri)
            """
            alert.addButton(withTitle: "Open Browser")
            alert.addButton(withTitle: "Cancel")

            let response = alert.runModal()
            if response == .alertSecondButtonReturn {
                return // Cancelled
            }

            if let url = URL(string: code.verificationUri) {
                NSWorkspace.shared.open(url)
            }

            // Poll in background (modal blocks, but we need to wait for token effectively)
            // Ideally we'd show a "Waiting..." modal or spinner.
            // For simplicity, we can use a non-modal window or just block a Task?
            // `runModal` blocks the thread. We need to poll while the user is doing auth in browser.
            // But we already returned from runModal to open the browser.
            // We need a secondary "Waiting for confirmation..." alert or state.

            // Let's show a "Waiting" alert that can be cancelled.
            let waitingAlert = NSAlert()
            waitingAlert.messageText = "Waiting for Authentication..."
            waitingAlert.informativeText = """
            Please complete the login in your browser.
            This window will close automatically when finished.
            """
            waitingAlert.addButton(withTitle: "Cancel")
            let parentWindow = Self.resolveWaitingParentWindow()
            let hostWindow = parentWindow ?? Self.makeWaitingHostWindow()
            let shouldCloseHostWindow = parentWindow == nil
            let tokenTask = Task.detached(priority: .userInitiated) {
                try await flow.pollForToken(deviceCode: code.deviceCode, interval: code.interval)
            }

            let waitTask = Task { @MainActor in
                let response = await Self.presentWaitingAlert(waitingAlert, parentWindow: hostWindow)
                if response == .alertFirstButtonReturn {
                    tokenTask.cancel()
                }
                return response
            }

            let tokenResult: Result<String, Error>
            do {
                let token = try await tokenTask.value
                tokenResult = .success(token)
            } catch {
                tokenResult = .failure(error)
            }

            Self.dismissWaitingAlert(waitingAlert, parentWindow: hostWindow, closeHost: shouldCloseHostWindow)
            let waitResponse = await waitTask.value
            if waitResponse == .alertFirstButtonReturn {
                return
            }

            switch tokenResult {
            case let .success(token):
                settings.copilotAPIToken = token
                settings.setProviderEnabled(
                    provider: .copilot,
                    metadata: ProviderRegistry.shared.metadata[.copilot]!,
                    enabled: true)

                let success = NSAlert()
                success.messageText = "Login Successful"
                success.runModal()
            case let .failure(error):
                guard !(error is CancellationError) else { return }
                let err = NSAlert()
                err.messageText = "Login Failed"
                err.informativeText = error.localizedDescription
                err.runModal()
            }

        } catch {
            let err = NSAlert()
            err.messageText = "Login Failed"
            err.informativeText = error.localizedDescription
            err.runModal()
        }
    }

    @MainActor
    private static func presentWaitingAlert(
        _ alert: NSAlert,
        parentWindow: NSWindow) async -> NSApplication.ModalResponse
    {
        await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: parentWindow) { response in
                continuation.resume(returning: response)
            }
        }
    }

    @MainActor
    private static func dismissWaitingAlert(
        _ alert: NSAlert,
        parentWindow: NSWindow,
        closeHost: Bool)
    {
        let alertWindow = alert.window
        if alertWindow.sheetParent != nil {
            parentWindow.endSheet(alertWindow)
        } else {
            alertWindow.orderOut(nil)
        }

        guard closeHost else { return }
        parentWindow.orderOut(nil)
        parentWindow.close()
    }

    @MainActor
    private static func resolveWaitingParentWindow() -> NSWindow? {
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            return window
        }
        if let window = NSApp.windows.first(where: { $0.isVisible && !$0.ignoresMouseEvents }) {
            return window
        }
        return NSApp.windows.first
    }

    @MainActor
    private static func makeWaitingHostWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 1),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.center()
        window.makeKeyAndOrderFront(nil)
        return window
    }
}
