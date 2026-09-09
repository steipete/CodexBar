import Foundation

/// Wraps the Hugging Face billing plugin strategy with Swift-side bearer identity enrichment.
///
/// Identity display is normal API behavior, so this enrichment runs for explicit API modes (and
/// is reused by Auto) even when no browser wallet is available. The identity service caches one
/// successful `whoami-v2` result per bearer credential fingerprint for 12 hours, so at most one
/// bearer identity request is issued per credential cache miss.
struct HuggingFaceAPIUsageStrategy: ProviderFetchStrategy {
    let id: String
    let kind: ProviderFetchKind = .apiToken

    private let identityService: HuggingFaceIdentityService
    let inner: ScriptFetchStrategy

    init(
        inner: ScriptFetchStrategy,
        identityService: HuggingFaceIdentityService = .shared)
    {
        self.id = inner.id
        self.inner = inner
        self.identityService = identityService
    }

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        await self.inner.isAvailable(context)
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        var result = try await self.inner.fetch(context)

        if let token = HuggingFaceSettingsReader.token(environment: context.env) {
            do {
                let identity = try await self.identityService.identity(
                    bearerToken: token,
                    timeout: context.webTimeout)
                if let display = identity?.displayIdentitySnapshot(provider: .huggingface) {
                    result = result.replacingUsage(result.usage.withIdentity(display))
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch {
                // Identity display is optional; billing remains authoritative and useful.
            }
        }

        // Explicit API modes never perform browser-wallet work. The store treats this outcome as
        // a deterministic clearing signal for provider-level wallet state.
        return result.replacingWalletOutcome(.notAttempted)
    }

    func shouldFallback(on error: Error, context: ProviderFetchContext) -> Bool {
        self.inner.shouldFallback(on: error, context: context)
    }
}
