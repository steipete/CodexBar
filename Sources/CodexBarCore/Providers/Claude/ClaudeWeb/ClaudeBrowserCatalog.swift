import Foundation

#if os(macOS)

enum ClaudeBrowserEngine: String, CaseIterable, Sendable {
    case safari
    case chromium
    case firefox
    case webkit
}

enum ClaudeBrowserCatalogError: LocalizedError, Sendable {
    case resourceMissing(String)
    case readFailed(String)
    case decodeFailed(String)

    var errorDescription: String? {
        switch self {
        case let .resourceMissing(name):
            "Browser catalog resource missing: \(name)"
        case let .readFailed(details):
            "Browser catalog read failed: \(details)"
        case let .decodeFailed(details):
            "Browser catalog decode failed: \(details)"
        }
    }
}

struct ClaudeBrowserCatalog: Decodable, Sendable {
    struct BrowserEntry: Decodable, Sendable, Hashable {
        let id: String
        let displayName: String
        let bundleIDs: [String]
        let appNameHints: [String]
        let profileRootRelative: [String]
        let cookiePathPatterns: [String]
        let notes: String?

        init(
            id: String,
            displayName: String,
            bundleIDs: [String] = [],
            appNameHints: [String] = [],
            profileRootRelative: [String] = [],
            cookiePathPatterns: [String] = [],
            notes: String? = nil)
        {
            self.id = id
            self.displayName = displayName
            self.bundleIDs = bundleIDs
            self.appNameHints = appNameHints
            self.profileRootRelative = profileRootRelative
            self.cookiePathPatterns = cookiePathPatterns
            self.notes = notes
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.id = try container.decode(String.self, forKey: .id)
            self.displayName = try container.decode(String.self, forKey: .displayName)
            self.bundleIDs = try container.decodeIfPresent([String].self, forKey: .bundleIDs) ?? []
            self.appNameHints = try container.decodeIfPresent([String].self, forKey: .appNameHints) ?? []
            self.profileRootRelative =
                try container.decodeIfPresent([String].self, forKey: .profileRootRelative) ?? []
            self.cookiePathPatterns =
                try container.decodeIfPresent([String].self, forKey: .cookiePathPatterns) ?? []
            self.notes = try container.decodeIfPresent(String.self, forKey: .notes)
        }

        private enum CodingKeys: String, CodingKey {
            case id
            case displayName
            case bundleIDs
            case appNameHints
            case profileRootRelative
            case cookiePathPatterns
            case notes
        }
    }

    let chromium: [BrowserEntry]
    let firefox: [BrowserEntry]
    let webkit: [BrowserEntry]
    let safari: [BrowserEntry]

    static let orderedEngines: [ClaudeBrowserEngine] = [.safari, .chromium, .firefox, .webkit]

    static var empty: ClaudeBrowserCatalog {
        ClaudeBrowserCatalog(chromium: [], firefox: [], webkit: [], safari: [])
    }

    func entries(for engine: ClaudeBrowserEngine) -> [BrowserEntry] {
        switch engine {
        case .chromium:
            self.chromium
        case .firefox:
            self.firefox
        case .webkit:
            self.webkit
        case .safari:
            self.safari
        }
    }

    static func decode(from data: Data) throws -> ClaudeBrowserCatalog {
        do {
            return try JSONDecoder().decode(ClaudeBrowserCatalog.self, from: data)
        } catch {
            throw ClaudeBrowserCatalogError.decodeFailed(error.localizedDescription)
        }
    }

    static func loadFromBundle(resource: String = "browser-catalog") throws -> ClaudeBrowserCatalog {
        guard let url = Bundle.module.url(forResource: resource, withExtension: "json") else {
            throw ClaudeBrowserCatalogError.resourceMissing("\(resource).json")
        }
        do {
            let data = try Data(contentsOf: url)
            return try Self.decode(from: data)
        } catch let error as ClaudeBrowserCatalogError {
            throw error
        } catch {
            throw ClaudeBrowserCatalogError.readFailed(error.localizedDescription)
        }
    }
}

// MARK: - Browser Detection

import AppKit

enum ClaudeBrowserDetector {
    /// Check if browser is installed via bundle ID or app name hints
    static func isInstalled(_ entry: ClaudeBrowserCatalog.BrowserEntry) -> Bool {
        // Try bundle ID lookup first (fast, authoritative)
        for bundleID in entry.bundleIDs
            where NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
        {
            return true
        }

        // Fallback to app name hints in /Applications and ~/Applications
        for appName in entry.appNameHints {
            let appFileName = appName.hasSuffix(".app") ? appName : "\(appName).app"
            let systemPath = "/Applications/\(appFileName)"
            let userPath = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications/\(appFileName)").path

            if FileManager.default.fileExists(atPath: systemPath) ||
                FileManager.default.fileExists(atPath: userPath)
            {
                return true
            }
        }

        return false
    }

    /// Filter catalog entries to only installed browsers
    static func installedEntries(
        from catalog: ClaudeBrowserCatalog,
        for engine: ClaudeBrowserEngine) -> [ClaudeBrowserCatalog.BrowserEntry]
    {
        catalog.entries(for: engine).filter { self.isInstalled($0) }
    }
}

#endif
