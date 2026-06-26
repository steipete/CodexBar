import Foundation
#if os(macOS)
@preconcurrency import AppKit
import Darwin
import os.lock
import SweetCookieKit

enum BrowserProfileAccessIssue: Equatable {
    case accessDenied
    case unreadable
}

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
    private let applicationURLs: @Sendable (String) -> [URL]
    private let profileAccessIssue: @Sendable (String) -> BrowserProfileAccessIssue?

    private struct CachedResult {
        let value: Bool
        let timestamp: Date
    }

    private enum ProbeKind: Int, Hashable {
        case appInstalled
        case usableProfileData
        case usableCookieStore
    }

    private struct CacheKey: Hashable {
        let browser: Browser
        let kind: ProbeKind
    }

    public convenience init(
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
        cacheTTL: TimeInterval = BrowserDetection.defaultCacheTTL,
        now: @escaping @Sendable () -> Date = Date.init,
        fileExists: @escaping @Sendable (String) -> Bool = { path in FileManager.default.fileExists(atPath: path) },
        directoryContents: @escaping @Sendable (String) -> [String]? = { path in
            try? FileManager.default.contentsOfDirectory(atPath: path)
        })
    {
        self.init(
            homeDirectory: homeDirectory,
            cacheTTL: cacheTTL,
            now: now,
            fileExists: fileExists,
            directoryContents: directoryContents,
            applicationURLs: Self.registeredApplicationURLs,
            profileAccessIssue: Self.probeProfileAccessIssue)
    }

    init(
        homeDirectory: String,
        cacheTTL: TimeInterval,
        now: @escaping @Sendable () -> Date,
        fileExists: @escaping @Sendable (String) -> Bool,
        directoryContents: @escaping @Sendable (String) -> [String]?,
        applicationURLs: @escaping @Sendable (String) -> [URL],
        profileAccessIssue: @escaping @Sendable (String) -> BrowserProfileAccessIssue?)
    {
        self.homeDirectory = homeDirectory
        self.cacheTTL = cacheTTL
        self.now = now
        self.fileExists = fileExists
        self.directoryContents = directoryContents
        self.applicationURLs = applicationURLs
        self.profileAccessIssue = profileAccessIssue
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
    /// This is intentionally stricter than `isAppInstalled`: non-Safari browsers must still be installed,
    /// and Chromium browsers must have profile data (to avoid stale sources and unnecessary Keychain prompts).
    public func isCookieSourceAvailable(_ browser: Browser) -> Bool {
        let homeURL = URL(fileURLWithPath: self.homeDirectory, isDirectory: true)
        guard BrowserCookieAccessGate.cookieStoreAccessDecision(homeDirectories: [homeURL]) == .allowed else {
            return false
        }

        // Safari does not need Keychain decryption and can still yield cookies if its storage path changes.
        if browser == .safari {
            return true
        }

        // Do not cache app presence here: uninstalling a browser must remove it from the next import attempt.
        guard self.detectAppInstalled(for: browser) else { return false }

        // For browsers that typically require keychain-backed decryption, ensure an actual cookie store exists.
        if self.requiresProfileValidation(browser) {
            return self.hasUsableCookieStore(browser)
        }

        return self.hasUsableProfileData(browser)
    }

    func cookieSourceProfileAccessIssue(_ browser: Browser) -> BrowserProfileAccessIssue? {
        let homeURL = URL(fileURLWithPath: self.homeDirectory, isDirectory: true)
        guard BrowserCookieAccessGate.cookieStoreAccessDecision(homeDirectories: [homeURL]) == .allowed,
              browser != .safari,
              self.detectAppInstalled(for: browser),
              let profilePath = self.profilePath(for: browser, homeDirectory: self.homeDirectory)
        else {
            return nil
        }

        return self.profileAccessIssue(profilePath)
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

        guard let appName = self.applicationName(for: browser) else { return false }
        return self.applicationURLs(appName).contains { self.fileExists($0.path) }
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

    private static func registeredApplicationURLs(named appName: String) -> [URL] {
        let probeURL = URL(string: "https://chatgpt.com")!
        let bundleName = "\(appName).app"
        return NSWorkspace.shared.urlsForApplications(toOpen: probeURL)
            .filter { $0.lastPathComponent == bundleName }
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
                name.range(of: ".default", options: [.caseInsensitive]) != nil
            }
        }

        return hasProfile
    }

    private func hasValidCookieStore(for browser: Browser, at profilePath: String) -> Bool {
        guard let contents = self.directoryContents(profilePath) else { return false }

        if browser.usesGeckoProfileStore {
            for name in contents where name.range(of: ".default", options: [.caseInsensitive]) != nil {
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

    private static func probeProfileAccessIssue(_ path: String) -> BrowserProfileAccessIssue? {
        do {
            _ = try FileManager.default.contentsOfDirectory(atPath: path)
            return nil
        } catch {
            if self.isPermissionError(error) {
                return .accessDenied
            }
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain,
               nsError.code == CocoaError.fileNoSuchFile.rawValue
            {
                return nil
            }
            return .unreadable
        }
    }

    private static func isPermissionError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain,
           nsError.code == CocoaError.fileReadNoPermission.rawValue
        {
            return true
        }
        if nsError.domain == NSPOSIXErrorDomain,
           nsError.code == Int(EACCES) || nsError.code == Int(EPERM)
        {
            return true
        }
        guard let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error else { return false }
        return Self.isPermissionError(underlying)
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
