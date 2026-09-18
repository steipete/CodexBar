import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@Suite(.serialized, ClaudeOAuthDefaultsFixtures(), ProviderTransportRegressionFixtures())
@MainActor
struct DeepSeekTransportOwnershipTests {
    private typealias Fixture = DeepSeekTransportTestSupport

    @Test
    func `balance ownership fingerprints the exact trimmed token without cookie normalization`() throws {
        let owner = try #require(DeepSeekPlatformBalanceOwner(profileID: "chrome:A", token: " token-value "))
        #expect(owner == DeepSeekPlatformBalanceOwner(profileID: "chrome:A", token: "token-value"))
        #expect(owner != DeepSeekPlatformBalanceOwner(profileID: "chrome:B", token: "token-value"))
        #expect(owner != DeepSeekPlatformBalanceOwner(profileID: "chrome:A", token: "Cookie:token-value"))
        #expect(owner != DeepSeekPlatformBalanceOwner(profileID: "chrome:A", token: "\"token-value\""))
        #expect(owner.tokenDigest.count == 64)
        #expect(!owner.tokenDigest.contains("token-value"))
        #expect(DeepSeekPlatformBalanceOwner(profileID: "", token: "token") == nil)
        #expect(DeepSeekPlatformBalanceOwner(profileID: "chrome:A", token: " ") == nil)
    }

    @Test
    func `browser balance ownership survives live copies but cannot be decoded`() async throws {
        let resolution = await Fixture.successfulResolution(candidate: Fixture.candidateA, cache: .init())
        let snapshot = try await Fixture.project(resolution)
        let owner = try #require(snapshot.deepseekPlatformBalanceOwner)
        #expect(owner.profileID == Fixture.candidateA.id)
        let copies = [
            snapshot.with(details: []),
            snapshot.with(primary: snapshot.primary, secondary: nil),
            snapshot.withIdentity(snapshot.identity),
            snapshot.withAccountLabel("Renamed account", for: .deepseek),
            snapshot.withDataConfidence(.percentOnly),
            snapshot.withoutDeepSeekDetailedUsage(),
            snapshot.scoped(to: .deepseek),
            snapshot.backfillingResetTimes(from: snapshot),
        ]
        for copy in copies {
            #expect(copy.deepseekPlatformBalanceOwner == owner)
            #expect(copy.updatedAt == snapshot.updatedAt)
        }
        let encoded = try JSONEncoder().encode(snapshot)
        var json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(json["deepseekPlatformBalanceOwner"] == nil)
        let encodedText = try #require(String(data: encoded, encoding: .utf8))
        #expect(!encodedText.contains(owner.tokenDigest))
        json["deepseekPlatformBalanceOwner"] = ["profileID": owner.profileID, "tokenDigest": owner.tokenDigest]
        let decoded = try JSONDecoder().decode(UsageSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.deepseekPlatformBalanceOwner == nil)
        let profileCopy = Fixture.balance().toUsageSnapshot().withoutDeepSeekDetailedUsage()
            .preservingDeepSeekPlatformProfiles(from: snapshot)
        #expect(profileCopy.deepseekPlatformProfiles == snapshot.deepseekPlatformProfiles)
        #expect(profileCopy.deepseekPlatformBalanceOwner == nil)
    }

    @Test(arguments: [false, true])
    func `API balance never acquires the optional browser balance owner`(enrichmentFails: Bool) async throws {
        let cache = DeepSeekPlatformValidationCache(validityTTL: 0)
        let successful = await Fixture.successfulResolution(candidate: Fixture.candidateA, cache: cache)
        #expect(successful.selectedBalance?.platformBalanceOwner != nil)
        let resolution = if enrichmentFails {
            await Fixture.failedResolution(candidates: [Fixture.candidateA], cache: cache)
        } else {
            successful
        }
        let snapshot = try await DeepSeekProviderDescriptor._loadUsageForTesting(
            apiKey: "synthetic-api-key",
            context: Fixture.context(includeOptionalUsage: true),
            optionalResolutionJoinGrace: .seconds(1),
            operations: .init(
                fetchUsage: { _, _, _ in Fixture.balance(19) },
                resolveAutomaticSession: { _, _, _, _, _, _ in resolution }))
        #expect(snapshot.deepseekPlatformBalanceOwner == nil)
        #expect(snapshot.primary?.resetDescription?.contains("19.00") == true)
    }

    @Test(arguments: [URLError.Code.badURL, .secureConnectionFailed])
    func `unsupported URL failures cannot retain even the matching owner`(code: URLError.Code) async throws {
        let cache = DeepSeekPlatformValidationCache(validityTTL: 0)
        let prior = try await Fixture.project(Fixture.successfulResolution(candidate: Fixture.candidateA, cache: cache))
        let error = await Fixture.failure(Fixture.failedResolution(
            candidates: [Fixture.candidateA], cache: cache, error: ProviderTransportRegressionSupport.urlError(code)))
        #expect(!UsageStore.shouldPreservePriorSnapshot(after: error, hadPriorData: true, priorSnapshot: prior))
        #expect(!UsageStore.isStartupConnectivityRetryableError(error))
        #expect(UsageStore.refreshFailureHookStatus(error) == "network_error")
    }

    @Test(arguments: ProviderTransportRegressionSupport.codes)
    func `transport policy requires the live balance owner but retry classification does not`(
        code: URLError.Code) async throws
    {
        let cache = DeepSeekPlatformValidationCache(validityTTL: 0)
        let prior = try await Fixture.project(Fixture.successfulResolution(candidate: Fixture.candidateA, cache: cache))
        let error = await Fixture.failure(Fixture.failedResolution(
            candidates: [Fixture.candidateA], cache: cache, error: ProviderTransportRegressionSupport.urlError(code)))
        #expect(error is DeepSeekPlatformTransportError)
        #expect(error.localizedDescription == "DeepSeek network error: Chrome session resolution unavailable")
        #expect(UsageStore.shouldPreservePriorSnapshot(after: error, hadPriorData: true, priorSnapshot: prior))
        #expect(!UsageStore.shouldPreservePriorSnapshot(after: error, hadPriorData: true))
        #expect(!UsageStore.shouldPreservePriorSnapshot(after: error, hadPriorData: false, priorSnapshot: prior))
        #expect(UsageStore.isStartupConnectivityRetryableError(error) == (code != .cancelled))
        let expected = code == .cancelled ? "cancelled" : code == .timedOut ? "timeout" : "offline"
        #expect(UsageStore.refreshFailureHookStatus(error) == expected)
    }

    @Test(arguments: ["auth", "parse", "success"])
    func `latest selected validation result supersedes an earlier transport failure`(last: String) async {
        let cache = DeepSeekPlatformValidationCache(validityTTL: 0)
        _ = await Fixture.successfulResolution(candidate: Fixture.candidateA, cache: cache)
        let sequence = DeepSeekValidationSequence(last: last)
        let resolution = await DeepSeekPlatformTokenImporter._resolvePlatformBalanceForTesting(
            candidates: [Fixture.candidateA], cache: cache, validate: { _ in try await sequence.next() })
        #expect(await sequence.count == 2)
        #expect(resolution.selectedTransportError == nil)
        if last == "success" {
            #expect(resolution.selectedBalance?.totalBalance == 42)
            #expect(resolution.selectedBalance?.platformBalanceOwner?.profileID == Fixture.candidateA.id)
        } else {
            #expect(resolution.selectedBalance == nil)
        }
    }

    @Test(arguments: ["ambiguous", "explicit", "absent"])
    func `ambiguous and unavailable selections cannot assign another profile failure`(selection: String) async {
        let cache = DeepSeekPlatformValidationCache(validityTTL: 0)
        _ = await Fixture.successfulResolution(candidate: Fixture.candidateA, cache: cache)
        _ = await Fixture.successfulResolution(candidate: Fixture.candidateB, cache: cache)
        let resolution = await Fixture.failedResolution(
            candidates: selection == "explicit" ? [Fixture.candidateA] : [Fixture.candidateA, Fixture.candidateB],
            selectedProfileID: selection == "absent" ? "chrome:missing" : nil,
            requiresExplicitSelection: selection == "explicit",
            cache: cache)
        #expect(resolution.detailedUsageState == .profileSelectionRequired)
        #expect(resolution.selectedTransportError == nil)
    }

    @Test(arguments: [false, true])
    func `a saved cold profile keeps its failure when another candidate fails or succeeds`(
        otherSucceeds: Bool) async throws
    {
        let resolution = await DeepSeekPlatformTokenImporter._resolvePlatformBalanceForTesting(
            candidates: [Fixture.candidateA, Fixture.candidateB],
            selectedProfileID: Fixture.candidateA.id,
            cache: .init(),
            validate: { token in
                if otherSucceeds, token == Fixture.candidateB.token { return Fixture.balance(42) }
                throw ProviderTransportRegressionSupport.urlError(.timedOut)
            })
        let error = try #require(resolution.selectedTransportError)
        #expect(error.owner?.profileID == Fixture.candidateA.id)
        #expect(resolution.selectedBalance == nil)
        #expect(resolution.detailedUsageState == .unavailable)
        #expect(resolution.profiles.map(\.id) == (otherSucceeds ? [Fixture.candidateB.id] : []))
        let projectedError = await Fixture.failure(resolution)
        #expect(projectedError is DeepSeekPlatformTransportError)
        #expect(UsageStore.isStartupConnectivityRetryableError(projectedError))
        #expect(UsageStore.refreshFailureHookStatus(projectedError) == "timeout")
        #expect(!UsageStore.shouldPreservePriorSnapshot(after: projectedError, hadPriorData: false))
    }

    @Test(arguments: ["required", "missing", "automatic"], [false, true])
    func `cold unresolved selection does not borrow an arbitrary candidate failure`(
        selection: String,
        otherSucceeds: Bool) async
    {
        let resolution = await DeepSeekPlatformTokenImporter._resolvePlatformBalanceForTesting(
            candidates: [Fixture.candidateA, Fixture.candidateB],
            selectedProfileID: selection == "missing" ? "chrome:missing" :
                selection == "required" ? Fixture.candidateA.id : nil,
            requiresExplicitSelection: selection == "required",
            cache: .init(),
            validate: { token in
                if otherSucceeds, token == Fixture.candidateB.token || selection == "automatic" {
                    return Fixture.balance()
                }
                throw ProviderTransportRegressionSupport.urlError()
            })
        #expect(resolution.selectedTransportError == nil)
        #expect(resolution.selectedBalance == nil)
        if otherSucceeds { #expect(resolution.detailedUsageState == .profileSelectionRequired) }
    }

    @Test(arguments: [false, true])
    func `a rejected selected session cannot borrow retention authority from another successful profile`(
        otherSucceeds: Bool) async throws
    {
        let cache = DeepSeekPlatformValidationCache()
        await cache.record(candidate: Fixture.candidateA, status: false, now: Date())
        let resolution = await DeepSeekPlatformTokenImporter._resolvePlatformBalanceForTesting(
            candidates: [Fixture.candidateA, Fixture.candidateB],
            selectedProfileID: Fixture.candidateA.id,
            cache: cache,
            validate: { token in
                if otherSucceeds, token == Fixture.candidateB.token { return Fixture.balance(42) }
                throw ProviderTransportRegressionSupport.urlError()
            })
        #expect(resolution.selectedBalance == nil)
        #expect(resolution.profiles.map(\.id) == (otherSucceeds ? [Fixture.candidateB.id] : []))
        if otherSucceeds {
            #expect(resolution.selectedTransportError == nil)
            #expect(resolution.detailedUsageState == .profileSelectionRequired)
            let projected = try await Fixture.project(resolution)
            #expect(projected.primary == nil)
            #expect(projected.deepseekDetailedUsageState == .profileSelectionRequired)
            #expect(projected.deepseekPlatformProfiles.map(\.id) == [Fixture.candidateB.id])
            #expect(projected.deepseekPlatformBalanceOwner == nil)
        } else {
            let transport = try #require(resolution.selectedTransportError)
            #expect(transport.owner == nil)
            #expect(resolution.detailedUsageState == .unavailable)
            let error = await Fixture.failure(resolution)
            #expect(UsageStore.isStartupConnectivityRetryableError(error))
        }
    }

    @Test
    func `another profile finishing later cannot replace the selected failure`() async throws {
        let cache = DeepSeekPlatformValidationCache(validityTTL: 0)
        _ = await Fixture.successfulResolution(candidate: Fixture.candidateA, cache: cache)
        _ = await Fixture.successfulResolution(candidate: Fixture.candidateB, cache: cache)
        let resolution = await DeepSeekPlatformTokenImporter._resolvePlatformBalanceForTesting(
            candidates: [Fixture.candidateA, Fixture.candidateB],
            selectedProfileID: Fixture.candidateA.id,
            cache: cache,
            validate: { token in
                throw ProviderTransportRegressionSupport.urlError(token == Fixture.candidateA.token ? .dnsLookupFailed :
                    .secureConnectionFailed)
            })
        let error = try #require(resolution.selectedTransportError)
        #expect(error.owner?.profileID == Fixture.candidateA.id)
        #expect((error.underlyingError as NSError).code == NSURLErrorDNSLookupFailed)
    }

    @Test
    func `a browser deadline without observed ownership cannot preserve a prior balance`() async throws {
        let prior = try await Fixture.project(Fixture.successfulResolution(
            candidate: Fixture.candidateA,
            cache: .init()))
        let error = await ProviderTransportRegressionSupport.captureFailure {
            _ = try await DeepSeekProviderDescriptor._loadPlatformUsageForTesting(
                context: Fixture.context(),
                resolutionJoinGrace: .zero,
                operations: .init(
                    fetchUsage: { _, _, _ in Fixture.balance() },
                    resolveAutomaticSession: { _, _, _, _, _, _ in
                        try? await Task.sleep(for: .seconds(30))
                        return .init(profiles: [], selectedSummary: nil, detailedUsageState: .unavailable)
                    }))
        }
        #expect(error is DeepSeekPlatformTransportError)
        #expect(!UsageStore.shouldPreservePriorSnapshot(after: error, hadPriorData: true, priorSnapshot: prior))
        #expect(UsageStore.isStartupConnectivityRetryableError(error))
    }
}

actor DeepSeekValidationSequence {
    let last: String
    private(set) var count = 0

    init(last: String) { self.last = last }

    func next() throws -> DeepSeekUsageSnapshot {
        self.count += 1
        if self.count == 1 { throw ProviderTransportRegressionSupport.urlError() }
        switch self.last {
        case "auth": throw DeepSeekUsageError.invalidPlatformToken
        case "parse": throw DeepSeekUsageError.parseFailed("Synthetic invalid response")
        default: return DeepSeekTransportTestSupport.balance(42)
        }
    }
}
