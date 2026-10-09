import AppKit
import CodexBarCore
import SwiftUI
import Testing
@testable import CodexBar

@MainActor
extension CodexAccountScopedRefreshTests {
    /// Opt-in production rendering with synthetic identities and usage; no visible app or account transport.
    @Test
    func `render synthetic multi account settings overview`() async throws {
        guard let path = ProcessInfo.processInfo.environment["CODEXBAR_ACCOUNT_OVERVIEW_PROOF_DIR"] else { return }
        let output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try await self.withSelectedAccountRetentionFixture(sameEmail: true, count: 3) { store, _, accounts in
            store.codexAccountSnapshots.removeAll { $0.id == accounts[2].id }
            for language in ["en", "zh-Hans"] {
                for width in [860.0, 560.0] {
                    store.settings.hidePersonalInfo = width < 600
                    try CodexBarLocalizationOverride.$appLanguage.withValue(language) {
                        let overview = try #require(store.codexAccountUsageOverview(onRefresh: { _ in }))
                        let content = Form {
                            Text("Synthetic Codex account data").font(.headline)
                            ProviderAccountUsageOverviewView(provider: .codex, overview: overview, isEnabled: true)
                            Section {
                                ProviderTokenUsageInlineView(provider: .codex, tokenUsage: .init(
                                    sessionLine: "Synthetic local usage: 12K tokens",
                                    monthLine: "Synthetic last 30 days: 180K tokens",
                                    hintLine: nil,
                                    errorLine: nil,
                                    errorCopyText: nil))
                            } header: {
                                Text(L("This Mac"))
                            } footer: {
                                SettingsSectionFooter(L("Local usage is shared across accounts on this Mac."))
                            }
                        }
                        .formStyle(.grouped)
                        .frame(width: width, height: 1080)
                        .environment(\.colorScheme, .light)
                        try self.writeOverviewProof(content, to: output.appendingPathComponent(
                            "overview-\(language)-\(Int(width)).png"))
                    }
                }
            }
        }
    }

    @Test
    func `render synthetic prior single account settings usage`() async throws {
        guard let path = ProcessInfo.processInfo.environment["CODEXBAR_ACCOUNT_OVERVIEW_PROOF_DIR"] else { return }
        let output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try await self.withSelectedAccountRetentionFixture(sameEmail: true, count: 3) { store, _, accounts in
            store.snapshots[.codex] = store.codexAccountSnapshots.first { $0.id == accounts[0].id }?.snapshot
            try CodexBarLocalizationOverride.$appLanguage.withValue("en") {
                let model = store.menuCardModel(for: .codex, context: .settings)
                // The pre-overview settings layout uses these same shared components for one live model.
                let content = Form {
                    Text("Synthetic Codex account data — prior settings layout").font(.headline)
                    Section {
                        ProviderDetailInfoRows(
                            provider: .codex, store: store, isEnabled: true, versionText: nil, model: model)
                    }
                    Section {
                        ProviderMetricsInlineView(
                            provider: .codex,
                            model: model,
                            openAIWebDiagnostic: nil,
                            isEnabled: true,
                            isRefreshing: false)
                    } header: {
                        Text(L("Usage"))
                    }
                }
                .formStyle(.grouped)
                .frame(width: 860, height: 440)
                .environment(\.colorScheme, .light)
                try self.writeOverviewProof(content, to: output.appendingPathComponent("before-en-860.png"))
            }
        }
    }

    func writeRotatedAuthOverviewProof(_ overview: ProviderAccountUsageOverview, phase: String) throws {
        guard let path = ProcessInfo.processInfo.environment["CODEXBAR_ACCOUNT_OVERVIEW_PROOF_DIR"] else { return }
        let output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let content = Form {
            Text("Synthetic Codex accounts — credential rotation").font(.headline)
            ProviderAccountUsageOverviewView(provider: .codex, overview: overview, isEnabled: true)
        }
        .formStyle(.grouped)
        .frame(width: 860, height: 780)
        .environment(\.colorScheme, .light)
        try self.writeOverviewProof(content, to: output.appendingPathComponent("\(phase).png"))
    }

    private func writeOverviewProof(_ content: some View, to url: URL) throws {
        let hosting = NSHostingView(rootView: content)
        hosting.appearance = NSAppearance(named: .aqua)
        hosting.frame = CGRect(origin: .zero, size: hosting.fittingSize)
        let window = NSWindow(
            contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer {
            window.contentView = nil
            window.close()
        }
        window.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: url, options: .atomic)
    }
}
