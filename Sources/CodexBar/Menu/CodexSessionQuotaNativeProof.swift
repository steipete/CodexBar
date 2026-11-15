#if DEBUG
import AppKit
import CodexBarCore
import SwiftUI

/// Opt-in application-entry-point proof. Uses synthetic quota data before settings or provider startup.
@MainActor
enum CodexSessionQuotaNativeProof {
    static func runIfRequested() -> Bool {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--session-quota-proof-dir") else { return false }
        guard arguments.indices.contains(index + 1) else { exit(2) }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = Delegate(directory: URL(fileURLWithPath: arguments[index + 1], isDirectory: true))
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
        return true
    }

    private static func model() -> UsageMenuCardView.Model {
        guard let metadata = ProviderDefaults.metadata[.codex] else {
            preconditionFailure("Codex provider metadata is required for the quota proof")
        }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 0,
                windowMinutes: 300,
                resetsAt: now.addingTimeInterval(3600),
                resetDescription: nil),
            secondary: RateWindow(
                usedPercent: 100,
                windowMinutes: 10080,
                resetsAt: now.addingTimeInterval(3 * 86400),
                resetDescription: nil),
            tertiary: nil,
            updatedAt: now,
            identity: nil)
        let projection = CodexConsumerProjection.make(
            surface: .liveCard,
            context: .init(
                snapshot: snapshot,
                rawUsageError: nil,
                liveCredits: nil,
                rawCreditsError: nil,
                liveDashboard: nil,
                rawDashboardError: nil,
                dashboardAttachmentAuthorized: false,
                dashboardRequiresLogin: false,
                now: now))
        return UsageMenuCardView.Model.make(.init(
            provider: .codex,
            metadata: metadata,
            snapshot: snapshot,
            codexProjection: projection,
            credits: nil,
            creditsError: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: true,
            now: now))
    }

    @MainActor
    private final class Delegate: NSObject, NSApplicationDelegate {
        private let directory: URL
        private var index = 0
        private var window: NSWindow?
        private let modes = ["expanded", "compact", "settings"]

        init(directory: URL) {
            self.directory = directory
            super.init()
        }

        func applicationDidFinishLaunching(_ notification: Notification) {
            do {
                try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
                self.showNext()
            } catch {
                self.fail(error)
            }
        }

        private func showNext() {
            guard self.index < self.modes.count else {
                NSApplication.shared.terminate(nil)
                return
            }
            let mode = self.modes[self.index]
            let model = CodexSessionQuotaNativeProof.model()
            let content = if mode == "settings" {
                AnyView(ProviderMetricsInlineView(
                    provider: .codex,
                    model: model.applyingUsageItemVisibility(hiddenItemIDs: [.metric("secondary")]),
                    openAIWebDiagnostic: nil,
                    isEnabled: true,
                    isRefreshing: false)
                    .padding(16))
            } else {
                AnyView(VStack(spacing: 0) {
                    UsageMenuCardHeaderSectionView(model: model, showDivider: true, width: 350)
                    UsageMenuCardUsageSectionView(
                        model: model,
                        layoutModel: model,
                        showBottomDivider: false,
                        bottomPadding: 12,
                        width: 350,
                        compactMetrics: mode == "compact")
                })
            }
            let hosting = NSHostingView(rootView: content
                .environment(\.colorScheme, .dark)
                .environment(\.locale, Locale(identifier: "en_US"))
                .background(Color(white: 0.16))
                .frame(width: 350))
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false)
            window.isReleasedWhenClosed = false
            window.title = "CodexBar synthetic quota proof — \(mode)"
            window.contentView = hosting
            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            self.window = window
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.capture(mode: mode)
            }
        }

        private func capture(mode: String) {
            do {
                guard let window = self.window, let view = window.contentView,
                      let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
                else { throw CocoaError(.fileWriteUnknown) }
                view.layoutSubtreeIfNeeded()
                view.cacheDisplay(in: view.bounds, to: bitmap)
                guard let png = bitmap.representation(using: .png, properties: [:]) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                try png.write(to: self.directory.appendingPathComponent("native-codex-weekly-block-\(mode).png"))
                print("SESSION_QUOTA_PROOF mode=\(mode) window=\(window.windowNumber) bytes=\(png.count)")
                window.close()
                self.window = nil
                self.index += 1
                self.showNext()
            } catch {
                self.fail(error)
            }
        }

        private func fail(_ error: Error) {
            FileHandle.standardError.write(Data("SESSION_QUOTA_PROOF_FAILED \(error)\n".utf8))
            exit(1)
        }
    }
}
#endif
