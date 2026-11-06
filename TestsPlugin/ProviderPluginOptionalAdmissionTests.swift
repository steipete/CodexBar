import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCore

struct ProviderPluginOptionalAdmissionTests {
    @Test(.timeLimit(.minutes(1)), arguments: BundledPluginTestSupport.engines)
    func `request admission waits do not spend the optional collection budget`(
        engine: ProviderPluginEngineKind) async throws
    {
        let (admissions, admitted) = AsyncStream<ContinuousClock.Instant>.makeStream()
        let (deadlines, deadlineObserved) = AsyncStream<Void>.makeStream()
        let (pending, release) = AsyncStream<Void>.makeStream()
        defer {
            admitted.finish()
            deadlineObserved.finish()
            release.finish()
        }
        let runtime = try ProviderPluginRuntime(
            source: """
            defineProvider({
              id: 'admission-fixture', name: 'Admission fixture', endpoints: ['https://example.test'], settings: [],
              async fetchUsage(ctx) {
                const response = await ctx.http.getWithOptional('https://example.test/primary',
                  'https://example.test/optional');
                return {identity: {loginMethod: response.optional?.bodyText || 'none'}};
              }
            });
            """,
            resourceBundle: CodexBarCoreResources.bundle,
            transport: ProviderHTTPTransportHandler { request in
                try (Data("ready".utf8), #require(HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)))
            },
            allowsDynamicID: true,
            contextOptions: ProviderPluginContextOptions(
                optionalRequestTimeoutSeconds: nil,
                waitForOptionalDeadline: { start, budget in
                    #expect(budget == .milliseconds(200))
                    var iterator = admissions.makeAsyncIterator()
                    let admittedAt = try #require(await iterator.next())
                    #expect(start >= admittedAt)
                    deadlineObserved.yield()
                    for await _ in pending {}
                    try Task.checkCancellation()
                },
                beforeHTTPAttempt: { request in
                    if request.url?.path == "/primary" {
                        admitted.yield(.now)
                    } else {
                        var deadline = deadlines.makeAsyncIterator()
                        #expect(await deadline.next() != nil)
                    }
                }),
            engine: engine)
        #expect(try await runtime.fetchUsage().identity?.loginMethod == "ready")
    }
}
