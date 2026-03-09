import Foundation
import Testing
@testable import CodexBarCore

@Suite
struct OllamaUsageFetcherTests {
    @Test
    func attachesCookieForOllamaHosts() {
        #expect(OllamaUsageFetcher.shouldAttachCookie(to: URL(string: "https://ollama.com/settings")))
        #expect(OllamaUsageFetcher.shouldAttachCookie(to: URL(string: "https://www.ollama.com")))
        #expect(OllamaUsageFetcher.shouldAttachCookie(to: URL(string: "https://app.ollama.com/path")))
    }

    @Test
    func rejectsNonOllamaHosts() {
        #expect(!OllamaUsageFetcher.shouldAttachCookie(to: URL(string: "https://example.com")))
        #expect(!OllamaUsageFetcher.shouldAttachCookie(to: URL(string: "https://ollama.com.evil.com")))
        #expect(!OllamaUsageFetcher.shouldAttachCookie(to: nil))
    }

    @Test
    func manualModeWithoutValidHeaderThrowsNoSessionCookie() {
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
    func autoModeWithoutHeaderDoesNotForceManualError() throws {
        let resolved = try OllamaUsageFetcher.resolveManualCookieHeader(
            override: nil,
            manualCookieMode: false)
        #expect(resolved == nil)
    }

    @Test
    func manualModeWithoutRecognizedSessionCookieThrowsNoSessionCookie() {
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
    func manualModeWithRecognizedSessionCookieAcceptsHeader() throws {
        let resolved = try OllamaUsageFetcher.resolveManualCookieHeader(
            override: "next-auth.session-token.0=abc; theme=dark",
            manualCookieMode: true)
        #expect(resolved?.contains("next-auth.session-token.0=abc") == true)
    }

    @Test
    func retryPolicyRetriesOnlyForAuthErrors() {
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
    func cookieImporterDefaultsToChromeFirst() {
        #expect(OllamaCookieImporter.defaultPreferredBrowsers == [.chrome])
    }

    @Test
    func cookieSelectorSkipsSessionLikeNoiseAndFindsRecognizedCookie() throws {
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
    func cookieSelectorThrowsWhenNoRecognizedSessionCookieExists() {
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
    func cookieSelectorAcceptsChunkedNextAuthSessionTokenCookie() throws {
        let candidate = OllamaCookieImporter.SessionInfo(
            cookies: [Self.makeCookie(name: "next-auth.session-token.0", value: "chunk0")],
            sourceLabel: "Profile C")

        let selected = try OllamaCookieImporter.selectSessionInfo(from: [candidate])
        #expect(selected.sourceLabel == "Profile C")
    }

    @Test
    func cookieSelectorKeepsRecognizedCandidatesInOrder() throws {
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
    func cookieSelectorDoesNotFallbackWhenFallbackDisabled() {
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
    func cookieSelectorFallsBackToNonChromeCandidateWhenFallbackEnabled() throws {
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
