import Foundation

/// WorkBuddy binds its website session to the browser User-Agent. Chrome's reduced User-Agent varies only by
/// major version, so the installed Chrome version is enough to reproduce the header for imported cookies.
enum WorkBuddyChromeVersion {
    static func majorVersion(
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
        readInfo: (String) -> [String: Any]? = Self.infoDictionary) -> Int?
    {
        #if os(macOS)
        for app in ["/Applications/Google Chrome.app", "\(homeDirectory)/Applications/Google Chrome.app"] {
            guard let version = readInfo("\(app)/Contents/Info.plist")?["CFBundleShortVersionString"] as? String,
                  let major = version.split(separator: ".").first.flatMap({ Int($0) }),
                  major > 1
            else { continue }
            return major
        }
        #endif
        return nil
    }

    static func infoDictionary(_ path: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }
}
