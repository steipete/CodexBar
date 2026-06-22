import Crypto
import Foundation
#if os(macOS)
import Security
#endif

/// A Claude login discovered on this machine, expressed as a refreshable
/// `ClaudeCredentialSource` so the fetch path can read AND refresh it per
/// account (rather than all accounts sharing the single default login).
public struct DiscoveredClaudeAccount: Sendable, Equatable {
    public let source: ClaudeCredentialSource
    public let label: String
    public let configDirectory: String

    public init(source: ClaudeCredentialSource, label: String, configDirectory: String) {
        self.source = source
        self.label = label
        self.configDirectory = configDirectory
    }
}

/// Finds the Claude Code logins on this machine.
///
/// Source of truth is the **Keychain itself**: it enumerates the real
/// `Claude Code-credentials*` generic-password services (attributes only — no
/// token data, so it does not prompt), newest first, instead of guessing
/// service names from `~/.claude*` paths (which doesn't survive moved/renamed
/// config dirs). `~/.claude*` dirs are used only to give matching accounts a
/// friendly label and to pick up file-based credential stores.
///
/// The actual token read (and any Keychain prompt) happens later, per account,
/// in `ClaudeCredentialResolver` at fetch time — only for accounts shown.
public enum ClaudeAccountDiscovery {
    public static let defaultKeychainService = "Claude Code-credentials"
    private static let credentialsFileName = ".credentials.json"

    public static func discover(
        homeDirectory: String = NSHomeDirectory(),
        fileManager: FileManager = .default,
        maxAccounts: Int = 4) -> [DiscoveredClaudeAccount]
    {
        let configDirs = self.claudeConfigDirectories(homeDirectory: homeDirectory, fileManager: fileManager)
        let fileCredsDirs = configDirs.filter { dir in
            fileManager.fileExists(
                atPath: (dir as NSString).appendingPathComponent(self.credentialsFileName))
        }
        return self.assemble(
            homeDirectory: homeDirectory,
            configDirectories: configDirs,
            fileCredsDirectories: fileCredsDirs,
            keychainServicesNewestFirst: self.keychainServices(),
            maxAccounts: maxAccounts)
    }

    /// Pure assembly (no Keychain / filesystem) so it is unit-testable: pick the
    /// default store, any file-based stores, then the most-recently-used
    /// remaining Keychain services up to `maxAccounts`, deduped, each labelled
    /// from its matching `~/.claude*` dir when one exists.
    static func assemble(
        homeDirectory: String,
        configDirectories: [String],
        fileCredsDirectories: [String],
        keychainServicesNewestFirst: [String],
        maxAccounts: Int) -> [DiscoveredClaudeAccount]
    {
        let defaultClaudeDir = (homeDirectory as NSString).appendingPathComponent(".claude")
        // computed service -> friendly dir label (best-effort)
        var labelByService: [String: String] = [:]
        for dir in configDirectories {
            let service = self.keychainServiceName(
                forConfigDirectory: dir, defaultClaudeDirectory: defaultClaudeDir)
            labelByService[service] = self.label(
                forConfigDirectory: dir, defaultClaudeDirectory: defaultClaudeDir)
        }

        var seen = Set<String>()
        var accounts: [DiscoveredClaudeAccount] = []
        func add(_ source: ClaudeCredentialSource, _ label: String, _ dir: String) {
            guard seen.insert(source.encodedTokenValue()).inserted else { return }
            accounts.append(DiscoveredClaudeAccount(source: source, label: label, configDirectory: dir))
        }

        // 1) file-based stores (rare on macOS, but authoritative when present)
        for dir in fileCredsDirectories {
            let path = (dir as NSString).appendingPathComponent(self.credentialsFileName)
            add(.credentialsFile(path: path),
                self.label(forConfigDirectory: dir, defaultClaudeDirectory: defaultClaudeDir), dir)
        }

        // 2) the default Keychain login, if present
        if keychainServicesNewestFirst.contains(self.defaultKeychainService) {
            add(.keychainService(service: self.defaultKeychainService, account: nil), "Claude", defaultClaudeDir)
        }

        // 3) remaining Keychain services, most-recently-used first, capped
        for service in keychainServicesNewestFirst where service != self.defaultKeychainService {
            if accounts.count >= max(1, maxAccounts) { break }
            let label = labelByService[service] ?? self.shortSuffix(of: service)
            add(.keychainService(service: service, account: nil), label, "")
        }
        return accounts
    }

    /// Real `Claude Code-credentials*` Keychain services, newest first.
    /// Attributes-only query (no `kSecReturnData`) so it does not prompt.
    static func keychainServices() -> [String] {
        #if os(macOS)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let rows = result as? [[String: Any]]
        else {
            return []
        }
        var newestByService: [String: Date] = [:]
        for row in rows {
            guard let service = row[kSecAttrService as String] as? String,
                  service.hasPrefix(self.defaultKeychainService)
            else { continue }
            let modified = (row[kSecAttrModificationDate as String] as? Date)
                ?? (row[kSecAttrCreationDate as String] as? Date)
                ?? .distantPast
            if let existing = newestByService[service], existing >= modified { continue }
            newestByService[service] = modified
        }
        return newestByService.sorted { $0.value > $1.value }.map(\.key)
        #else
        return []
        #endif
    }

    /// Keychain service Claude Code uses for a config dir (used only for nice
    /// labels now): `~/.claude` → bare service; else
    /// `"Claude Code-credentials-" + sha256(absolutePath)[0..<8]`.
    public static func keychainServiceName(
        forConfigDirectory configDir: String,
        defaultClaudeDirectory: String) -> String
    {
        if configDir == defaultClaudeDirectory {
            return self.defaultKeychainService
        }
        return "\(self.defaultKeychainService)-\(self.sha256Hex(configDir).prefix(8))"
    }

    static func claudeConfigDirectories(
        homeDirectory: String,
        fileManager: FileManager) -> [String]
    {
        guard let entries = try? fileManager.contentsOfDirectory(atPath: homeDirectory) else {
            return []
        }
        return entries
            .filter { $0 == ".claude" || $0.hasPrefix(".claude-") }
            .map { (homeDirectory as NSString).appendingPathComponent($0) }
            .filter { path in
                var isDir: ObjCBool = false
                return fileManager.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
            }
            .sorted()
    }

    static func label(forConfigDirectory configDir: String, defaultClaudeDirectory: String) -> String {
        if configDir == defaultClaudeDirectory {
            return "Claude"
        }
        let name = (configDir as NSString).lastPathComponent
        if let range = name.range(of: ".claude-") {
            return String(name[range.upperBound...])
        }
        return name
    }

    static func shortSuffix(of service: String) -> String {
        let prefix = self.defaultKeychainService + "-"
        if service.hasPrefix(prefix) {
            return "Claude " + String(service.dropFirst(prefix.count))
        }
        return "Claude"
    }

    private static func sha256Hex(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
