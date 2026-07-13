import Foundation
import Testing
@testable import CodexBarCore

struct DeepSeekProviderDescriptorTests {
    private actor CancellationProbe {
        private(set) var wasCancelled = false

        func markCancelled() {
            self.wasCancelled = true
        }
    }

    private actor ResolutionInputProbe {
        private(set) var profileID: String?
        private(set) var requiresExplicitSelection = false

        func record(profileID: String?, requiresExplicitSelection: Bool) {
            self.profileID = profileID
            self.requiresExplicitSelection = requiresExplicitSelection
        }
    }

    @Test
    func `balance failure cancels automatic session resolution promptly`() async {
        let probe = CancellationProbe()
        let operations = DeepSeekProviderDescriptor.FetchOperations(
            fetchUsage: { _, _, _ in
                throw DeepSeekUsageError.apiError("invalid key")
            },
            resolveAutomaticSession: { _, _, _, _ in
                do {
                    try await Task.sleep(for: .seconds(10))
                } catch {
                    await probe.markCancelled()
                }
                return Self.unavailableResolution
            })
        let startedAt = ContinuousClock.now

        await #expect {
            _ = try await DeepSeekProviderDescriptor._loadUsageForTesting(
                apiKey: "invalid",
                context: Self.makeContext(),
                optionalResolutionJoinGrace: .seconds(5),
                operations: operations)
        } throws: { error in
            error as? DeepSeekUsageError == .apiError("invalid key")
        }

        #expect(startedAt.duration(to: .now) < .seconds(1))
        let cancellationDeadline = ContinuousClock.now.advanced(by: .milliseconds(200))
        while await !(probe.wasCancelled), ContinuousClock.now < cancellationDeadline {
            await Task.yield()
        }
        #expect(await probe.wasCancelled)
    }

    @Test
    func `automatic session resolution cannot hold balance past its grace`() async throws {
        let probe = CancellationProbe()
        let operations = DeepSeekProviderDescriptor.FetchOperations(
            fetchUsage: { _, _, _ in Self.balance },
            resolveAutomaticSession: { _, _, _, _ in
                do {
                    try await Task.sleep(for: .seconds(10))
                } catch {
                    await probe.markCancelled()
                }
                return Self.unavailableResolution
            })
        let startedAt = ContinuousClock.now

        let snapshot = try await DeepSeekProviderDescriptor._loadUsageForTesting(
            apiKey: "valid",
            context: Self.makeContext(),
            optionalResolutionJoinGrace: .milliseconds(20),
            operations: operations)

        #expect(snapshot.primary?.resetDescription?.contains("$8.06") == true)
        #expect(snapshot.deepseekUsage == nil)
        #expect(snapshot.deepseekDetailedUsageState == .unavailable)
        #expect(startedAt.duration(to: .now) < .seconds(1))
        let cancellationDeadline = ContinuousClock.now.advanced(by: .milliseconds(200))
        while await !(probe.wasCancelled), ContinuousClock.now < cancellationDeadline {
            await Task.yield()
        }
        #expect(await probe.wasCancelled)
    }

    @Test
    func `automatic session result enriches the required balance`() async throws {
        let summary = DeepSeekUsageSummary(
            todayTokens: 123,
            currentMonthTokens: 456,
            todayCost: 0.1,
            currentMonthCost: 0.2,
            requestCount: 3,
            currentMonthRequestCount: 4,
            topModel: "deepseek-chat",
            categoryBreakdown: [],
            daily: [],
            currency: "USD",
            updatedAt: Date(timeIntervalSince1970: 1))
        let operations = DeepSeekProviderDescriptor.FetchOperations(
            fetchUsage: { _, _, _ in Self.balance },
            resolveAutomaticSession: { _, _, _, _ in
                DeepSeekPlatformTokenImporter.Resolution(
                    profiles: [DeepSeekPlatformProfile(id: "chrome:Default", name: "Chrome — Personal")],
                    selectedSummary: summary,
                    detailedUsageState: .available)
            })

        let snapshot = try await DeepSeekProviderDescriptor._loadUsageForTesting(
            apiKey: "valid",
            context: Self.makeContext(),
            optionalResolutionJoinGrace: .seconds(1),
            operations: operations)

        #expect(snapshot.primary?.resetDescription?.contains("$8.06") == true)
        #expect(snapshot.deepseekUsage?.todayTokens == 123)
        #expect(snapshot.deepseekDetailedUsageState == .available)
        #expect(snapshot.deepseekPlatformProfiles.map(\.id) == ["chrome:Default"])
    }

    @Test
    func `automatic resolution timeout is hard when the resolver ignores cancellation`() async throws {
        let operations = DeepSeekProviderDescriptor.FetchOperations(
            fetchUsage: { _, _, _ in Self.balance },
            resolveAutomaticSession: { _, _, _, _ in
                let deadline = ContinuousClock.now.advanced(by: .milliseconds(500))
                while ContinuousClock.now < deadline {
                    await Task.yield()
                }
                return Self.unavailableResolution
            })
        let startedAt = ContinuousClock.now

        let snapshot = try await DeepSeekProviderDescriptor._loadUsageForTesting(
            apiKey: "valid",
            context: Self.makeContext(),
            optionalResolutionJoinGrace: .milliseconds(20),
            operations: operations)

        #expect(snapshot.primary?.resetDescription?.contains("$8.06") == true)
        #expect(startedAt.duration(to: .now) < .milliseconds(200))
    }

    @Test
    func `profile selection from another api account requires explicit replacement`() async throws {
        let probe = ResolutionInputProbe()
        let selectedAccountID = UUID()
        let otherAccountID = UUID()
        let operations = DeepSeekProviderDescriptor.FetchOperations(
            fetchUsage: { _, _, _ in Self.balance },
            resolveAutomaticSession: { profileID, requiresExplicitSelection, _, _ in
                await probe.record(
                    profileID: profileID,
                    requiresExplicitSelection: requiresExplicitSelection)
                return Self.unavailableResolution
            })
        let otherAccountScope = try #require(DeepSeekSettingsReader.profileScope(
            selectedTokenAccountID: otherAccountID,
            apiKey: "valid"))
        let environment = [
            DeepSeekSettingsReader.profileIDEnvironmentKey: "chrome:Default",
            DeepSeekSettingsReader.profileScopeEnvironmentKey: otherAccountScope,
        ]

        _ = try await DeepSeekProviderDescriptor._loadUsageForTesting(
            apiKey: "valid",
            context: Self.makeContext(environment: environment, selectedTokenAccountID: selectedAccountID),
            optionalResolutionJoinGrace: .seconds(1),
            operations: operations)

        #expect(await probe.profileID == nil)
        #expect(await probe.requiresExplicitSelection)
    }

    @Test
    func `replacing an api key in the same account requires explicit profile replacement`() async throws {
        let probe = ResolutionInputProbe()
        let selectedAccountID = UUID()
        let operations = DeepSeekProviderDescriptor.FetchOperations(
            fetchUsage: { _, _, _ in Self.balance },
            resolveAutomaticSession: { profileID, requiresExplicitSelection, _, _ in
                await probe.record(profileID: profileID, requiresExplicitSelection: requiresExplicitSelection)
                return Self.unavailableResolution
            })
        let oldScope = try #require(DeepSeekSettingsReader.profileScope(
            selectedTokenAccountID: selectedAccountID,
            apiKey: "old-key"))
        let environment = [
            DeepSeekSettingsReader.profileIDEnvironmentKey: "chrome:Default",
            DeepSeekSettingsReader.profileScopeEnvironmentKey: oldScope,
        ]

        _ = try await DeepSeekProviderDescriptor._loadUsageForTesting(
            apiKey: "new-key",
            context: Self.makeContext(environment: environment, selectedTokenAccountID: selectedAccountID),
            optionalResolutionJoinGrace: .seconds(1),
            operations: operations)

        #expect(await probe.profileID == nil)
        #expect(await probe.requiresExplicitSelection)
    }

    @Test
    func `changing the environment api key requires explicit profile replacement`() async throws {
        let probe = ResolutionInputProbe()
        let operations = DeepSeekProviderDescriptor.FetchOperations(
            fetchUsage: { _, _, _ in Self.balance },
            resolveAutomaticSession: { profileID, requiresExplicitSelection, _, _ in
                await probe.record(profileID: profileID, requiresExplicitSelection: requiresExplicitSelection)
                return Self.unavailableResolution
            })
        let oldScope = try #require(DeepSeekSettingsReader.profileScope(
            selectedTokenAccountID: nil,
            apiKey: "old-key"))
        let environment = [
            DeepSeekSettingsReader.profileIDEnvironmentKey: "chrome:Default",
            DeepSeekSettingsReader.profileScopeEnvironmentKey: oldScope,
        ]

        _ = try await DeepSeekProviderDescriptor._loadUsageForTesting(
            apiKey: "new-key",
            context: Self.makeContext(environment: environment),
            optionalResolutionJoinGrace: .seconds(1),
            operations: operations)

        #expect(await probe.profileID == nil)
        #expect(await probe.requiresExplicitSelection)
    }

    private static let balance = DeepSeekUsageSnapshot(
        isAvailable: true,
        currency: "USD",
        totalBalance: 8.06,
        grantedBalance: 0,
        toppedUpBalance: 8.06,
        updatedAt: Date(timeIntervalSince1970: 1))

    private static let unavailableResolution = DeepSeekPlatformTokenImporter.Resolution(
        profiles: [],
        selectedSummary: nil,
        detailedUsageState: .unavailable)

    private static func makeContext(
        environment: [String: String] = [:],
        selectedTokenAccountID: UUID? = nil) -> ProviderFetchContext
    {
        let browserDetection = BrowserDetection(cacheTTL: 0)
        return ProviderFetchContext(
            runtime: .app,
            sourceMode: .api,
            includeCredits: false,
            includeOptionalUsage: true,
            webTimeout: 60,
            webDebugDumpHTML: false,
            verbose: false,
            env: environment,
            settings: nil,
            fetcher: UsageFetcher(environment: [:]),
            claudeFetcher: ClaudeUsageFetcher(browserDetection: browserDetection),
            browserDetection: browserDetection,
            selectedTokenAccountID: selectedTokenAccountID)
    }
}
