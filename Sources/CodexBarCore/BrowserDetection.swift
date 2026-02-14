import Foundation
#if os(macOS)
import os.lock
import SweetCookieKit

/// Browser presence + profile heuristics.
///
/// Primary goal: avoid triggering unnecessary Keychain prompts (e.g. Chromium “Safe Storage”) by skipping
/// cookie imports from browsers that have no profile data on disk.
public final class BrowserDetection: Sendable {
    public static let defaultCacheTTL: TimeInterval = 60 * 10

    private let cache = OSAllocatedUnfairLock<[CacheKey: CachedResult]>(initialState: [:])
    private let homeDirectory: String
    private let cacheTTL: TimeInterval
    private let now: @Sendable () -> Date
    private let fileExists: @Sendable (String) -> Bool
    private let directoryContents: @Sendable (String) -> [String]?

    private struct CachedResult {
        let value: Bool
        let timestamp: Date
    }

    private enum ProbeKind: Int, Hashable, Sendable {
        case appInstalled
        case usableProfileData
        case usableCookieStore
    }

    private struct CacheKey: Hashable, Sendable {
        let browser: Browser
        let kind: ProbeKind
    }

    public init(
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
        cacheTTL: TimeInterval = BrowserDetection.defaultCacheTTL,
        now: @escaping @Sendable () -> Date = Date.init,
        fileExists: @escaping @Sendable (String) -> Bool = { path in FileManager.default.fileExists(atPath: path) },
        directoryContents: @escaping @Sendable (String) -> [String]? = { path in
            try? FileManager.default.contentsOfDirectory(atPath: path)
        })
    {
        self.homeDirectory = homeDirectory
        self.cacheTTL = cacheTTL
        self.now = now
        self.fileExists = fileExists
        self.directoryContents = directoryContents
    }

    public func isAppInstalled(_ browser: Browser) -> Bool {
        // Safari is always available on macOS.
        if browser == .safari {
            return true
        }

        return self.cachedBool(browser: browser, kind: .appInstalled) {
            self.detectAppInstalled(for: browser)
        }
    }

    /// Returns true when a cookie import attempt for this browser should be allowed.
    ///
    /// This is intentionally stricter than `isAppInstalled`: for Chromium browsers, we only return true
    /// when profile data exists (to avoid unnecessary Keychain prompts).
    public func isCookieSourceAvailable(_ browser: Browser) -> Bool {
        // We always allow Safari cookie attempts: no Keychain prompts, and it can still yield cookies
        // even if the on-disk location changes across macOS versions.
        if browser == .safari {
            return true
        }

        // For browsers that typically require keychain-backed decryption, ensure an actual cookie store exists.
        if self.requiresProfileValidation(browser) {
            return self.hasUsableCookieStore(browser)
        }

        return self.hasUsableProfileData(browser)
    }

    public func hasUsableProfileData(_ browser: Browser) -> Bool {
        self.cachedBool(browser: browser, kind: .usableProfileData) {
            self.detectUsableProfileData(for: browser)
        }
    }

    private func hasUsableCookieStore(_ browser: Browser) -> Bool {
        self.cachedBool(browser: browser, kind: .usableCookieStore) {
            self.detectUsableCookieStore(for: browser)
        }
    }

    public func clearCache() {
        self.cache.withLock { cache in
            cache.removeAll()
        }
    }

    // MARK: - Detection Logic

    private func cachedBool(browser: Browser, kind: ProbeKind, compute: () -> Bool) -> Bool {
        let now = self.now()
        let key = CacheKey(browser: browser, kind: kind)
        if let cached = self.cache.withLock({ cache in cache[key] }) {
            if now.timeIntervalSince(cached.timestamp) < self.cacheTTL {
                return cached.value
            }
        }

        let result = compute()
        self.cache.withLock { cache in
            cache[key] = CachedResult(value: result, timestamp: now)
        }
        return result
    }

    private func detectAppInstalled(for browser: Browser) -> Bool {
        let appPaths = self.applicationPaths(for: browser)
        for path in appPaths where self.fileExists(path) {
            return true
        }
        return false
    }

    private func detectUsableProfileData(for browser: Browser) -> Bool {
        guard let profilePath = self.profilePath(for: browser, homeDirectory: self.homeDirectory) else {
            return false
        }

        guard self.fileExists(profilePath) else {
            return false
        }

        // For Chromium-based browsers (and Firefox), verify actual profile data exists.
        if self.requiresProfileValidation(browser) {
            return self.hasValidProfileDirectory(for: browser, at: profilePath)
        }

        return true
    }

    private func detectUsableCookieStore(for browser: Browser) -> Bool {
        guard let profilePath = self.profilePath(for: browser, homeDirectory: self.homeDirectory) else {
            return false
        }

        guard self.fileExists(profilePath) else {
            return false
        }

        return self.hasValidCookieStore(for: browser, at: profilePath)
    }

    private func applicationPaths(for browser: Browser) -> [String] {
        guard let appName = self.applicationName(for: browser) else { return [] }

        return [
            "/Applications/\(appName).app",
            "\(self.homeDirectory)/Applications/\(appName).app",
        ]
    }

    private func applicationName(for browser: Browser) -> String? {
        browser.appBundleName
    }

    private func profilePath(for browser: Browser, homeDirectory: String) -> String? {
        if browser == .safari {
            return "\(homeDirectory)/Library/Cookies/Cookies.binarycookies"
        }

        if let relativePath = browser.chromiumProfileRelativePath {
            return "\(homeDirectory)/Library/Application Support/\(relativePath)"
        }

        if let geckoFolder = browser.geckoProfilesFolder {
            return "\(homeDirectory)/Library/Application Support/\(geckoFolder)/Profiles"
        }

        return nil
    }

    private func requiresProfileValidation(_ browser: Browser) -> Bool {
        // Chromium-based browsers should have Default/ or Profile*/ subdirectories
        if browser == .safari {
            return false
        }

        if browser == .helium {
            // Helium doesn't use the Default/Profile* pattern
            return false
        }

        if browser.usesGeckoProfileStore {
            // Firefox should have at least one *.default* directory
            return true
        }

        if browser.usesChromiumProfileStore {
            return true
        }

        return false
    }

    private func hasValidProfileDirectory(for browser: Browser, at profilePath: String) -> Bool {
        guard let contents = self.directoryContents(profilePath) else { return false }

        // Check for Default/ or Profile*/ subdirectories for Chromium browsers
        let hasProfile = contents.contains { name in
            name == "Default" || name.hasPrefix("Profile ") || name.hasPrefix("user-")
        }

        if browser.usesGeckoProfileStore {
            return contents.contains { name in
                name.contains(".default")
            }
        }

        return hasProfile
    }

    private func hasValidCookieStore(for browser: Browser, at profilePath: String) -> Bool {
        guard let contents = self.directoryContents(profilePath) else { return false }

        if browser.usesGeckoProfileStore {
            for name in contents where name.contains(".default") {
                let cookieDB = "\(profilePath)/\(name)/cookies.sqlite"
                if self.fileExists(cookieDB) {
                    return true
                }
            }
            return false
        }

        for name in contents where name == "Default" || name.hasPrefix("Profile ") || name.hasPrefix("user-") {
            let cookieDBLegacy = "\(profilePath)/\(name)/Cookies"
            let cookieDBNetwork = "\(profilePath)/\(name)/Network/Cookies"
            if self.fileExists(cookieDBLegacy) || self.fileExists(cookieDBNetwork) {
                return true
            }
        }

        return false
    }
}

#else

// MARK: - Non-macOS stub

public struct BrowserDetection: Sendable {
    public static let defaultCacheTTL: TimeInterval = 0

    public init(
        homeDirectory: String = "",
        cacheTTL: TimeInterval = BrowserDetection.defaultCacheTTL,
        now: @escaping @Sendable () -> Date = Date.init,
        fileExists: @escaping @Sendable (String) -> Bool = { _ in false },
        directoryContents: @escaping @Sendable (String) -> [String]? = { _ in nil })
    {
        _ = homeDirectory
        _ = cacheTTL
        _ = now
        _ = fileExists
        _ = directoryContents
    }

    public func isAppInstalled(_ browser: Browser) -> Bool {
        false
    }

    public func isCookieSourceAvailable(_ browser: Browser) -> Bool {
        false
    }

    public func hasUsableProfileData(_ browser: Browser) -> Bool {
        false
    }

    public func clearCache() {}
}

#endif
