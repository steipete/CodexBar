import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct HelmcodeSettingsReaderTests {
    @Test
    func `settings reader accepts cookie headers and curl captures`() {
        #expect(HelmcodeSettingsReader.cookieHeader(environment: [
            "HELMCODE_COOKIE": " Cookie: session=fixture; tenant=test ",
        ]) == "session=fixture; tenant=test")
        #expect(HelmcodeSettingsReader.cookieHeader(environment: [
            "helmcode_cookie": "curl 'https://cloud.helmcode.com' -H 'Cookie: session=fixture'",
        ]) == "session=fixture")
        #expect(HelmcodeSettingsReader.cookieHeader(environment: [:]) == nil)
    }

    @Test
    func `deployment resolution reads environment with helmcode fallback`() {
        #expect(HelmcodeDeployment.resolve(environment: [:]) == .helmcode)
        #expect(HelmcodeDeployment.resolve(environment: ["HELMCODE_DEPLOYMENT": "helmcode"]) == .helmcode)
        #expect(HelmcodeDeployment.resolve(environment: ["HELMCODE_DEPLOYMENT": "nan"]) == .nanBuilders)
        #expect(HelmcodeDeployment.resolve(environment: ["HELMCODE_DEPLOYMENT": "nan.builders"]) == .nanBuilders)
        #expect(HelmcodeDeployment.resolve(environment: ["HELMCODE_DEPLOYMENT": "nanbuilders"]) == .nanBuilders)
        #expect(HelmcodeDeployment.resolve(environment: ["HELMCODE_DEPLOYMENT": " nan "]) == .nanBuilders)
        #expect(HelmcodeDeployment.resolve(environment: ["HELMCODE_DEPLOYMENT": "unknown"]) == .helmcode)
    }

    @Test
    func `strategy deployment prefers explicit environment over settings`() {
        let helmcodeSettings = HelmcodeProviderSettings(
            cookieSource: .auto,
            manualCookieHeader: nil,
            deployment: .helmcode)
        let nanSettings = HelmcodeProviderSettings(
            cookieSource: .auto,
            manualCookieHeader: nil,
            deployment: .nanBuilders)

        #expect(HelmcodeWebFetchStrategy.deployment(settings: nil, environment: [:]) == .helmcode)
        #expect(HelmcodeWebFetchStrategy.deployment(settings: helmcodeSettings, environment: [:]) == .helmcode)
        #expect(HelmcodeWebFetchStrategy.deployment(settings: nanSettings, environment: [:]) == .nanBuilders)
        #expect(HelmcodeWebFetchStrategy.deployment(
            settings: helmcodeSettings,
            environment: ["HELMCODE_DEPLOYMENT": "nan"]) == .nanBuilders)
        #expect(HelmcodeWebFetchStrategy.deployment(
            settings: nanSettings,
            environment: ["HELMCODE_DEPLOYMENT": ""]) == .nanBuilders)
    }

    @Test
    func `nan builders deployment targets the community endpoints`() {
        let deployment = HelmcodeDeployment.nanBuilders
        #expect(deployment.displayName == "NaN Builders")
        #expect(deployment.quotaURL.absoluteString == "https://cloud-api.nan.builders/api/usage/quota")
        #expect(deployment.creditsURL.absoluteString == "https://cloud-api.nan.builders/api/billing/credits")
        #expect(deployment.dashboardURL.absoluteString == "https://cloud.nan.builders")
        #expect(deployment.dashboardPageURL.absoluteString == "https://cloud.nan.builders/dashboard")
        #expect(deployment.cookieDomains == [
            "cloud-api.nan.builders",
            "cloud.nan.builders",
            "nan.builders",
        ])
    }
}
