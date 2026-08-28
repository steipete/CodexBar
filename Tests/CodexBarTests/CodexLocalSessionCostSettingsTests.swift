import CodexBarCore
import Foundation
import SwiftUI
import Testing
@testable import CodexBar

@MainActor
struct CodexLocalSessionCostSettingsTests {
    @Test
    func `codex exposes usage and cookie pickers`() throws {
        let fixture = try self.makeSettingsFixture(suite: "CodexLocalSessionCostSettingsTests-codex")
        let context = fixture.settingsContext(provider: .codex)

        let pickers = CodexProviderImplementation().settingsPickers(context: context)
        let toggles = CodexProviderImplementation().settingsToggles(context: context)
        #expect(pickers.contains(where: { $0.id == "codex-usage-source" }))
        let usagePicker = try #require(pickers.first(where: { $0.id == "codex-usage-source" }))
        #expect(usagePicker.title == "Quota usage source")
        #expect(usagePicker.subtitle.contains("Local session cost estimates work independently"))
        let cookiePicker = try #require(pickers.first(where: { $0.id == "codex-cookie-source" }))
        #expect(cookiePicker.placement == .connection)
        let localLedgerToggle = try #require(toggles.first(where: { $0.id == "codex-local-session-cost-ledger" }))
        #expect(localLedgerToggle.title == "Local session cost estimates")
        #expect(localLedgerToggle.subtitle.contains("organization API keys"))
        #expect(!localLedgerToggle.binding.wrappedValue)
        localLedgerToggle.binding.wrappedValue = true
        #expect(fixture.settings.codexLocalSessionCostLedgerEnabled)
        #expect(!fixture.settings.costUsageEnabled)
        #expect(fixture.settings.isCostUsageEffectivelyEnabled(for: .codex))
        #expect(!fixture.settings.isCostUsageEffectivelyEnabled(for: .claude))
        #expect(toggles.contains(where: { $0.id == "codex-historical-tracking" }))
        let sparkToggle = try #require(toggles.first(where: { $0.id == "codex-spark-usage-visible" }))
        #expect(sparkToggle.title == "Show Codex Spark usage")
        #expect(sparkToggle.subtitle.contains("menu and provider preview"))
        #expect(sparkToggle.binding.wrappedValue)
        #expect(sparkToggle.isEnabled?() == true)

        sparkToggle.binding.wrappedValue = false
        #expect(fixture.settings.codexSparkUsageVisible == false)

        fixture.settings.showOptionalCreditsAndExtraUsage = false
        #expect(sparkToggle.isEnabled?() == false)
    }

    @Test
    func `codex local session cost setting is localized in Korean`() throws {
        let fixture = try self.makeSettingsFixture(suite: "CodexLocalSessionCostSettingsTests-korean-copy")
        let context = fixture.settingsContext(provider: .codex)
        let toggle = try #require(CodexProviderImplementation().settingsToggles(context: context)
            .first(where: { $0.id == "codex-local-session-cost-ledger" }))
        let expectedSubtitle = [
            "선택한 관리 계정의 세션 기록 대신 이 Mac의 Codex 세션을 사용합니다.",
            "조직 API 키를 지원하며 OpenAI 결제 정보나 관리자 권한 없이 사용할 수 있습니다.",
            "네트워크 요청 없이 로컬에 캐시되었거나 앱에 포함된 모델 가격을 사용합니다.",
            "이 공급자 전용 설정은 다른 공급자의 비용 요약을 활성화하지 않습니다.",
        ].joined(separator: "\n")

        #expect(L(toggle.title, language: "ko") == "로컬 세션 비용 추정치")
        #expect(L(toggle.subtitle, language: "ko") == expectedSubtitle)
    }

    @Test
    func `codex local ledger ignores the managed account home`() throws {
        let fixture = try self.makeSettingsFixture(suite: "CodexLocalSessionCostSettingsTests-local-ledger")
        fixture.settings._test_activeManagedCodexRemoteHomePath = "/tmp/managed-codex-home"
        fixture.settings.codexActiveSource = .managedAccount(id: UUID())
        defer { fixture.settings._test_activeManagedCodexRemoteHomePath = nil }

        let managedScope = fixture.store.tokenCostScope(for: .codex)
        fixture.settings.codexLocalSessionCostLedgerEnabled = true
        let localScope = fixture.store.tokenCostScope(for: .codex)

        #expect(managedScope.codexHomePath == "/tmp/managed-codex-home")
        #expect(managedScope.signature == "codex:managed:/tmp/managed-codex-home")
        #expect(localScope.codexHomePath == nil)
        #expect(localScope.signature == "codex:ambient")
    }

    @Test
    func `unresolved managed cost scope never falls back to ambient sessions`() throws {
        let fixture = try self.makeSettingsFixture(suite: "CodexLocalSessionCostSettingsTests-managed-unresolved")
        let accountID = UUID()
        fixture.settings.codexActiveSource = .managedAccount(id: accountID)

        let scope = fixture.store.tokenCostScope(for: .codex)

        #expect(scope.codexHomePath != nil)
        #expect(scope.signature != "codex:ambient")
        #expect(scope.signature.hasPrefix("codex:managed:"))
    }

    private func makeSettingsFixture(suite: String) throws -> Fixture {
        let settings = testSettingsStore(suiteName: suite)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        settings._test_managedCodexAccountStoreURL = root.appendingPathComponent("accounts.json")
        let environment = ["HOME": root.path, "CODEX_HOME": root.appendingPathComponent("codex").path]
        let store = UsageStore(
            fetcher: UsageFetcher(environment: environment),
            browserDetection: BrowserDetection(homeDirectory: root.path, cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: environment)
        return Fixture(settings: settings, store: store)
    }

    private struct Fixture {
        let settings: SettingsStore
        let store: UsageStore
        private let state = ProviderSettingsContextState()

        @MainActor
        func settingsContext(provider: UsageProvider) -> ProviderSettingsContext {
            let settings = self.settings
            let store = self.store
            let state = self.state
            return ProviderSettingsContext(
                provider: provider,
                settings: settings,
                store: store,
                boolBinding: { keyPath in
                    Binding(
                        get: { settings[keyPath: keyPath] },
                        set: { settings[keyPath: keyPath] = $0 })
                },
                stringBinding: { keyPath in
                    Binding(
                        get: { settings[keyPath: keyPath] },
                        set: { settings[keyPath: keyPath] = $0 })
                },
                statusText: { id in state.statusByID[id] },
                setStatusText: { id, text in
                    if let text {
                        state.statusByID[id] = text
                    } else {
                        state.statusByID.removeValue(forKey: id)
                    }
                },
                lastAppActiveRunAt: { id in state.lastRunAtByID[id] },
                setLastAppActiveRunAt: { id, date in
                    if let date {
                        state.lastRunAtByID[id] = date
                    } else {
                        state.lastRunAtByID.removeValue(forKey: id)
                    }
                },
                requestConfirmation: { _ in },
                runLoginFlow: {})
        }
    }

    private final class ProviderSettingsContextState {
        var statusByID: [String: String] = [:]
        var lastRunAtByID: [String: Date] = [:]
    }
}
