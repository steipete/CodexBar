#if canImport(JavaScriptCore)
import Foundation
import JavaScriptCore
import ObjectiveC
import Testing
@testable import CodexBarCore

struct ProviderPluginMemoryTests {
    @Test
    func `QuickJS releases autoreleased host objects between refreshes`() async throws {
        let objects = TrackedObjects()
        let runtime = try ProviderPluginRuntime(source: Self.cookiePlugin, engine: .quickJS)

        for _ in 0..<20 {
            _ = try await runtime.fetchUsage(
                cookieSessionResolver: { _, _ in
                    .init(header: "fixture=synthetic", source: "Fixture", origin: "https://example.test")
                },
                cookieSessionValidator: { _, _ in objects.recordAutoreleasedString() })
        }
        // Wait for the worker to leave the final fetch, while keeping the runtime alive.
        _ = try runtime.globalType(of: "absentFixtureGlobal")
        withExtendedLifetime(runtime) {
            #expect(objects.capturedCount == 20)
            #expect(objects.liveCount == 0)
        }
    }

    @Test
    func `retiring JavaScriptCore engines releases their contexts`() throws {
        let bundle = try #require(CodexBarCoreResources.bundle)
        let url = try #require(bundle.url(forResource: "provider-plugin-prelude", withExtension: "js"))
        let prelude = try String(contentsOf: url, encoding: .utf8)
        let objects = TrackedObjects()

        for _ in 0..<20 {
            try autoreleasepool {
                let engine = try JavaScriptCoreProviderPluginEngine.make(
                    source: """
                    defineProvider({id: "synthetic", name: "Fixture", endpoints: ["https://example.test"],
                      settings: [], fetchUsage() { return {}; }});
                    """,
                    preludeSource: prelude,
                    transport: ProviderHTTPTransportHandler { _ in throw URLError(.unsupportedURL) },
                    responseSizeLimit: 1024,
                    enforcesUserResponsePolicy: false,
                    allowsDynamicID: false)
                let context = try #require(
                    Mirror(reflecting: engine).children.first { $0.label == "context" }?.value as? JSContext)
                objects.record(context)
            }
        }
        #expect(objects.liveCount == 0)
    }

    @Test
    func `completed JavaScriptCore fetches release retired runtimes`() async throws {
        let objects = TrackedObjects()
        for _ in 0..<20 {
            let runtime = try ProviderPluginRuntime(source: Self.cookiePlugin, engine: .javaScriptCore)
            objects.record(runtime)
            _ = try await runtime.fetchUsage(
                cookieSessionResolver: { _, _ in
                    .init(header: "fixture=synthetic", source: "Fixture", origin: "https://example.test")
                },
                cookieSessionValidator: { _, _ in })
        }
        // Let the existing fetch watchdogs release their temporary runtime references.
        try await Task.sleep(for: .seconds(ProviderPluginRuntime.defaultTimeout + 1))
        #expect(objects.capturedCount == 20)
        #expect(objects.liveCount == 0)
    }

    private static let cookiePlugin = """
    defineProvider({
      id: "synthetic", name: "Fixture", endpoints: ["https://example.test"], settings: [],
      capabilities: ["browser-cookies"], cookieDomains: ["example.test"],
      cookiePolicy: {selection: "request-url", cache: "validated-single-entry"},
      async fetchUsage(ctx) {
        const {value: session} = await ctx.browser.sessions("example.test").next();
        ctx.browser.acceptCookie("example.test", session);
        return {primary: {usedPercent: 42}};
      }
    });
    """

    private final class TrackedObjects: @unchecked Sendable {
        private final class WeakObject {
            weak var object: AnyObject?

            init(_ object: AnyObject) {
                self.object = object
            }
        }

        private let lock = NSLock()
        private var objects: [WeakObject] = []

        func record(_ object: AnyObject) {
            self.lock.withLock { self.objects.append(WeakObject(object)) }
        }

        func recordAutoreleasedString() {
            // Calling the Objective-C factory directly prevents ARC's return-value optimization
            // from removing the autorelease that this worker-lifetime regression needs to observe.
            typealias Factory = @convention(c) (AnyObject, Selector, NSString) -> Unmanaged<AnyObject>
            let selector = NSSelectorFromString("stringWithString:")
            let method = class_getClassMethod(NSMutableString.self, selector)!
            let factory = unsafeBitCast(method_getImplementation(method), to: Factory.self)
            self.record(factory(NSMutableString.self as AnyObject, selector, "fixture").takeUnretainedValue())
        }

        var capturedCount: Int {
            self.lock.withLock { self.objects.count }
        }

        var liveCount: Int {
            self.lock.withLock { self.objects.filter { $0.object != nil }.count }
        }
    }
}
#endif
