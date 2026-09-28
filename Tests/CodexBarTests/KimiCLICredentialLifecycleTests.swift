import Foundation
import Testing
@testable import CodexBarCore

struct KimiCLICredentialLifecycleTests {
    @Test
    func `fifteen minute CLI credential becomes stale at fourteen minutes without modifying the file`() throws {
        let home = try makeTemporaryKimiCodeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let issuedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let url = try writeKimiCodeCredential(
            home: home,
            accessToken: "synthetic-access",
            expiresAt: issuedAt.addingTimeInterval(900).timeIntervalSince1970)
        let original = try Data(contentsOf: url)
        let environment = ["KIMI_CODE_HOME": home.path]

        #expect(KimiSettingsReader.kimiCodeAccessToken(
            environment: environment, now: issuedAt.addingTimeInterval(839)) == "synthetic-access")
        for seconds in [840.0, 900.0] {
            #expect(KimiSettingsReader.kimiCodeAccessToken(
                environment: environment, now: issuedAt.addingTimeInterval(seconds)) == nil)
        }
        #expect(try Data(contentsOf: url) == original)
    }

    @Test
    func `CLI only auto mode explains renewal and the app API key setting`() async throws {
        let home = try makeTemporaryKimiCodeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let url = try writeKimiCodeCredential(
            home: home,
            accessToken: "synthetic-stale-access",
            refreshToken: "synthetic-rotating-refresh",
            expiresAt: Date().addingTimeInterval(30).timeIntervalSince1970)
        let original = try Data(contentsOf: url)
        let context = makeKimiFetchContext(
            sourceMode: .auto,
            environment: ["KIMI_CODE_HOME": home.path],
            settings: .make(kimi: .init(cookieSource: .off, manualCookieHeader: nil)))

        let outcome = await KimiProviderDescriptor.descriptor.fetchPlan.fetchOutcome(context: context, provider: .kimi)

        guard case let .failure(error) = outcome.result else {
            Issue.record("Expected stale CLI credential")
            return
        }
        #expect(error as? KimiAPIError == .expiredCodeCredential)
        #expect(error.localizedDescription.contains("Run kimi"))
        #expect(error.localizedDescription.contains("Settings > Providers > Kimi"))
        #expect(!error.localizedDescription.contains("synthetic-"))
        #expect(outcome.attempts.map(\.strategyID) == ["kimi.api", "kimi.cli", "kimi.web"])
        #expect(outcome.attempts.map(\.wasAvailable) == [false, true, false])
        #expect(try Data(contentsOf: url) == original)
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent("device_id").path))
    }

    @Test(arguments: [false, true])
    func `stale or rejected CLI credentials fall back to configured web auth without renewal`(
        rejectedByServer: Bool) async throws
    {
        let home = try makeTemporaryKimiCodeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let url = try writeKimiCodeCredential(
            home: home,
            accessToken: "api-bad",
            expiresAt: Date().addingTimeInterval(rejectedByServer ? 900 : -60).timeIntervalSince1970)
        let original = try Data(contentsOf: url)
        let transport = KimiOrderedCredentialTransport()
        let pipeline = ProviderFetchPipeline { _ in
            [
                KimiCLICredentialFetchStrategy(transport: transport, resolveWebAuthToken: { _ in nil }),
                KimiWebFetchStrategy(fetchUsage: { token, _ in
                    #expect(token == "synthetic-web")
                    return KimiUsageSnapshot(
                        weekly: .init(limit: "100", used: "25", remaining: "75", resetTime: nil),
                        rateLimit: nil,
                        updatedAt: Date())
                }),
            ]
        }
        let context = makeKimiFetchContext(
            sourceMode: .auto,
            environment: ["KIMI_CODE_HOME": home.path],
            settings: .make(kimi: .init(cookieSource: .manual, manualCookieHeader: "kimi-auth=synthetic-web")))

        let outcome = await pipeline.fetch(context: context, provider: .kimi)
        let result = try outcome.result.get()

        #expect(result.sourceLabel == "Kimi web cookie")
        #expect(result.usage.primary?.usedPercent == 25)
        #expect(outcome.attempts.map(\.strategyID) == ["kimi.cli", "kimi.web"])
        #expect(outcome.attempts.first?.errorDescription?.contains("Run kimi") == true)
        #expect(await transport.authorizationHeaders() == (rejectedByServer ? ["Bearer api-bad"] : []))
        #expect(try Data(contentsOf: url) == original)
    }

    @Test
    func `next fetch recovers when the CLI replaces its rotating credential`() async throws {
        let home = try makeTemporaryKimiCodeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        _ = try writeKimiCodeCredential(home: home, accessToken: "old-access", expiresAt: 1)
        let transport = KimiOrderedCredentialTransport()
        let strategy = KimiCLICredentialFetchStrategy(transport: transport)
        let context = makeKimiFetchContext(
            sourceMode: .auto,
            environment: ["KIMI_CODE_HOME": home.path],
            settings: .make(kimi: .init(cookieSource: .off, manualCookieHeader: nil)))
        await #expect(throws: KimiAPIError.expiredCodeCredential) { try await strategy.fetch(context) }

        let url = try writeKimiCodeCredential(
            home: home,
            accessToken: "cli-ok",
            refreshToken: "rotated-refresh",
            expiresAt: Date().addingTimeInterval(900).timeIntervalSince1970)
        let renewed = try Data(contentsOf: url)
        let result = try await strategy.fetch(context)

        #expect(result.sourceLabel == "Kimi Code CLI")
        #expect(result.usage.primary?.usedPercent == 25)
        #expect(await transport.authorizationHeaders() == ["Bearer cli-ok"])
        #expect(try Data(contentsOf: url) == renewed)
    }
}
