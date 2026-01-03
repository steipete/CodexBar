import Foundation
#if os(macOS)
import SweetCookieKit

/// Detects which browsers are installed to avoid unnecessary keychain prompts.
public final class BrowserDetection: Sendable {
    private nonisolated(unsafe) var cache: [Browser: CachedResult] = [:]

    private struct CachedResult {
        let isInstalled: Bool
        let timestamp: Date
    }

    public init() {}

    public func isInstalled(_ browser: Browser) -> Bool {
        // Safari is always available on macOS
        if browser == .safari {
            return true
        }

        if let cached = self.cache[browser] {
            return cached.isInstalled
        }

        let result = self.detectInstallation(for: browser)
        self.cache[browser] = CachedResult(isInstalled: result, timestamp: Date())
        return result
    }

    public func filterInstalled(_ browsers: [Browser]) -> [Browser] {
        browsers.filter { self.isInstalled($0) }
    }

    func clearCache() {
        self.cache.removeAll()
    }

    // MARK: - Detection Logic

    private func detectInstallation(for browser: Browser) -> Bool {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        let fm = FileManager.default

        // 1. Check application bundle paths
        let appPaths = self.applicationPaths(for: browser)
        for path in appPaths where fm.fileExists(atPath: path) {
            return true
        }

        // 2. Check profile directory (indicates past usage)
        if let profilePath = self.profilePath(for: browser, homeDirectory: homeDir) {
            if fm.fileExists(atPath: profilePath) {
                // For Chromium-based browsers, verify actual profile data exists
                if self.requiresProfileValidation(browser) {
                    return self.hasValidProfile(at: profilePath, fileManager: fm)
                }
                return true
            }
        }

        return false
    }

    private func applicationPaths(for browser: Browser) -> [String] {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        guard let appName = self.applicationName(for: browser) else { return [] }

        return [
            "/Applications/\(appName).app",
            "\(homeDir)/Applications/\(appName).app",
        ]
    }

    private func applicationName(for browser: Browser) -> String? {
        switch browser {
        case .safari:
            return "Safari"
        case .chrome:
            return "Google Chrome"
        case .chromeBeta:
            return "Google Chrome Beta"
        case .chromeCanary:
            return "Google Chrome Canary"
        case .arc:
            return "Arc"
        case .arcBeta:
            return "Arc Beta"
        case .arcCanary:
            return "Arc Canary"
        case .brave:
            return "Brave Browser"
        case .braveBeta:
            return "Brave Browser Beta"
        case .braveNightly:
            return "Brave Browser Nightly"
        case .edge:
            return "Microsoft Edge"
        case .edgeBeta:
            return "Microsoft Edge Beta"
        case .edgeCanary:
            return "Microsoft Edge Canary"
        case .vivaldi:
            return "Vivaldi"
        case .chromium:
            return "Chromium"
        case .firefox:
            return "Firefox"
        case .chatgptAtlas:
            return "ChatGPT Atlas"
        case .helium:
            return "Helium"
        @unknown default:
            return nil
        }
    }

    private func profilePath(for browser: Browser, homeDirectory: String) -> String? {
        switch browser {
        case .safari:
            return "\(homeDirectory)/Library/Cookies/Cookies.binarycookies"
        case .chrome:
            return "\(homeDirectory)/Library/Application Support/Google/Chrome"
        case .chromeBeta:
            return "\(homeDirectory)/Library/Application Support/Google/Chrome Beta"
        case .chromeCanary:
            return "\(homeDirectory)/Library/Application Support/Google/Chrome Canary"
        case .arc:
            return "\(homeDirectory)/Library/Application Support/Arc/User Data"
        case .arcBeta:
            return "\(homeDirectory)/Library/Application Support/Arc Beta/User Data"
        case .arcCanary:
            return "\(homeDirectory)/Library/Application Support/Arc Canary/User Data"
        case .brave:
            return "\(homeDirectory)/Library/Application Support/BraveSoftware/Brave-Browser"
        case .braveBeta:
            return "\(homeDirectory)/Library/Application Support/BraveSoftware/Brave-Browser-Beta"
        case .braveNightly:
            return "\(homeDirectory)/Library/Application Support/BraveSoftware/Brave-Browser-Nightly"
        case .edge:
            return "\(homeDirectory)/Library/Application Support/Microsoft Edge"
        case .edgeBeta:
            return "\(homeDirectory)/Library/Application Support/Microsoft Edge Beta"
        case .edgeCanary:
            return "\(homeDirectory)/Library/Application Support/Microsoft Edge Canary"
        case .vivaldi:
            return "\(homeDirectory)/Library/Application Support/Vivaldi"
        case .chromium:
            return "\(homeDirectory)/Library/Application Support/Chromium"
        case .firefox:
            return "\(homeDirectory)/Library/Application Support/Firefox/Profiles"
        case .chatgptAtlas:
            return "\(homeDirectory)/Library/Application Support/ChatGPT Atlas"
        case .helium:
            return "\(homeDirectory)/Library/Application Support/net.imput.helium"
        @unknown default:
            return nil
        }
    }

    private func requiresProfileValidation(_ browser: Browser) -> Bool {
        // Chromium-based browsers should have Default/ or Profile*/ subdirectories
        switch browser {
        case .chrome, .chromeBeta, .chromeCanary,
             .arc, .arcBeta, .arcCanary,
             .brave, .braveBeta, .braveNightly,
             .edge, .edgeBeta, .edgeCanary,
             .vivaldi, .chromium, .chatgptAtlas:
            return true
        case .firefox:
            // Firefox should have at least one *.default* directory
            return true
        case .helium:
            // Helium doesn't use the Default/Profile* pattern
            return false
        case .safari:
            return false
        @unknown default:
            return false
        }
    }

    private func hasValidProfile(at profilePath: String, fileManager: FileManager) -> Bool {
        guard let contents = try? fileManager.contentsOfDirectory(atPath: profilePath) else {
            return false
        }

        // Check for Default/ or Profile*/ subdirectories for Chromium browsers
        let hasProfile = contents.contains { name in
            name == "Default" || name.hasPrefix("Profile ") || name.hasPrefix("user-")
        }

        // For Firefox, check for .default directories
        if !hasProfile {
            let hasFirefoxProfile = contents.contains { name in
                name.contains(".default")
            }
            return hasFirefoxProfile
        }

        return hasProfile
    }
}

#else

// MARK: - Non-macOS stub

public actor BrowserDetection {
    public init() {}

    public func isInstalled(_ browser: Browser) -> Bool {
        true
    }

    public func filterInstalled(_ browsers: [Browser]) -> [Browser] {
        browsers
    }

    public func clearCache() {}
}

#endif
