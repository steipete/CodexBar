import Foundation
import SweetCookieKit
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
    func `deployment selection resolution reads environment with automatic fallback`() {
        #expect(HelmcodeDeploymentSelection.resolve(environment: [:]) == .auto)
        #expect(HelmcodeDeploymentSelection.resolve(environment: ["HELMCODE_DEPLOYMENT": "auto"]) == .auto)
        #expect(HelmcodeDeploymentSelection.resolve(environment: ["HELMCODE_DEPLOYMENT": "helmcode"]) == .helmcode)
        #expect(HelmcodeDeploymentSelection.resolve(environment: ["HELMCODE_DEPLOYMENT": "nan"]) == .nanBuilders)
        #expect(HelmcodeDeploymentSelection
            .resolve(environment: ["HELMCODE_DEPLOYMENT": "nan.builders"]) == .nanBuilders)
        #expect(HelmcodeDeploymentSelection
            .resolve(environment: ["HELMCODE_DEPLOYMENT": "nanbuilders"]) == .nanBuilders)
        #expect(HelmcodeDeploymentSelection.resolve(environment: ["HELMCODE_DEPLOYMENT": " nan "]) == .nanBuilders)
        #expect(HelmcodeDeploymentSelection.resolve(environment: ["HELMCODE_DEPLOYMENT": "unknown"]) == .auto)
    }

    @Test
    func `selection resolution prefers explicit environment over settings`() {
        let helmcodeSettings = HelmcodeProviderSettings(
            cookieSource: .auto,
            manualCookieHeader: nil,
            deploymentSelection: .helmcode)
        let nanSettings = HelmcodeProviderSettings(
            cookieSource: .auto,
            manualCookieHeader: nil,
            deploymentSelection: .nanBuilders)

        #expect(HelmcodeDeploymentResolver.resolveSelection(settings: nil, environment: [:]) == .auto)
        #expect(HelmcodeDeploymentResolver.resolveSelection(settings: helmcodeSettings, environment: [:]) == .helmcode)
        #expect(HelmcodeDeploymentResolver.resolveSelection(settings: nanSettings, environment: [:]) == .nanBuilders)
        #expect(HelmcodeDeploymentResolver.resolveSelection(
            settings: helmcodeSettings,
            environment: ["HELMCODE_DEPLOYMENT": "nan"]) == .nanBuilders)
        #expect(HelmcodeDeploymentResolver.resolveSelection(
            settings: nanSettings,
            environment: ["HELMCODE_DEPLOYMENT": ""]) == .nanBuilders)
        #expect(HelmcodeDeploymentResolver.resolveSelection(
            settings: nanSettings,
            environment: ["HELMCODE_DEPLOYMENT": "auto"]) == .auto)
    }

    @Test
    func `cookie capture host detection picks the pasted tenant`() {
        #expect(HelmcodeDeploymentResolver.detectTenant(fromCookieCapture: nil) == nil)
        #expect(HelmcodeDeploymentResolver.detectTenant(fromCookieCapture: "") == nil)
        #expect(HelmcodeDeploymentResolver.detectTenant(
            fromCookieCapture: "session=abc123") == nil)
        #expect(HelmcodeDeploymentResolver.detectTenant(
            fromCookieCapture: "curl 'https://cloud.nan.builders/dashboard' -H 'Cookie: session=abc'") ==
            .nanBuilders)
        #expect(HelmcodeDeploymentResolver.detectTenant(
            fromCookieCapture: "curl 'https://cloud-api.helmcode.com/api/usage/quota' -H 'Cookie: session=abc'") ==
            .helmcode)
        #expect(HelmcodeDeploymentResolver.detectTenant(
            fromCookieCapture: "curl 'https://example.com/login' -H 'Cookie: session=abc'") == nil)
    }

    @Test
    func `manual cookie tenant detection honors pinned selection and bare header fallback`() {
        let nanCapture = HelmcodeCredentialSelection(
            cookieHeader: "session=abc",
            rawCapture: "curl 'https://cloud.nan.builders/dashboard' -H 'Cookie: session=abc'",
            origin: .manual)
        let bare = HelmcodeCredentialSelection(cookieHeader: "session=abc", rawCapture: "session=abc", origin: .manual)
        #expect(HelmcodeDeploymentResolver.tenant(for: nanCapture, deploymentSelection: .auto) == .nanBuilders)
        #expect(HelmcodeDeploymentResolver.tenant(for: bare, deploymentSelection: .auto) == .helmcode)
        #expect(HelmcodeDeploymentResolver.tenant(for: nanCapture, deploymentSelection: .helmcode) == .helmcode)
        #expect(HelmcodeDeploymentResolver.tenant(
            for: HelmcodeCredentialSelection(cookieHeader: "s", rawCapture: "", origin: .environment),
            deploymentSelection: .nanBuilders) == .nanBuilders)
    }

    @Test
    func `dashboard deployment follows credential over cache with pinned override`() {
        // Automatic + manual NaN capture: NaN (the credential decides, beating the display cache).
        let nanManual = HelmcodeProviderSettings(
            cookieSource: .manual,
            manualCookieHeader: "curl 'https://cloud.nan.builders/dashboard' -H 'Cookie: nan_session=abc'",
            deploymentSelection: .auto)
        #expect(HelmcodeDeploymentResolver.dashboardDeployment(settings: nanManual, environment: [:]) == .nanBuilders)
        // Automatic, no credential, no cache: Helmcode Cloud fallback.
        let auto = HelmcodeProviderSettings(cookieSource: .auto, manualCookieHeader: nil, deploymentSelection: .auto)
        #expect(HelmcodeDeploymentResolver.dashboardDeployment(settings: auto, environment: [:]) == .helmcode)
        // A pinned selection wins over everything.
        let pinned = HelmcodeProviderSettings(
            cookieSource: .manual,
            manualCookieHeader: "curl 'https://cloud.nan.builders/dashboard' -H 'Cookie: nan_session=abc'",
            deploymentSelection: .helmcode)
        #expect(HelmcodeDeploymentResolver.dashboardDeployment(settings: pinned, environment: [:]) == .helmcode)
    }

    @Test
    func `nan builders deployment targets the community endpoints`() {
        let deployment = HelmcodeDeployment.nanBuilders
        #expect(deployment.displayName == "NaN Builders")
        #expect(deployment.sourceLabelName == "NaN Builders")
        #expect(HelmcodeDeployment.helmcode.sourceLabelName == "Helmcode Cloud")
        #expect(HelmcodeDeployment.nanBuilders.sourceLabelName == "NaN Builders")
        #expect(HelmcodeDeployment.helmcode.displayName == "Helmcode")
        #expect(deployment.quotaURL.absoluteString == "https://cloud-api.nan.builders/api/usage/quota")
        #expect(deployment.billingURL.absoluteString == "https://cloud-api.nan.builders/api/billing")
        #expect(deployment.creditsURL.absoluteString == "https://cloud-api.nan.builders/api/billing/credits")
        #expect(deployment.dashboardURL.absoluteString == "https://cloud.nan.builders")
        #expect(deployment.dashboardPageURL.absoluteString == "https://cloud.nan.builders/dashboard")
        #expect(deployment.cookieDomains == [
            "cloud-api.nan.builders",
            "cloud.nan.builders",
            "nan.builders",
        ])
        #expect(HelmcodeDeploymentSelection.allCases.map(\.displayName) == [
            "Automatic",
            "Helmcode Cloud",
            "NaN Builders",
        ])
    }
}
