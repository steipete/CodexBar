import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

public struct DeepSeekSettingsReader: Sendable {
    struct ProfileSelection: Sendable, Equatable {
        let profileID: String?
        let requiresExplicitSelection: Bool
    }

    public static let apiKeyEnvironmentKey = "DEEPSEEK_API_KEY"
    public static let apiKeyEnvironmentKeys = [Self.apiKeyEnvironmentKey, "DEEPSEEK_KEY"]
    public static let platformTokenEnvironmentKey = "DEEPSEEK_PLATFORM_TOKEN"
    public static let platformTokenEnvironmentKeys = [Self.platformTokenEnvironmentKey, "DEEPSEEK_USER_TOKEN"]
    public static let profileIDEnvironmentKey = "CODEXBAR_DEEPSEEK_PROFILE_ID"
    public static let profileScopeEnvironmentKey = "CODEXBAR_DEEPSEEK_PROFILE_SCOPE"
    private static let browserProfileScope = "browser:v1"

    public static func apiKey(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        self.value(for: self.apiKeyEnvironmentKeys, environment: environment)
    }

    public static func platformToken(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        self.value(for: self.platformTokenEnvironmentKeys, environment: environment)
    }

    static func scopedPlatformToken(
        environment: [String: String],
        selectedTokenAccountID: UUID?,
        apiKey: String?) -> String?
    {
        guard let token = self.platformToken(environment: environment),
              let expectedScope = self.profileScope(
                  selectedTokenAccountID: selectedTokenAccountID,
                  apiKey: apiKey)
        else { return nil }
        if self.profileScope(environment: environment) == expectedScope {
            return token
        }
        // Preserve unscoped legacy/manual sessions only as a standalone browser balance source.
        guard apiKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true else { return nil }
        return token
    }

    public static func profileID(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        self.value(for: [self.profileIDEnvironmentKey], environment: environment)
            .map(self.canonicalProfileID)
    }

    public static func profileScope(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        self.value(for: [self.profileScopeEnvironmentKey], environment: environment)
    }

    public static func profileScope(selectedTokenAccountID: UUID?, apiKey: String?) -> String? {
        guard let apiKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !apiKey.isEmpty else {
            return self.browserProfileScope
        }
        #if canImport(CryptoKit)
        let accountScope = selectedTokenAccountID?.uuidString.lowercased() ?? "environment"
        let input = "com.steipete.codexbar.deepseek-profile-scope.v1\0\(accountScope)\0\(apiKey)"
        let digest = SHA256.hash(data: Data(input.utf8))
        return "v1:" + digest.map { String(format: "%02x", $0) }.joined()
        #else
        return nil
        #endif
    }

    static func profileSelection(
        environment: [String: String],
        selectedTokenAccountID: UUID?,
        apiKey: String?) -> ProfileSelection
    {
        let profileID = self.profileID(environment: environment)
        let expectedScope = self.profileScope(selectedTokenAccountID: selectedTokenAccountID, apiKey: apiKey)
        let storedScope = self.profileScope(environment: environment)

        if let expectedScope, storedScope == expectedScope {
            return ProfileSelection(profileID: profileID, requiresExplicitSelection: false)
        }
        if apiKey == nil {
            return ProfileSelection(profileID: nil, requiresExplicitSelection: false)
        }
        return ProfileSelection(profileID: nil, requiresExplicitSelection: true)
    }

    public static func canonicalProfileID(_ rawValue: String) -> String {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.hasPrefix("/") else { return value }
        let profileName = URL(fileURLWithPath: value).lastPathComponent
        return profileName.isEmpty ? value : "chrome:\(profileName)"
    }

    private static func value(for keys: [String], environment: [String: String]) -> String? {
        for key in keys {
            guard let raw = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty
            else {
                continue
            }
            let cleaned = Self.cleaned(raw)
            if !cleaned.isEmpty {
                return cleaned
            }
        }
        return nil
    }

    private static func cleaned(_ raw: String) -> String {
        var value = raw
        if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
            (value.hasPrefix("'") && value.hasSuffix("'"))
        {
            value = String(value.dropFirst().dropLast())
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
