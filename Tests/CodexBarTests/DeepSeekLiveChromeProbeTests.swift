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

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-deepseek-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let configURL = tempDir.appendingPathComponent("config.json")
        let root: [String: Any] = [
            "providers": [[
                "id": "deepseek",
                "enabled": true,
                "cookieSource": "manual",
            ]],
        ]
        try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            .write(to: configURL, options: .atomic)

        var updatedRoot = root
        var providers = try #require(updatedRoot["providers"] as? [[String: Any]])
        var deepseek = try #require(providers.first)
        deepseek["cookieHeader"] = payload
        providers[0] = deepseek
        updatedRoot["providers"] = providers
        try JSONSerialization.data(withJSONObject: updatedRoot, options: [.prettyPrinted, .sortedKeys])
            .write(to: configURL, options: .atomic)

        let parsed = try #require(DeepSeekCookieHeader.session(from: payload))
        let account = try await DeepSeekUsageFetcher.fetchWebAccount(session: parsed)
        guard account.summary != nil || account.identity != nil else {
            Issue.record("Imported session did not authenticate platform APIs")
            return
        }
        print(
            "IMPORT_OK source=\(imported.sourceLabel) chars=\(payload.count) "
                + "has_summary=\(account.summary != nil) config=\(configURL.path)")
    }
}
#endif
