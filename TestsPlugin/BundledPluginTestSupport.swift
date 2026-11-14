import Foundation
import Testing
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

    /// Decodes an `application/x-www-form-urlencoded` body, reading `+` as a space and rejecting duplicate keys.
    static func formFields(_ body: Data?) throws -> [String: String] {
        var fields: [String: String] = [:]
        let text = try #require(String(data: body ?? Data(), encoding: .utf8))
        for pair in text.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            #expect(parts.count == 2)
            guard parts.count == 2 else { continue }
            let key = try #require(String(parts[0]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding)
            let value = try #require(String(parts[1]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding)
            #expect(fields.updateValue(value, forKey: key) == nil)
        }
        return fields
    }

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

/// Counts calls from synchronous host callbacks, such as cookie invalidation, that cannot await an actor.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int {
        self.lock.withLock { self.count }
    }

    func increment() { self.lock.withLock { self.count += 1 } }
}
