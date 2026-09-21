import CodexBarCore
import Testing
@testable import CodexBar

@MainActor
struct MenuDescriptorUpdateAndVersionTests {
    @Test(arguments: [false, true], [false, true])
    func `update availability and readiness select exactly one action`(available: Bool, ready: Bool) {
        let descriptor = self.descriptor(available: available, ready: ready, version: "1.2.3")
        let actions = descriptor.sections.flatMap(\.entries).compactMap { entry -> MenuDescriptor.MenuAction? in
            guard case let .action(_, action) = entry else { return nil }
            return action
        }

        #expect(actions.contains(.installUpdate) == ready)
        #expect(actions.contains(.checkForUpdates) == (available && !ready))
        #expect(actions.contains(.refresh))
        #expect(actions.contains(.settings))
        #expect(actions.contains(.about))
        #expect(actions.contains(.quit))
    }

    @Test(arguments: ["", "1.2.3", "1.2.3beta4"])
    func `about label includes only a known short version`(version: String) {
        let descriptor = self.descriptor(available: false, ready: false, version: version)
        let labels = descriptor.sections.flatMap(\.entries).compactMap { entry -> String? in
            guard case let .action(label, .about) = entry else { return nil }
            return label
        }

        #expect(labels == [L("About CodexBar") + (version.isEmpty ? "" : " (v\(version))")])
    }

    @Test(arguments: [
        ("codex-cli 1.2.3", "1.2.3"),
        ("1.2.3beta4", "1.2.3"),
        ("build 12 version 3.4", "12"),
        ("no version", ""),
        ("v1.2.", "1.2"),
    ])
    func `provider headline retains its first numeric version`(raw: String, expected: String) throws {
        let descriptor = self.descriptor(available: false, ready: false, version: "", providerVersion: raw)
        let headlines = descriptor.sections.flatMap(\.entries).compactMap { entry -> String? in
            guard case let .text(label, .headline) = entry else { return nil }
            return label
        }
        let name = try #require(ProviderRegistry.shared.metadata[.codex]?.displayName)
        #expect(headlines.first == name + (expected.isEmpty ? "" : " \(expected)"))
    }

    @Test
    func `update actions have distinct menu symbols`() {
        #expect(MenuDescriptor.MenuAction.checkForUpdates.systemImageName == "arrow.triangle.2.circlepath.circle")
        #expect(MenuDescriptor.MenuAction.installUpdate.systemImageName == "arrow.down.circle")
    }

    private func descriptor(
        available: Bool,
        ready: Bool,
        version: String,
        providerVersion: String? = nil) -> MenuDescriptor
    {
        let settings = testSettingsStore(
            suiteName: "MenuDescriptorUpdateAndVersionTests",
            userDefaults: InMemoryUserDefaults(),
            config: testConfigWithAllProvidersDisabled())
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            environmentBase: [:])
        store.accountInfoCache[.codex] = UsageStore.AccountInfoCacheEntry(
            account: AccountInfo(email: nil, plan: nil),
            configRevision: settings.configRevision,
            expiresAt: .distantFuture)
        store.versions[.codex] = providerVersion
        return MenuDescriptor.build(
            provider: providerVersion == nil ? nil : .codex,
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updateReady: ready,
            canCheckForUpdates: available,
            versionText: version,
            includeContextualActions: false)
    }
}
