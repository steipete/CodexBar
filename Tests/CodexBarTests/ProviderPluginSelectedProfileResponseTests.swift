import Foundation
import Testing
@testable import CodexBarCore

struct ProviderPluginSelectedProfileResponseTests {
    @Test(arguments: BundledPluginTestSupport.engines, [true, false])
    func `selected profiles hide response cookie headers while preserving ordinary headers`(
        engine: ProviderPluginEngineKind, selected: Bool) async throws
    {
        var source = ProviderPluginSelectedProfileTests.source.replacingOccurrences(
            of: "return {primary: {usedPercent: response.json.percent}};", with: """
            const exposed = response.headers['set-cookie'] !== undefined ||
              response.headers['set-cookie2'] !== undefined || response.headers.cookie !== undefined;
            if (exposed !== \(!selected)) throw new Error('Incorrect response cookie visibility');
            if (response.headers['x-safe'] !== 'visible') throw new Error('Missing ordinary response header');
            return {primary: {usedPercent: response.json.percent}};
            """)
        if !selected {
            source = source.replacingOccurrences(of: "store: 'selected-profile', ", with: "")
                .replacingOccurrences(of: "sessionURL: 'https://app.langdock.com/api/usage'", with: "")
        }
        let runtime = try ProviderPluginRuntime(
            source: source,
            transport: ProviderHTTPTransportHandler { request in
                let url = try #require(request.url)
                return try (Data(#"{"percent":42}"#.utf8), #require(HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [
                        "Set-Cookie": "auth_token=synthetic-rotated",
                        "Set-Cookie2": "auth_token=synthetic-rotated",
                        "Cookie": "auth_token=synthetic-echoed",
                        "X-Safe": "visible",
                    ])))
            },
            engine: engine)
        let record = try LangdockPluginTests.record()
        var settings = CookieProviderSettings()
        settings.selectedBrowserProfile = LangdockPluginTests.profile
        let broker = ProviderPluginCookieBroker(
            provider: .langdock,
            domains: runtime.manifest.cookieDomains,
            settings: settings,
            batches: { _, _ in nil },
            jarImporter: { batch in
                batch == 0 ? [.init(header: "", source: "Fixture", origin: "", records: [record])] : nil
            },
            policy: runtime.manifest.cookiePolicy,
            profileReader: { _ in [record] })
        let result = try await runtime.fetchResult(cookies: broker)
        #expect(result.usage.primary?.usedPercent == 42)
    }
}
