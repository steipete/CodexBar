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

    static func loadProfiles(
        origin: String,
        root: URL,
        browserID: String,
        labelPrefix: String,
        logger: @escaping @Sendable (String) -> Void) -> [Profile]
    {
        let profileNames = ProviderBrowserProfile.chromiumProfileNames(
            root: root,
            nameKeys: ["gaia_given_name", "name"])
        return ChromiumLocalStorageDiscovery.profileCandidates(root: root, labelPrefix: labelPrefix)
            .compactMap { candidate in
                guard !Task.isCancelled else { return nil }
                let levelDB = candidate.url
                let name = levelDB.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent

                let id = "\(browserID):\(name)"
                logger("Checking \(id)")
                let entries = SweetCookieKit.ChromiumLocalStorageReader.readEntries(
                    for: origin,
                    in: levelDB,
                    logger: logger)
                    .map { Entry(key: $0.key, value: $0.value) }
                let displayName = profileNames[name]
                let label = if let displayName, !displayName.isEmpty, displayName != name {
                    "\(labelPrefix) — \(displayName)"
                } else {
                    "\(labelPrefix) \(name)"
                }
                return Profile(id: id, label: label, entries: entries)
            }
            .sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
    }
}
#endif
