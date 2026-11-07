import Foundation
@testable import CodexBarCore

enum BundledPluginTestSupport {
    #if canImport(JavaScriptCore)
    static let engines: [ProviderPluginEngineKind] = [.quickJS, .javaScriptCore]
    #else
    static let engines: [ProviderPluginEngineKind] = [.quickJS]
    #endif

    static let timeout: TimeInterval = 300
    static let contextOptions = ProviderPluginContextOptions(
        optionalRequestTimeoutSeconds: nil,
        waitForOptionalDeadline: { _, _ in
            // Parser fixtures collect every response; deadline tests supply an explicit gate.
            try await Self.suspendUntilCancelled()
        },
        waitForHTTPDeadline: { _, _ in try await Self.suspendUntilCancelled() },
        sleepBeforeRetry: { _ in })

    static func suspendUntilCancelled() async throws {
        let (pending, release) = AsyncStream<Void>.makeStream()
        defer { release.finish() }
        for await _ in pending {}
        try Task.checkCancellation()
    }

    static func runtime(
        _ name: String,
        engine: ProviderPluginEngineKind,
        wallClock: Date? = nil,
        transport: any ProviderHTTPTransport,
        contextOptions: ProviderPluginContextOptions = Self.contextOptions,
        storageDirectory: URL? = nil) throws -> ProviderPluginRuntime
    {
        guard let bundle = CodexBarCoreResources.bundle,
              let url = bundle.url(forResource: name, withExtension: "js")
        else {
            throw ProviderPluginError.load("bundled plugin '\(name).js' was not found")
        }
        let source = try String(contentsOf: url, encoding: .utf8)
        let clock = wallClock.map { "Date.now = () => \($0.timeIntervalSince1970 * 1000);\n" } ?? ""
        return try ProviderPluginRuntime(
            source: clock + source,
            resourceBundle: bundle,
            transport: transport,
            timeout: Self.timeout,
            contextOptions: contextOptions,
            engine: engine,
            storageDirectory: storageDirectory)
    }
}
