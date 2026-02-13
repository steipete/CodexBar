import Foundation

private final class AppResourceLocatorMarker {}

enum AppResourceLocator {
    private static let bundleNames = [
        "CodexBar_CodexBar",
        "CodexBar",
    ]

    static func url(forResource name: String, withExtension ext: String?) -> URL? {
        for bundle in self.lookupBundles() {
            if let url = bundle.url(forResource: name, withExtension: ext) {
                return url
            }
        }
        return nil
    }

    private static func lookupBundles() -> [Bundle] {
        var bundles: [Bundle] = []
        var seen = Set<URL>()

        func appendUnique(_ bundle: Bundle?) {
            guard let bundle else { return }
            let key = bundle.bundleURL.standardizedFileURL
            guard !seen.contains(key) else { return }
            seen.insert(key)
            bundles.append(bundle)
        }

        let markerBundle = Bundle(for: AppResourceLocatorMarker.self)
        appendUnique(Bundle.main)
        appendUnique(markerBundle)

        let roots = [
            Bundle.main.resourceURL,
            Bundle.main.bundleURL,
            markerBundle.resourceURL,
            markerBundle.bundleURL,
        ].compactMap { $0 }

        for root in roots {
            for bundleName in self.bundleNames {
                let bundleURL = root.appendingPathComponent("\(bundleName).bundle", isDirectory: true)
                appendUnique(Bundle(url: bundleURL))
            }
        }

        return bundles
    }
}
