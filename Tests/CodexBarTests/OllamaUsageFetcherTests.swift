import Foundation
import Testing
@testable import CodexBarCore

struct OllamaUsageFetcherTests {
    @Test
    func `attaches cookie for ollama hosts`() {
        #expect(OllamaUsageFetcher.shouldAttachCookie(to: URL(string: "https://ollama.com/settings")))
        #expect(OllamaUsageFetcher.shouldAttachCookie(to: URL(string: "https://www.ollama.com")))
        #expect(OllamaUsageFetcher.shouldAttachCookie(to: URL(string: "https://app.ollama.com/path")))
    }

    @Test
    func `rejects non ollama hosts`() {
        #expect(!OllamaUsageFetcher.shouldAttachCookie(to: URL(string: "https://example.com")))
        #expect(!OllamaUsageFetcher.shouldAttachCookie(to: URL(string: "https://ollama.com.evil.com")))
        #expect(!OllamaUsageFetcher.shouldAttachCookie(to: nil))
    }

    @Test
    func `manual mode without valid header throws no session cookie`() {
        do {
            _ = try OllamaUsageFetcher.resolveManualCookieHeader(
                override: nil,
                manualCookieMode: true)
            Issue.record("Expected OllamaUsageError.noSessionCookie")
        } catch OllamaUsageError.noSessionCookie {
            // expected
        } catch {
            Issue.record("Expected OllamaUsageError.noSessionCookie, got \(error)")
        }
    }

    @Test
    func `auto mode without header does not force manual error`() throws {
        let resolved = try OllamaUsageFetcher.resolveManualCookieHeader(
            override: nil,
            manualCookieMode: false)
        #expect(resolved == nil)
    }

    @Test
    func `manual mode without recognized session cookie throws no session cookie`() {
        do {
            _ = try OllamaUsageFetcher.resolveManualCookieHeader(
                override: "analytics_session_id=noise; theme=dark",
                manualCookieMode: true)
            Issue.record("Expected OllamaUsageError.noSessionCookie")
        } catch OllamaUsageError.noSessionCookie {
            // expected
        } catch {
            Issue.record("Expected OllamaUsageError.noSessionCookie, got \(error)")
        }
    }

    @Test
    func `manual mode with recognized session cookie accepts header`() throws {
        let resolved = try OllamaUsageFetcher.resolveManualCookieHeader(
            override: "next-auth.session-token.0=abc; theme=dark",
            manualCookieMode: true)
        #expect(resolved?.contains("next-auth.session-token.0=abc") == true)
    }

    @Test
    func `manual mode accepts secure session cookie header`() throws {
        let resolved = try OllamaUsageFetcher.resolveManualCookieHeader(
            override: "__Secure-session=abc; theme=dark",
            manualCookieMode: true)
        #expect(resolved?.contains("__Secure-session=abc") == true)
    }

    @Test
    func `retry policy retries only for auth errors`() {
        #expect(OllamaUsageFetcher.shouldRetryWithNextCookieCandidate(after: OllamaUsageError.invalidCredentials))
        #expect(OllamaUsageFetcher.shouldRetryWithNextCookieCandidate(after: OllamaUsageError.notLoggedIn))
        #expect(OllamaUsageFetcher.shouldRetryWithNextCookieCandidate(
            after: OllamaUsageFetcher.RetryableParseFailure.missingUsageData))
        #expect(!OllamaUsageFetcher.shouldRetryWithNextCookieCandidate(
            after: OllamaUsageError.parseFailed("Missing Ollama usage data.")))
        #expect(!OllamaUsageFetcher.shouldRetryWithNextCookieCandidate(
            after: OllamaUsageError.parseFailed("Unexpected parser mismatch.")))
        #expect(!OllamaUsageFetcher.shouldRetryWithNextCookieCandidate(after: OllamaUsageError.networkError("timeout")))
    }

    #if os(macOS)
    @Test
    func `cookie importer defaults to chrome first`() {
        #expect(OllamaCookieImporter.defaultPreferredBrowsers == [.chrome])
    }

    @Test
    func `cookie selector skips session like noise and finds recognized cookie`() throws {
        let first = OllamaCookieImporter.SessionInfo(
            cookies: [Self.makeCookie(name: "analytics_session_id", value: "noise")],
            sourceLabel: "Profile A")
        let second = OllamaCookieImporter.SessionInfo(
            cookies: [Self.makeCookie(name: "__Secure-next-auth.session-token", value: "auth")],
            sourceLabel: "Profile B")

        let selected = try OllamaCookieImporter.selectSessionInfo(from: [first, second])
        #expect(selected.sourceLabel == "Profile B")
    }

    @Test
    func `cookie selector throws when no recognized session cookie exists`() {
        let candidates = [
            OllamaCookieImporter.SessionInfo(
                cookies: [Self.makeCookie(name: "analytics_session_id", value: "noise")],
                sourceLabel: "Profile A"),
            OllamaCookieImporter.SessionInfo(
                cookies: [Self.makeCookie(name: "tracking_session", value: "noise")],
                sourceLabel: "Profile B"),
        ]

        do {
            _ = try OllamaCookieImporter.selectSessionInfo(from: candidates)
            Issue.record("Expected OllamaUsageError.noSessionCookie")
        } catch OllamaUsageError.noSessionCookie {
            // expected
        } catch {
            Issue.record("Expected OllamaUsageError.noSessionCookie, got \(error)")
        }
    }

    @Test
    func `cookie selector accepts chunked next auth session token cookie`() throws {
        let candidate = OllamaCookieImporter.SessionInfo(
            cookies: [Self.makeCookie(name: "next-auth.session-token.0", value: "chunk0")],
            sourceLabel: "Profile C")

        let selected = try OllamaCookieImporter.selectSessionInfo(from: [candidate])
        #expect(selected.sourceLabel == "Profile C")
    }

    @Test
    func `cookie selector accepts secure session cookie`() throws {
        let candidate = OllamaCookieImporter.SessionInfo(
            cookies: [Self.makeCookie(name: "__Secure-session", value: "auth")],
            sourceLabel: "Profile D")

        let selected = try OllamaCookieImporter.selectSessionInfo(from: [candidate])
        #expect(selected.sourceLabel == "Profile D")
    }

    @Test
    func `cookie selector keeps recognized candidates in order`() throws {
        let first = OllamaCookieImporter.SessionInfo(
            cookies: [Self.makeCookie(name: "session", value: "stale")],
            sourceLabel: "Chrome Profile A")
        let second = OllamaCookieImporter.SessionInfo(
            cookies: [Self.makeCookie(name: "next-auth.session-token.0", value: "valid")],
            sourceLabel: "Chrome Profile B")
        let noise = OllamaCookieImporter.SessionInfo(
            cookies: [Self.makeCookie(name: "analytics_session_id", value: "noise")],
            sourceLabel: "Chrome Profile C")

        let selected = try OllamaCookieImporter.selectSessionInfos(from: [first, noise, second])
        #expect(selected.map(\.sourceLabel) == ["Chrome Profile A", "Chrome Profile B"])
    }

    @Test
    func `cookie selector does not fallback when fallback disabled`() {
        let preferred = [
            OllamaCookieImporter.SessionInfo(
                cookies: [Self.makeCookie(name: "analytics_session_id", value: "noise")],
                sourceLabel: "Chrome Profile"),
        ]
        let fallback = [
            OllamaCookieImporter.SessionInfo(
                cookies: [Self.makeCookie(name: "next-auth.session-token.0", value: "chunk0")],
                sourceLabel: "Safari Profile"),
        ]

        do {
            _ = try OllamaCookieImporter.selectSessionInfoWithFallback(
                preferredCandidates: preferred,
                allowFallbackBrowsers: false,
                loadFallbackCandidates: { fallback })
            Issue.record("Expected OllamaUsageError.noSessionCookie")
        } catch OllamaUsageError.noSessionCookie {
            // expected
        } catch {
            Issue.record("Expected OllamaUsageError.noSessionCookie, got \(error)")
        }
    }

    @Test
    func `cookie selector falls back to non chrome candidate when fallback enabled`() throws {
        let preferred = [
            OllamaCookieImporter.SessionInfo(
                cookies: [Self.makeCookie(name: "analytics_session_id", value: "noise")],
                sourceLabel: "Chrome Profile"),
        ]
        let fallback = [
            OllamaCookieImporter.SessionInfo(
                cookies: [Self.makeCookie(name: "next-auth.session-token.0", value: "chunk0")],
                sourceLabel: "Safari Profile"),
        ]

        let selected = try OllamaCookieImporter.selectSessionInfoWithFallback(
            preferredCandidates: preferred,
            allowFallbackBrowsers: true,
            loadFallbackCandidates: { fallback })
        #expect(selected.sourceLabel == "Safari Profile")
    }

    private static func makeCookie(
        name: String,
        value: String,
        domain: String = "ollama.com") -> HTTPCookie
    {
        HTTPCookie(
            properties: [
                .name: name,
                .value: value,
                .domain: domain,
                .path: "/",
            ])!
    }
    #endif
}
