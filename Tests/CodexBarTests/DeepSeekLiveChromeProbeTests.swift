import Foundation
import Testing
@testable import CodexBarCore

#if os(macOS)
struct DeepSeekLiveChromeProbeTests {
    @Test
    func `import chrome session and write config`() async throws {
        guard ProcessInfo.processInfo.environment["CODEXBAR_IMPORT_DEEPSEEK_SESSION"] == "1" else { return }

        let detection = BrowserDetection(cacheTTL: 0)
        let sessions = try DeepSeekCookieImporter
            .importSessions(browserDetection: detection) { print("import_log: \($0)") }
        guard let imported = sessions.first else {
            Issue.record("No Chrome DeepSeek sessions imported")
            return
        }
        let session = imported.session
        let cookieNames = session.cookieHeader?
            .split(separator: ";")
            .compactMap { $0.split(separator: "=").first?.trimmingCharacters(in: .whitespaces) } ?? []
        print("cookie_names=\(cookieNames)")
        print("has_auth_header=\(session.authorizationHeader != nil)")

        let payload = session.storagePayload
        guard !payload.isEmpty else {
            Issue.record("Imported session is empty")
            return
        }

        let configURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codexbar/config.json")
        let data = try Data(contentsOf: configURL)
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var providers = root["providers"] as? [[String: Any]]
        else {
            Issue.record("Could not parse config.json")
            return
        }

        guard let index = providers.firstIndex(where: { ($0["id"] as? String) == "deepseek" }) else {
            Issue.record("DeepSeek provider missing from config")
            return
        }

        var deepseek = providers[index]
        deepseek["cookieSource"] = "manual"
        deepseek["cookieHeader"] = payload
        providers[index] = deepseek
        root["providers"] = providers

        let out = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try out.write(to: configURL, options: .atomic)

        let parsed = try #require(DeepSeekCookieHeader.session(from: payload))
        let account = try await DeepSeekUsageFetcher.fetchWebAccount(session: parsed)
        guard account.summary != nil || account.identity != nil else {
            Issue.record("Imported session did not authenticate platform APIs")
            return
        }
        print("IMPORT_OK source=\(imported.sourceLabel) chars=\(payload.count) has_summary=\(account.summary != nil)")
    }
}
#endif
