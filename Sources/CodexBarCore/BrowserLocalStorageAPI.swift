#if os(macOS)
import Foundation
import SweetCookieKit

struct BrowserLocalStorageAPI: Sendable {
    struct Entry: Sendable {
        let key: String
        let value: String
    }

    struct Profile: Sendable {
        let id: String
        let label: String
        let entries: [Entry]
    }

    typealias Loader = @Sendable (
        _ origin: String,
        _ browsers: [Browser],
        _ detection: BrowserDetection,
        _ logger: @escaping @Sendable (String) -> Void) -> [Profile]

    private let loader: Loader

    init(loader: @escaping Loader) {
        self.loader = loader
    }

    func profiles(
        for origin: String,
        browsers: [Browser],
        using detection: BrowserDetection,
        logger: @escaping @Sendable (String) -> Void) -> [Profile]
    {
        self.loader(origin, browsers, detection, logger)
    }

    static let live = BrowserLocalStorageAPI { origin, browsers, detection, logger in
        let installedBrowsers = browsers.browsersWithProfileData(using: detection)
        let roots = ChromiumProfileLocator.roots(
            for: installedBrowsers,
            homeDirectories: BrowserCookieClient.defaultHomeDirectories())
        return roots.flatMap { root in
            Self.loadProfiles(
                origin: origin,
                root: root.url,
                browserID: root.browser.rawValue,
                labelPrefix: root.labelPrefix,
                logger: logger)
        }
    }

    private static func loadProfiles(
        origin: String,
        root: URL,
        browserID: String,
        labelPrefix: String,
        logger: @escaping @Sendable (String) -> Void) -> [Profile]
    {
        guard let directories = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])
        else { return [] }

        let profileNames = Self.chromeProfileNames(root: root)
        return directories.compactMap { directory in
            guard !Task.isCancelled,
                  let isDirectory = try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory,
                  isDirectory
            else { return nil }
            let name = directory.lastPathComponent
            guard name == "Default" || name.hasPrefix("Profile ") || name.hasPrefix("user-") else {
                return nil
            }
            let levelDB = directory.appendingPathComponent("Local Storage").appendingPathComponent("leveldb")
            guard FileManager.default.fileExists(atPath: levelDB.path) else { return nil }

            let id = "\(browserID):\(name)"
            logger("Checking \(id)")
            let entries = SweetCookieKit.ChromiumLocalStorageReader.readEntries(
                for: origin,
                in: levelDB,
                logger: logger)
                .map { Entry(key: $0.key, value: $0.value) }
            let displayName = profileNames[name]?.trimmingCharacters(in: .whitespacesAndNewlines)
            let label = if let displayName, !displayName.isEmpty, displayName != name {
                "\(labelPrefix) — \(displayName)"
            } else {
                "\(labelPrefix) \(name)"
            }
            return Profile(id: id, label: label, entries: entries)
        }
        .sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
    }

    private static func chromeProfileNames(root: URL) -> [String: String] {
        let localStateURL = root.appendingPathComponent("Local State")
        guard let data = try? Data(contentsOf: localStateURL),
              let rootObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profile = rootObject["profile"] as? [String: Any],
              let infoCache = profile["info_cache"] as? [String: Any]
        else { return [:] }

        return infoCache.reduce(into: [:]) { result, entry in
            guard let info = entry.value as? [String: Any] else { return }
            let name = (info["gaia_given_name"] as? String) ?? (info["name"] as? String)
            guard let name else { return }
            result[entry.key] = name
        }
    }
}
#endif
