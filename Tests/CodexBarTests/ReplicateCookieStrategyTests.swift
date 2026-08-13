import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct ReplicateCookieStrategyTests {
    #if os(macOS)
    @Test
    func `cookie importer uses Replicate billing domains`() {
        #expect(!ReplicateCookieImporter.cookieDomains.isEmpty)
        #expect(Set(ReplicateCookieImporter.cookieDomains) == Set(ReplicateBillingEndpoints.cookieDomains))

        let referenceDate = Date(timeIntervalSince1970: 1_700_000_000)
        let query = ReplicateCookieImporter.cookieQuery(referenceDate: referenceDate)
        #expect(query.domains == ReplicateCookieImporter.cookieDomains)
        #expect(query.includeExpired == false)
        #expect(query.referenceDate == referenceDate)
        guard case .exact = query.domainMatch else {
            Issue.record("Expected exact Replicate cookie-domain matching")
            return
        }
    }

    @Test
    func `session cookie predicate accepts Django sessionid`() throws {
        let sessionCookie = try #require(HTTPCookie(properties: [
            .domain: "replicate.com",
            .path: "/",
            .name: "sessionid",
            .value: "abc123",
            .secure: true,
        ]))
        #expect(ReplicateCookieImporter.hasSessionCookie([sessionCookie]))

        let csrfCookie = try #require(HTTPCookie(properties: [
            .domain: "replicate.com",
            .path: "/",
            .name: "csrftoken",
            .value: "token",
            .secure: true,
        ]))
        #expect(ReplicateCookieImporter.hasSessionCookie([sessionCookie, csrfCookie]))
    }

    @Test
    func `session cookie predicate rejects unrelated cookies`() throws {
        let unrelated = try #require(HTTPCookie(properties: [
            .domain: "replicate.com",
            .path: "/",
            .name: "tracking_id",
            .value: "xyz",
            .secure: true,
        ]))
        #expect(!ReplicateCookieImporter.hasSessionCookie([unrelated]))
    }
    #endif

    @Test
    func `resolveAccount reads account props from billing HTML`() throws {
        let html = """
        <html><body>
        <script type="application/json" id="react-component-props-billing-page">
        {"page":{"account":{"kind":"user","username":"demo-user"}}}
        </script>
        </body></html>
        """

        let account = try ReplicateUsageFetcher.resolveAccount(fromBillingHTML: html)
        #expect(account.kind == "user")
        #expect(account.username == "demo-user")
    }

    @Test
    func `resolveAccount finds nested account dictionary`() throws {
        let html = """
        <html><body>
        <script type="application/json" id="react-component-props-root">
        {"layout":{"nested":{"account":{"kind":"organization","username":"my-org"}}}}
        </script>
        </body></html>
        """

        let account = try ReplicateUsageFetcher.resolveAccount(fromBillingHTML: html)
        #expect(account.kind == "organization")
        #expect(account.username == "my-org")
    }

    @Test
    func `resolveAccount treats missing account props as invalid credentials`() {
        let html = """
        <html><body><script type="application/json" id="react-component-props-empty">{"page":{}}</script></body></html>
        """

        #expect {
            _ = try ReplicateUsageFetcher.resolveAccount(fromBillingHTML: html)
        } throws: { error in
            guard case ReplicateUsageError.invalidCredentials = error else { return false }
            return true
        }
    }

    @Test
    func `resolveAccount treats missing props scripts as invalid credentials`() {
        let html = "<html><body><h1>Sign in</h1></body></html>"

        #expect {
            _ = try ReplicateUsageFetcher.resolveAccount(fromBillingHTML: html)
        } throws: { error in
            guard case ReplicateUsageError.invalidCredentials = error else { return false }
            return true
        }
    }

    #if os(macOS)
    @Test
    func `descriptor defaults automatic cookie import to Chrome only`() {
        #expect(ProviderDescriptorRegistry.descriptor(for: .replicate).metadata.browserCookieOrder == [.chrome])
    }
    #endif

    @Test
    func `manual cookie source exempts Linux web CLI gate`() {
        let settings = ProviderSettingsSnapshot.make(
            replicate: ReplicateProviderSettings(cookieSource: .manual, manualCookieHeader: "sessionid=abc"))
        let descriptor = ProviderDescriptorRegistry.descriptor(for: .replicate)
        #expect(descriptor.cli.isBrowserSupportExempt(
            sourceMode: .auto,
            environment: [:],
            settings: settings))
    }
}
