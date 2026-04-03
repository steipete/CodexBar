import CryptoKit
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

    public var selection: CodexProfileSelection {
        CodexProfileSelection(
            alias: self.alias,
            profilePath: self.fileURL.path,
            accountEmail: self.accountEmail,
            accountID: self.accountID,
            plan: self.plan)
    }

    public var tokenAccount: ProviderTokenAccount {
        ProviderTokenAccount(
            id: Self.stableUUID(seed: self.accountID ?? self.accountEmail ?? self.fileURL.path),
            label: self.alias,
            token: self.fileURL.path,
            addedAt: 0,
            lastUsed: nil)
    }

    private static func stableUUID(seed: String) -> UUID {
        let digest = SHA256.hash(data: Data(seed.utf8))
        let bytes = Array(digest.prefix(16))
        let uuidBytes = uuid_t(
            bytes[0],
            bytes[1],
            bytes[2],
            bytes[3],
            bytes[4],
            bytes[5],
            bytes[6],
            bytes[7],
            bytes[8],
            bytes[9],
            bytes[10],
            bytes[11],
            bytes[12],
            bytes[13],
            bytes[14],
            bytes[15])
        return UUID(uuid: uuidBytes)
    }
}

public enum CodexProfileStore {
    public static func discover(
        authFileURL: URL = CodexOAuthCredentialsStore.authFilePath(),
        fileManager: FileManager = .default) -> [DiscoveredCodexProfile]
    {
        let activeAuthURL = authFileURL
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

        let profilesDirectory = activeAuthURL.deletingLastPathComponent().appendingPathComponent("profiles")
        let candidates = (try? fileManager.contentsOfDirectory(
            at: profilesDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles])) ?? []

        var discovered: [DiscoveredCodexProfile] = candidates
            .filter { $0.pathExtension.lowercased() == "json" }
            .sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending })
            .compactMap { candidate in
                let alias = candidate.deletingPathExtension().lastPathComponent
                guard var profile = self.profile(at: candidate, alias: alias, fileManager: fileManager) else {
                    return nil
                }
                let credentials = self.credentials(at: candidate, fileManager: fileManager)
                profile = DiscoveredCodexProfile(
                    alias: profile.alias,
                    fileURL: profile.fileURL,
                    accountEmail: profile.accountEmail,
                    accountID: profile.accountID,
                    plan: profile.plan,
                    isActiveInCodex: self.matches(credentials, activeCredentials))
                return profile
            }

        if let activeProfile,
           discovered.contains(where: {
               $0.fileURL.standardizedFileURL == activeProfile.fileURL.standardizedFileURL
           }) == false
        {
            discovered.append(activeProfile)
        }

        return discovered.sorted { lhs, rhs in
            lhs.alias.localizedStandardCompare(rhs.alias) == .orderedAscending
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
        let email = rawEmail?.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawPlan = (authDict?["chatgpt_plan_type"] as? String) ?? (payload?["chatgpt_plan_type"] as? String)
        let plan = rawPlan?.trimmingCharacters(in: .whitespacesAndNewlines)
        let accountID = credentials.accountId?.trimmingCharacters(in: .whitespacesAndNewlines)

        return DiscoveredCodexProfile(
            alias: alias,
            fileURL: url.standardizedFileURL,
            accountEmail: email?.isEmpty == false ? email : nil,
            accountID: accountID?.isEmpty == false ? accountID : nil,
            plan: plan?.isEmpty == false ? plan : nil,
            isActiveInCodex: false)
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

        return visible.sorted { lhs, rhs in
            lhs.alias.localizedStandardCompare(rhs.alias) == .orderedAscending
        }
    }

    public static func selectedDisplayProfile(
        selectedPath: String?,
        authFileURL: URL = CodexOAuthCredentialsStore.authFilePath(),
        fileManager: FileManager = .default) -> DiscoveredCodexProfile?
    {
        let displayed = self.displayProfiles(authFileURL: authFileURL, fileManager: fileManager)
        if let selectedPath {
            let standardizedPath = URL(fileURLWithPath: selectedPath).standardizedFileURL.path
            if let exact = displayed.first(where: { $0.fileURL.path == standardizedPath }) {
                return exact
            }
            let authPath = authFileURL.standardizedFileURL.path
            if standardizedPath == authPath {
                return displayed.first(where: \.isActiveInCodex)
            }
        }
        return displayed.first(where: \.isActiveInCodex)
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
        return lhs.accessToken == rhs.accessToken &&
            lhs.refreshToken == rhs.refreshToken &&
            lhs.accountId == rhs.accountId
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
