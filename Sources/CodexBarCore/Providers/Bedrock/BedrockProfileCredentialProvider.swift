import Foundation

/// Resolves AWS credentials for a named profile by shelling out to the AWS CLI.
///
/// Uses `aws configure export-credentials`, which transparently resolves static
/// credentials, SSO sessions, assume-role chains, and `credential_process` profiles.
/// The runner is injected so tests never invoke a real `aws` binary.
struct BedrockProfileCredentialProvider {
    typealias Runner = @Sendable (
        _ arguments: [String],
        _ environment: [String: String]) async throws -> SubprocessResult

    let awsBinaryPath: String
    let run: Runner

    /// Production provider that drives the real `aws` binary via `SubprocessRunner`.
    static func live(awsBinaryPath: String) -> BedrockProfileCredentialProvider {
        BedrockProfileCredentialProvider(awsBinaryPath: awsBinaryPath) { arguments, environment in
            try await SubprocessRunner.run(
                binary: awsBinaryPath,
                arguments: arguments,
                environment: environment,
                timeout: 20,
                label: "aws-bedrock-credentials")
        }
    }

    func exportCredentials(
        profile: String,
        environment: [String: String] = [:]) async throws -> BedrockAWSSigner.Credentials
    {
        let result: SubprocessResult
        do {
            result = try await self.run(
                ["configure", "export-credentials", "--profile", profile, "--format", "process"],
                environment)
        } catch let SubprocessRunnerError.nonZeroExit(_, stderr) {
            throw Self.mapExportError(stderr: stderr, profile: profile)
        }

        guard let data = result.stdout.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessKeyID = Self.nonEmpty(json["AccessKeyId"] as? String),
              let secretAccessKey = Self.nonEmpty(json["SecretAccessKey"] as? String)
        else {
            throw BedrockUsageError.parseFailed("Could not parse AWS CLI export-credentials output")
        }

        return BedrockAWSSigner.Credentials(
            accessKeyID: accessKeyID,
            secretAccessKey: secretAccessKey,
            sessionToken: Self.nonEmpty(json["SessionToken"] as? String))
    }

    /// Returns the profile's configured region, or `nil` when unset.
    /// `aws configure get region` exits non-zero when the value is not configured,
    /// which is a normal case rather than an error.
    func resolveRegion(
        profile: String,
        environment: [String: String] = [:]) async throws -> String?
    {
        do {
            let result = try await self.run(
                ["configure", "get", "region", "--profile", profile],
                environment)
            return Self.nonEmpty(result.stdout)
        } catch SubprocessRunnerError.nonZeroExit {
            return nil
        }
    }

    static func mapExportError(stderr: String, profile: String) -> BedrockUsageError {
        let lower = stderr.lowercased()
        if lower.contains("sso login") || lower.contains("expired") || lower.contains("token has expired") {
            return .profileSessionExpired(profile)
        }
        let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return .apiError(trimmed.isEmpty ? "AWS CLI failed to export credentials" : trimmed)
    }

    private static func nonEmpty(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}
