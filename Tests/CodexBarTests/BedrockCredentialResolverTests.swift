import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct BedrockCredentialResolverTests {
    private static let credentialsJSON = #"""
    {"Version":1,"AccessKeyId":"AKIAPROFILE","SecretAccessKey":"profile-secret","SessionToken":"profile-token"}
    """#

    /// Fake AWS CLI runner: returns exported credentials and a profile region.
    private func profileProvider(region: String = "ap-southeast-2") -> BedrockProfileCredentialProvider {
        BedrockProfileCredentialProvider(awsBinaryPath: "/usr/bin/aws") { arguments, _ in
            if arguments.contains("export-credentials") {
                return SubprocessResult(stdout: Self.credentialsJSON, stderr: "")
            }
            if arguments.contains("get") {
                return SubprocessResult(stdout: region + "\n", stderr: "")
            }
            return SubprocessResult(stdout: "", stderr: "")
        }
    }

    @Test
    func `keys mode resolves static credentials and region`() async throws {
        let env = [
            BedrockSettingsReader.accessKeyIDKey: "AKIAKEYS",
            BedrockSettingsReader.secretAccessKeyKey: "keys-secret",
            BedrockSettingsReader.regionKeys[0]: "us-west-2",
        ]
        let resolved = try await BedrockCredentialResolver.resolve(environment: env)
        #expect(resolved.credentials.accessKeyID == "AKIAKEYS")
        #expect(resolved.credentials.secretAccessKey == "keys-secret")
        #expect(resolved.region == "us-west-2")
    }

    @Test
    func `keys mode without credentials throws missingCredentials`() async {
        await #expect(throws: BedrockUsageError.missingCredentials) {
            try await BedrockCredentialResolver.resolve(environment: [:])
        }
    }

    @Test
    func `profile mode resolves credentials via the AWS CLI`() async throws {
        let env = [
            BedrockSettingsReader.authModeKey: "profile",
            BedrockSettingsReader.profileKey: "work",
        ]
        let resolved = try await BedrockCredentialResolver.resolve(
            environment: env,
            resolveAWSBinary: { _ in "/usr/bin/aws" },
            makeProvider: { _ in self.profileProvider() })
        #expect(resolved.credentials.accessKeyID == "AKIAPROFILE")
        #expect(resolved.credentials.sessionToken == "profile-token")
        // No explicit region in env, so it is derived from the profile.
        #expect(resolved.region == "ap-southeast-2")
    }

    @Test
    func `profile mode prefers explicit region over the profile region`() async throws {
        let env = [
            BedrockSettingsReader.authModeKey: "profile",
            BedrockSettingsReader.profileKey: "work",
            BedrockSettingsReader.regionKeys[0]: "eu-central-1",
        ]
        let resolved = try await BedrockCredentialResolver.resolve(
            environment: env,
            resolveAWSBinary: { _ in "/usr/bin/aws" },
            makeProvider: { _ in self.profileProvider() })
        #expect(resolved.region == "eu-central-1")
    }

    @Test
    func `profile mode without a profile name throws missingCredentials`() async {
        let env = [BedrockSettingsReader.authModeKey: "profile"]
        await #expect(throws: BedrockUsageError.missingCredentials) {
            try await BedrockCredentialResolver.resolve(
                environment: env,
                resolveAWSBinary: { _ in "/usr/bin/aws" },
                makeProvider: { _ in self.profileProvider() })
        }
    }

    @Test
    func `profile mode without the AWS CLI throws awsCLINotFound`() async {
        let env = [
            BedrockSettingsReader.authModeKey: "profile",
            BedrockSettingsReader.profileKey: "work",
        ]
        await #expect(throws: BedrockUsageError.awsCLINotFound) {
            try await BedrockCredentialResolver.resolve(
                environment: env,
                resolveAWSBinary: { _ in nil },
                makeProvider: { _ in self.profileProvider() })
        }
    }
}
