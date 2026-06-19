import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct BedrockSettingsReaderTests {
    @Test
    func `default auth mode is keys`() {
        #expect(BedrockSettingsReader.authMode(environment: [:]) == .keys)
    }

    @Test
    func `explicit profile auth mode wins`() {
        let env = ["CODEXBAR_BEDROCK_AUTH_MODE": "profile"]
        #expect(BedrockSettingsReader.authMode(environment: env) == .profile)
    }

    @Test
    func `AWS_PROFILE without keys implies profile mode`() {
        let env = ["AWS_PROFILE": "work"]
        #expect(BedrockSettingsReader.authMode(environment: env) == .profile)
        #expect(BedrockSettingsReader.profile(environment: env) == "work")
    }

    @Test
    func `AWS_PROFILE alongside static keys keeps keys mode`() {
        let env = [
            "AWS_PROFILE": "work",
            "AWS_ACCESS_KEY_ID": "AKIA",
            "AWS_SECRET_ACCESS_KEY": "secret",
        ]
        #expect(BedrockSettingsReader.authMode(environment: env) == .keys)
    }

    @Test
    func `hasCredentials in profile mode requires a profile name`() {
        let withProfile = ["CODEXBAR_BEDROCK_AUTH_MODE": "profile", "AWS_PROFILE": "work"]
        let withoutProfile = ["CODEXBAR_BEDROCK_AUTH_MODE": "profile"]
        #expect(BedrockSettingsReader.hasCredentials(environment: withProfile))
        #expect(!BedrockSettingsReader.hasCredentials(environment: withoutProfile))
    }

    @Test
    func `hasCredentials in keys mode requires both keys`() {
        let both = ["AWS_ACCESS_KEY_ID": "AKIA", "AWS_SECRET_ACCESS_KEY": "secret"]
        let onlyAccess = ["AWS_ACCESS_KEY_ID": "AKIA"]
        #expect(BedrockSettingsReader.hasCredentials(environment: both))
        #expect(!BedrockSettingsReader.hasCredentials(environment: onlyAccess))
    }
}
