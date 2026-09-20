#if os(macOS)
import Foundation
import SweetCookieKit
import Testing
@testable import CodexBarCore

struct FirefoxLocalStorageProviderImporterTests {
    @Test
    func `browser local storage API preserves caller browser order`() {
        let recorder = Recorder()
        let api = self.api(recorder: recorder, profiles: [:])
        _ = api.profiles(
            for: "https://example.test",
            browsers: [.chrome, .firefox],
            using: self.detection,
            logger: { _ in })
        #expect(recorder.requests.count == 1)
        #expect(recorder.requests.first?.browsers == [.chrome, .firefox])
    }

    @Test
    func `DeepSeek requests Chrome then Firefox`() {
        let recorder = Recorder()
        let token = "deepseek_fixture_token_0123456789"
        let api = self.api(recorder: recorder, profiles: [
            "https://platform.deepseek.com": [
                self.profile("chrome:Default", "Chrome Default", ["userToken": token]),
                self.profile("firefox:alpha.default", "Firefox alpha.default", ["userToken": token]),
            ],
        ])
        let tokens = DeepSeekPlatformTokenImporter.importTokens(browserDetection: self.detection, localStorage: api)
        #expect(recorder.requests.first?.browsers == [.chrome, .firefox])
        #expect(tokens.map(\.id) == ["chrome:Default", "firefox:alpha.default"])
    }

    @Test
    func `Factory appends same-origin Firefox token after existing sources and deduplicates refresh`() {
        let recorder = Recorder()
        let refresh = "factory_refresh_fixture_0123456789"
        let access = "factory_access_fixture_0123456789"
        let api = self.api(recorder: recorder, profiles: [
            "https://app.factory.ai": [self.profile("firefox:alpha.default", "Firefox alpha.default", [
                "workos:refresh-token": refresh,
                "workos:access-token": access,
            ])],
            "https://auth.factory.ai": [self.profile("firefox:beta.default", "Firefox beta.default", [
                "workos:refresh-token": refresh,
            ])],
        ])
        let tokens = FactoryLocalStorageImporter.importWorkOSTokens(browserDetection: self.detection, localStorage: api)
        #expect(recorder.requests.map(\.origin) == ["https://app.factory.ai", "https://auth.factory.ai"])
        #expect(recorder.requests.allSatisfy { $0.browsers == [.firefox] })
        #expect(tokens.count == 1)
        #expect(tokens.first?.sourceLabel == "Firefox alpha.default")
        #expect(tokens.first?.accessToken == access)
    }

    @Test
    func `Devin appends Firefox sessions after Chromium sessions`() {
        let recorder = Recorder()
        let firefox = self.devinStorage(token: "auth1_firefox_fixture_0123456789")
        let api = self.api(recorder: recorder, profiles: [
            "https://app.devin.ai": [self.profile("firefox:alpha.default", "Firefox alpha.default", firefox)],
        ])
        // No synthetic Chromium directory is supplied, so the injected Firefox session remains the observable path.
        let sessions = DevinSessionImporter.importSessions(browserDetection: self.detection, localStorage: api)
        #expect(recorder.requests.first?.browsers == [.firefox])
        #expect(sessions.first?.sourceLabel == "Firefox alpha.default")
        #expect(sessions.first?.accessToken == "auth1_firefox_fixture_0123456789")
    }

    @Test
    func `Windsurf fallback appends deduplicated Firefox sessions after Chromium`() {
        let recorder = Recorder()
        let api = self.api(recorder: recorder, profiles: [
            "https://app.devin.ai": [
                self.profile("firefox:alpha.default", "Firefox alpha.default", [
                    "devin_session_token": "chromium-session",
                    "devin_auth1_token": "duplicate-auth",
                    "devin_account_id": "duplicate-account",
                    "devin_primary_org_id": "duplicate-org",
                ]),
                self.profile("firefox:beta.default", "Firefox beta.default", [
                    "devin_session_token": "firefox-session",
                    "devin_auth1_token": "firefox-auth",
                    "devin_account_id": "firefox-account",
                    "devin_primary_org_id": "firefox-org",
                ]),
            ],
        ])
        let chromium = WindsurfDevinSessionImporter.SessionInfo(
            session: WindsurfDevinSessionAuth(
                sessionToken: "chromium-session",
                auth1Token: "chromium-auth",
                accountID: "chromium-account",
                primaryOrgID: "chromium-org"),
            sourceLabel: "Chrome Default")
        let sessions = WindsurfDevinSessionImporter._fallbackSessionsForTesting(
            chromiumSessions: [chromium],
            browserDetection: self.detection,
            localStorage: api)
        #expect(sessions.map(\.sourceLabel) == ["Chrome Default", "Firefox beta.default (app.devin.ai)"])
        #expect(recorder.requests.map(\.origin).first == "https://app.devin.ai")
        #expect(recorder.requests.allSatisfy { $0.browsers == [.firefox] })
    }

    @Test
    func `Windsurf queries Firefox only after empty Chromium fallback`() {
        let recorder = Recorder()
        let storage = [
            "devin_session_token": "session-fixture",
            "devin_auth1_token": "auth-fixture",
            "devin_account_id": "account-fixture",
            "devin_primary_org_id": "org-fixture",
        ]
        let api = self.api(recorder: recorder, profiles: [
            "https://app.devin.ai": [self.profile("firefox:alpha.default", "Firefox alpha.default", storage)],
        ])
        let sessions = WindsurfDevinSessionImporter._fallbackSessionsForTesting(
            chromiumSessions: [],
            browserDetection: self.detection,
            localStorage: api)
        #expect(recorder.requests.map(\.origin).first == "https://app.devin.ai")
        #expect(recorder.requests.allSatisfy { $0.browsers == [.firefox] })
        #expect(sessions.first?.sourceLabel == "Firefox alpha.default (app.devin.ai)")
    }

    @Test
    func `MiniMax appends deduplicated Firefox tokens after Chromium candidates`() {
        let chromiumToken = String(repeating: "c", count: 64)
        let firefoxToken = String(repeating: "f", count: 64)
        let existing = [MiniMaxLocalStorageImporter.TokenInfo(
            accessToken: chromiumToken,
            groupID: nil,
            sourceLabel: "Chrome Default")]
        let tokens = MiniMaxLocalStorageImporter._appendFirefoxTokensForTesting(
            existing: existing,
            label: "Firefox alpha.default",
            entries: [BrowserLocalStorageAPI.Entry(
                key: "auth",
                value: #"{"access_token":"\#(chromiumToken)","id_token":"\#(firefoxToken)"}"#)])
        #expect(tokens.map(\.accessToken) == [chromiumToken, firefoxToken])
        #expect(tokens.map(\.sourceLabel) == ["Chrome Default", "Firefox alpha.default"])
    }

    @Test
    func `MiniMax Firefox local storage uses all declared origins and Firefox label`() {
        let recorder = Recorder()
        let token = String(repeating: "a", count: 64)
        let api = self.api(recorder: recorder, profiles: [
            "https://platform.minimax.io": [self.profile("firefox:alpha.default", "Firefox alpha.default", [
                "auth": #"{"access_token":"\#(token)"}"#,
            ])],
        ])
        let tokens = MiniMaxLocalStorageImporter.importAccessTokens(browserDetection: self.detection, localStorage: api)
        #expect(recorder.requests.map(\.origin) == [
            "https://platform.minimax.io", "https://www.minimax.io", "https://minimax.io",
            "https://platform.minimaxi.com", "https://www.minimaxi.com", "https://minimaxi.com",
        ])
        #expect(tokens.first?.sourceLabel == "Firefox alpha.default")
        #expect(tokens.first?.accessToken == token)
    }

    private var detection: BrowserDetection {
        BrowserDetection(homeDirectory: FileManager.default.temporaryDirectory.path)
    }

    private func api(
        recorder: Recorder,
        profiles: [String: [BrowserLocalStorageAPI.Profile]]) -> BrowserLocalStorageAPI
    {
        BrowserLocalStorageAPI { origin, browsers, _, _ in
            recorder.requests.append(Request(origin: origin, browsers: browsers))
            return profiles[origin] ?? []
        }
    }

    private func profile(
        _ id: String,
        _ label: String,
        _ values: [String: String]) -> BrowserLocalStorageAPI.Profile
    {
        BrowserLocalStorageAPI.Profile(
            id: id,
            label: label,
            entries: values.map { BrowserLocalStorageAPI.Entry(key: $0.key, value: $0.value) })
    }

    private func devinStorage(token: String) -> [String: String] {
        [
            "auth1_session": #"{"token":"\#(token)"}"#,
            "last-internal-org-for-external-org-v1-fixture": #""org_fixture12345""#,
        ]
    }

    private final class Recorder: @unchecked Sendable {
        var requests: [Request] = []
    }

    private struct Request: Equatable, Sendable {
        let origin: String
        let browsers: [Browser]
    }
}
#endif
