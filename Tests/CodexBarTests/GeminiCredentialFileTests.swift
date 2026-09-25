import Foundation
import Testing
@testable import CodexBarCore

struct GeminiCredentialFileTests {
    @Test(arguments: ["oauth", "curl-header", "curl-body"])
    func `gemini secrets use private staging and cancellation leaves original bytes`(kind: String) throws {
        let fixture = try GeminiTestEnvironment()
        defer { fixture.cleanup() }
        try fixture.writeCredentials(accessToken: "original", refreshToken: "synthetic", expiry: Date(), idToken: nil)
        let oauthURL = fixture.homeURL.appendingPathComponent(".gemini/oauth_creds.json")
        let original = try Data(contentsOf: oauthURL)
        #expect(throws: CancellationError.self) {
            let inspectEmpty: @Sendable (URL) throws -> Void = { staged in
                let directory = staged.deletingLastPathComponent()
                let mode = try FileManager.default
                    .attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
                #expect(mode?.intValue == 0o700)
                let fileMode = try FileManager.default
                    .attributesOfItem(atPath: staged.path)[.posixPermissions] as? NSNumber
                #expect(fileMode?.intValue == 0o600)
                #expect(try Data(contentsOf: staged).isEmpty)
                throw CancellationError()
            }
            try CredentialFileWriter.$beforeWriteForTesting.withValue(inspectEmpty) {
                if kind == "oauth" {
                    try GeminiStatusProbe.updateStoredCredentials(
                        ["access_token": "replacement"], homeDirectory: fixture.homeURL.path)
                } else {
                    var request = URLRequest(url: URL(string: "https://synthetic.invalid")!)
                    request.setValue("Bearer synthetic", forHTTPHeaderField: "Authorization")
                    if kind == "curl-body" { request.httpBody = Data("refresh_token=synthetic".utf8) }
                    _ = try GeminiStatusProbe.writeCurlRequest(request, to: fixture.homeURL)
                }
            }
        }
        #expect(try Data(contentsOf: oauthURL) == original)
        #expect(!FileManager.default.fileExists(atPath: fixture.homeURL.appendingPathComponent("curl.conf").path))
        #expect(!FileManager.default.fileExists(atPath: fixture.homeURL.appendingPathComponent("body").path))
    }
}
