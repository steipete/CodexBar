import Foundation
import os.lock
import SweetCookieKit
import Testing
@testable import CodexBarCore

#if os(macOS)
@Suite(.serialized)
struct ClaudeWebBrowserFallbackTests {
    @Test
    func `chrome without a Claude session falls through to Safari`() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-browser-fallback-\(UUID().uuidString)", isDirectory: true)
        let chromeCookies = temp
            .appendingPathComponent("Library/Application Support/Google/Chrome/Default/Network/Cookies")
        try FileManager.default.createDirectory(
            at: chromeCookies.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: chromeCookies.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: temp) }

        let detection = BrowserDetection(
            homeDirectory: temp.path,
            cacheTTL: 0,
            fileExists: { path in
                if path == "/Applications/Google Chrome.app" {
                    return true
                }
                return FileManager.default.fileExists(atPath: path)
            },
            directoryContents: { path in
                try? FileManager.default.contentsOfDirectory(atPath: path)
            })
        let attempts = OSAllocatedUnfairLock(initialState: [Browser]())
        let browserOverride: @Sendable (Browser) throws -> ClaudeWebAPIFetcher.SessionKeyInfo? = { browser in
            attempts.withLock { $0.append(browser) }
            guard browser == .safari else { return nil }
            return ClaudeWebAPIFetcher.SessionKeyInfo(
                key: "sk-ant-safari-fallback",
                sourceLabel: "Safari",
                cookieCount: 1)
        }

        let sessionInfo = try BrowserCookieAccessGate.withShouldAttemptOverrideForTesting(true) {
            try KeychainAccessGate.withTaskOverrideForTesting(false) {
                try KeychainAccessPreflight.withCheckGenericPasswordOverrideForTesting { _, _ in .allowed } operation: {
                    try ProviderInteractionContext.$current.withValue(.background) {
                        try ClaudeWebSessionKeyImport.$browserOverrideForTesting.withValue(browserOverride) {
                            try ClaudeWebAPIFetcher.sessionKeyInfo(browserDetection: detection)
                        }
                    }
                }
            }
        }

        #expect(attempts.withLock { $0 } == [.chrome, .safari])
        #expect(sessionInfo.key == "sk-ant-safari-fallback")
        #expect(sessionInfo.sourceLabel == "Safari")
    }
}
#endif
