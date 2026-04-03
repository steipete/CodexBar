import Foundation

public struct DiscoveredCodexProfile: Identifiable, Equatable, Sendable {
    public let alias: String
    public let fileURL: URL
    public let accountEmail: String?
    public let accountID: String?
    public let plan: String?
    public let isActiveInCodex: Bool

    public init(
        alias: String,
        fileURL: URL,
        accountEmail: String?,
        accountID: String?,
        plan: String?,
        isActiveInCodex: Bool)
    {
        self.alias = alias
        self.fileURL = fileURL.standardizedFileURL
        self.accountEmail = accountEmail
        self.accountID = accountID
        self.plan = plan
        self.isActiveInCodex = isActiveInCodex
    }

    public var id: String {
        self.fileURL.path
    }
}

public enum CodexProfileStore {
    public static func discover(
        authFileURL: URL = CodexOAuthCredentialsStore.authFilePath(),
        fileManager: FileManager = .default) -> [DiscoveredCodexProfile]
    {
        let activeAuthURL = authFileURL.standardizedFileURL
        let activeProfile = self.profile(at: activeAuthURL, alias: "Current", fileManager: fileManager).map { profile in
            DiscoveredCodexProfile(
                alias: profile.alias,
                fileURL: profile.fileURL,
                accountEmail: profile.accountEmail,
                accountID: profile.accountID,
                plan: profile.plan,
                isActiveInCodex: true)
        }
        let activeCredentials = activeProfile.flatMap { self.credentials(at: $0.fileURL, fileManager: fileManager) }

        let profilesDirectory = activeAuthURL.deletingLastPathComponent().appendingPathComponent(
            "profiles",
            isDirectory: true)
        let candidates = (try? fileManager.contentsOfDirectory(
            at: profilesDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles])) ?? []

        var discovered = candidates
            .filter { $0.pathExtension.lowercased() == "json" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .compactMap { candidate -> DiscoveredCodexProfile? in
                let alias = candidate.deletingPathExtension().lastPathComponent
                guard var profile = self.profile(at: candidate, alias: alias, fileManager: fileManager) else {
                    return nil
                }
                profile = DiscoveredCodexProfile(
                    alias: profile.alias,
                    fileURL: profile.fileURL,
                    accountEmail: profile.accountEmail,
                    accountID: profile.accountID,
                    plan: profile.plan,
                    isActiveInCodex: self.matches(
                        self.credentials(at: candidate, fileManager: fileManager),
                        activeCredentials))
                return profile
            }

        if let activeProfile,
           discovered.contains(where: { $0.fileURL == activeProfile.fileURL }) == false
        {
            discovered.append(activeProfile)
        }

        return discovered.sorted {
            $0.alias.localizedStandardCompare($1.alias) == .orderedAscending
        }
    }

    public static func displayProfiles(
        authFileURL: URL = CodexOAuthCredentialsStore.authFilePath(),
        fileManager: FileManager = .default) -> [DiscoveredCodexProfile]
    {
        let discovered = self.discover(authFileURL: authFileURL, fileManager: fileManager)
        let authPath = authFileURL.standardizedFileURL.path
        guard discovered.contains(where: { $0.fileURL.path == authPath }) else {
            return discovered
        }

        let activeCredentials = self.credentials(at: authFileURL, fileManager: fileManager)
        let matchedSavedPath = discovered.first(where: { profile in
            profile.fileURL.path != authPath &&
                self.matches(self.credentials(at: profile.fileURL, fileManager: fileManager), activeCredentials)
        })?.fileURL.standardizedFileURL.path

        let visible = discovered.compactMap { profile -> DiscoveredCodexProfile? in
            if profile.fileURL.path == authPath, matchedSavedPath != nil {
                return nil
            }
            if profile.fileURL.path == authPath {
                return DiscoveredCodexProfile(
                    alias: "Live",
                    fileURL: profile.fileURL,
                    accountEmail: profile.accountEmail,
                    accountID: profile.accountID,
                    plan: profile.plan,
                    isActiveInCodex: true)
            }
            if profile.fileURL.path == matchedSavedPath {
                return DiscoveredCodexProfile(
                    alias: profile.alias,
                    fileURL: profile.fileURL,
                    accountEmail: profile.accountEmail,
                    accountID: profile.accountID,
                    plan: profile.plan,
                    isActiveInCodex: true)
            }
            return profile
        }

        return visible.sorted {
            $0.alias.localizedStandardCompare($1.alias) == .orderedAscending
        }
    }

    public static func profile(
        at url: URL,
        alias: String,
        fileManager: FileManager = .default) -> DiscoveredCodexProfile?
    {
        guard self.isSafeRegularFile(url, fileManager: fileManager),
              let data = try? Data(contentsOf: url),
              let credentials = try? CodexOAuthCredentialsStore.parse(data: data)
        else {
            return nil
        }

        let payload = credentials.idToken.flatMap(UsageFetcher.parseJWT)
        let authDict = payload?["https://api.openai.com/auth"] as? [String: Any]
        let profileDict = payload?["https://api.openai.com/profile"] as? [String: Any]
        let rawEmail = (payload?["email"] as? String) ?? (profileDict?["email"] as? String)
        let rawPlan = (authDict?["chatgpt_plan_type"] as? String) ?? (payload?["chatgpt_plan_type"] as? String)
        let accountID = credentials.accountId?.trimmingCharacters(in: .whitespacesAndNewlines)

        return DiscoveredCodexProfile(
            alias: alias,
            fileURL: url.standardizedFileURL,
            accountEmail: Self.cleaned(rawEmail),
            accountID: Self.cleaned(accountID),
            plan: Self.cleaned(rawPlan),
            isActiveInCodex: false)
    }

    private static func cleaned(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func credentials(at url: URL, fileManager: FileManager) -> CodexOAuthCredentials? {
        guard self.isSafeRegularFile(url, fileManager: fileManager),
              let data = try? Data(contentsOf: url)
        else {
            return nil
        }
        return try? CodexOAuthCredentialsStore.parse(data: data)
    }

    private static func matches(_ lhs: CodexOAuthCredentials?, _ rhs: CodexOAuthCredentials?) -> Bool {
        guard let lhs, let rhs else { return false }

        let lhsAccountID = self.cleaned(lhs.accountId)
        let rhsAccountID = self.cleaned(rhs.accountId)
        if let lhsAccountID, let rhsAccountID {
            return lhsAccountID == rhsAccountID
        }

        if let lhsIDToken = cleaned(lhs.idToken), let rhsIDToken = cleaned(rhs.idToken) {
            return lhsIDToken == rhsIDToken
        }

        return lhs.accessToken == rhs.accessToken && lhs.refreshToken == rhs.refreshToken
    }

    private static func isSafeRegularFile(_ url: URL, fileManager: FileManager) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true,
              values.isSymbolicLink != true
        else {
            return false
        }
        return fileManager.fileExists(atPath: url.path)
    }
}
