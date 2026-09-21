import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct KiloOrganizationRefreshTests {
    enum Change: CaseIterable {
        case credential, credentialAndRestore, selection, catalog, source, enablement, cancellation
    }

    @Test(arguments: [false, true], [false, true])
    func `CLI credential changes outside settings invalidate organization discovery`(
        removeCredential: Bool,
        failure: Bool) async throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let authFile = root.appendingPathComponent(".local/share/kilo/auth.json")
        try FileManager.default.createDirectory(
            at: authFile.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(#"{"kilo":{"access":"fixture-cli-a"}}"#.utf8).write(to: authFile)
        let fixture = try Fixture(environment: ["HOME": root.path])
        fixture.settings.kiloUsageDataSource = .cli
        let revision = fixture.settings.providerConfigRevision(for: .kilo)
        let request = Task { await fixture.descriptor.onRefresh() }
        #expect(await fixture.loader.waitUntilStarted())
        do {
            if removeCredential {
                try FileManager.default.removeItem(at: authFile)
            } else {
                try Data(#"{"kilo":{"access":"fixture-cli-b"}}"#.utf8).write(to: authFile, options: .atomic)
            }
        } catch {
            await fixture.loader.finish(failure: true)
            _ = await request.value
            throw error
        }
        #expect(fixture.settings.providerConfigRevision(for: .kilo) == revision)
        await fixture.loader.finish(failure: failure)
        let outcome = await request.value
        #expect(!outcome.success)
        #expect(outcome.errorMessage == nil)
        #expect(fixture.settings.kiloKnownOrganizations == [Fixture.alpha, Fixture.beta])
        #expect(fixture.settings.kiloEnabledOrganizationIDs == [Fixture.alpha.id])
    }

    @Test(arguments: Change.allCases, [false, true])
    func `obsolete organization results and errors leave current settings intact`(
        change: Change,
        failure: Bool) async throws
    {
        let fixture = try Fixture()
        let request = Task { await fixture.descriptor.onRefresh() }
        #expect(await fixture.loader.waitUntilStarted())
        switch change {
        case .credential:
            fixture.settings.kiloAPIToken = "fixture-token-b"
            fixture.settings.kiloKnownOrganizations = [Fixture.beta]
            fixture.settings.kiloEnabledOrganizationIDs = [Fixture.beta.id]
        case .credentialAndRestore:
            fixture.settings.kiloAPIToken = "fixture-token-b"
            fixture.settings.kiloAPIToken = "fixture-token-a"
        case .selection:
            fixture.settings.kiloEnabledOrganizationIDs = [Fixture.beta.id]
        case .catalog:
            fixture.settings.kiloKnownOrganizations = [Fixture.beta]
        case .source:
            fixture.settings.kiloUsageDataSource = .cli
        case .enablement:
            fixture.settings.setProviderEnabled(
                provider: .kilo,
                metadata: ProviderDescriptorRegistry.descriptor(for: .kilo).metadata,
                enabled: true)
        case .cancellation:
            request.cancel()
        }
        let expectedCatalog = fixture.settings.kiloKnownOrganizations
        let expectedEnabled = fixture.settings.kiloEnabledOrganizationIDs
        await fixture.loader.finish(failure: failure)
        let outcome = await request.value
        #expect(!outcome.success)
        #expect(outcome.errorMessage == nil)
        #expect(fixture.settings.kiloKnownOrganizations == expectedCatalog)
        #expect(fixture.settings.kiloEnabledOrganizationIDs == expectedEnabled)
    }

    @Test(arguments: [false, true])
    func `current organization refresh still prunes selections and reports failures`(failure: Bool) async throws {
        let fixture = try Fixture()
        let request = Task { await fixture.descriptor.onRefresh() }
        #expect(await fixture.loader.waitUntilStarted())
        await fixture.loader.finish(failure: failure)
        let outcome = await request.value
        #expect(outcome.success == !failure)
        #expect(outcome.errorMessage == (failure ? "Synthetic organization failure" : nil))
        #expect(fixture.settings.kiloKnownOrganizations == (failure ? [Fixture.alpha, Fixture.beta] : [Fixture.beta]))
        #expect(fixture.settings.kiloEnabledOrganizationIDs == (failure ? [Fixture.alpha.id] : []))
    }

    @Test
    func `display and unrelated provider changes preserve a current organization refresh`() async throws {
        let fixture = try Fixture()
        let request = Task { await fixture.descriptor.onRefresh() }
        #expect(await fixture.loader.waitUntilStarted())
        fixture.settings.updateProviderConfig(provider: .kilo) { $0.accentColor = "#FF0000" }
        fixture.settings.updateProviderConfig(provider: .codex) { $0.enabled = false }
        await fixture.loader.finish(failure: false)
        let outcome = await request.value
        #expect(outcome.success)
        #expect(fixture.settings.kiloKnownOrganizations == [Fixture.beta])
    }

    @MainActor
    private struct Fixture {
        static let alpha = KiloOrganization(id: "org-a", name: "Alpha", role: nil)
        static let beta = KiloOrganization(id: "org-b", name: "Beta", role: nil)
        let settings = testSettingsStore(suiteName: "KiloOrganizationRefresh", userDefaults: InMemoryUserDefaults())
        let loader = GatedLoader()
        let descriptor: ProviderSettingsOrganizationsDescriptor

        init(environment: [String: String] = [:]) throws {
            self.settings.kiloUsageDataSource = .api
            self.settings.kiloAPIToken = "fixture-token-a"
            self.settings.kiloKnownOrganizations = [Self.alpha, Self.beta]
            self.settings.kiloEnabledOrganizationIDs = [Self.alpha.id]
            let store = UsageStore(
                fetcher: UsageFetcher(environment: [:]),
                browserDetection: BrowserDetection(cacheTTL: 0),
                settings: self.settings,
                startupBehavior: .testing,
                environmentBase: [:])
            let context = ProviderSettingsContext(
                provider: .kilo,
                settings: self.settings,
                store: store,
                statusText: { _ in nil },
                setStatusText: { _, _ in },
                lastAppActiveRunAt: { _ in nil },
                setLastAppActiveRunAt: { _, _ in },
                requestConfirmation: { _ in },
                runLoginFlow: {})
            var isolatedEnvironment = environment
            isolatedEnvironment["HOME"] = environment["HOME"] ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("kilo-test-home-\(UUID().uuidString)").path
            let implementation =
                KiloProviderImplementation(environment: isolatedEnvironment) { [loader = self.loader] _ in
                    try await loader.load()
                }
            self.descriptor = try #require(implementation.settingsOrganizations(context: context))
        }
    }

    private actor GatedLoader {
        private var started = false
        private var result: Result<[KiloOrganization], any Error>?
        private var continuation: CheckedContinuation<[KiloOrganization], any Error>?

        func load() async throws -> [KiloOrganization] {
            self.started = true
            if let result { return try result.get() }
            return try await withCheckedThrowingContinuation { self.continuation = $0 }
        }

        func waitUntilStarted() async -> Bool {
            let deadline = ContinuousClock.now + .seconds(5)
            while !self.started, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(10))
            }
            return self.started
        }

        func finish(failure: Bool) {
            let result: Result<[KiloOrganization], any Error> = failure
                ? .failure(NSError(
                    domain: "KiloOrganizationRefreshTests",
                    code: 401,
                    userInfo: [NSLocalizedDescriptionKey: "Synthetic organization failure"]))
                : .success([KiloOrganization(id: "org-b", name: "Beta", role: nil)])
            self.result = result
            self.continuation?.resume(with: result)
            self.continuation = nil
        }
    }
}
