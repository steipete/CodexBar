import Foundation

/// Resolves Bedrock signing credentials + region for the configured auth mode.
///
/// Shared by the main usage fetch (`BedrockAPIFetchStrategy`) and the daily
/// cost-history refresh (`CostUsageFetcher`) so both honor AWS-profile auth
/// identically instead of the history path silently requiring static keys.
enum BedrockCredentialResolver {
    struct Resolved {
        let credentials: BedrockAWSSigner.Credentials
        let region: String
    }

    static func resolve(
        environment: [String: String],
        resolveAWSBinary: ([String: String]) -> String? = { BinaryLocator.resolveAWSBinary(env: $0) },
        makeProvider: (String) -> BedrockProfileCredentialProvider = {
            BedrockProfileCredentialProvider.live(awsBinaryPath: $0)
        }) async throws -> Resolved
    {
        switch BedrockSettingsReader.authMode(environment: environment) {
        case .keys:
            guard let accessKeyID = BedrockSettingsReader.accessKeyID(environment: environment),
                  let secretAccessKey = BedrockSettingsReader.secretAccessKey(environment: environment)
            else {
                throw BedrockUsageError.missingCredentials
            }
            let credentials = BedrockAWSSigner.Credentials(
                accessKeyID: accessKeyID,
                secretAccessKey: secretAccessKey,
                sessionToken: BedrockSettingsReader.sessionToken(environment: environment))
            return Resolved(
                credentials: credentials,
                region: BedrockSettingsReader.region(environment: environment))

        case .profile:
            guard let profile = BedrockSettingsReader.profile(environment: environment) else {
                throw BedrockUsageError.missingCredentials
            }
            guard let awsBinary = resolveAWSBinary(environment) else {
                throw BedrockUsageError.awsCLINotFound
            }
            // Preserve inherited AWS credential env: assume-role profiles may use
            // `credential_source = Environment`, while signing still uses only the
            // credentials exported by the selected profile.
            let cliEnvironment = environment
            let provider = makeProvider(awsBinary)
            let credentials = try await provider.exportCredentials(profile: profile, environment: cliEnvironment)
            let region = try await Self.resolveRegion(
                provider: provider,
                profile: profile,
                environment: cliEnvironment)
            return Resolved(credentials: credentials, region: region)
        }
    }

    private static func resolveRegion(
        provider: BedrockProfileCredentialProvider,
        profile: String,
        environment: [String: String]) async throws -> String
    {
        if let explicit = BedrockSettingsReader.cleaned(environment[BedrockSettingsReader.regionKeys[0]])
            ?? BedrockSettingsReader.cleaned(environment[BedrockSettingsReader.regionKeys[1]])
        {
            return explicit
        }
        if let derived = try await provider.resolveRegion(profile: profile, environment: environment) {
            return derived
        }
        return BedrockSettingsReader.defaultRegion
    }
}
