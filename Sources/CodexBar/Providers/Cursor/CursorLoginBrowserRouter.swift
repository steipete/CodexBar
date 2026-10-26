import AppKit
import CodexBarCore
import Foundation

@MainActor
enum CursorLoginBrowserRouter {
    struct Route: Equatable {
        let launchURL: URL
        /// The concrete browser that must both open the login URL and supply the polled cookies.
        let browserApplicationURL: URL
    }

    enum Resolution: Equatable {
        case route(Route)
        case cancelled
        case unavailable
    }

    typealias ApplicationURLResolver = @MainActor (URL) -> [URL]
    typealias ApplicationChooser = @MainActor ([URL]) -> URL?
    typealias BrowserSupportCheck = @MainActor (URL?) -> Bool

    static func resolve(
        loginURL: URL,
        handlerApplicationURL: URL?,
        applicationURLs: ApplicationURLResolver = {
            NSWorkspace.shared.urlsForApplications(toOpen: $0)
        },
        chooseApplication: ApplicationChooser = { applications in
            CursorLoginBrowserRouter.chooseApplication(applications)
        },
        supportsBrowser: BrowserSupportCheck)
        -> Resolution
    {
        if let handlerApplicationURL, supportsBrowser(handlerApplicationURL) {
            return .route(Route(
                launchURL: loginURL,
                browserApplicationURL: handlerApplicationURL))
        }

        let candidates = self.supportedApplications(
            applicationURLs(loginURL),
            supportsBrowser: supportsBrowser)
        switch candidates.count {
        case 0:
            return .unavailable
        default:
            guard let selection = chooseApplication(candidates) else { return .cancelled }
            guard let candidate = candidates.first(where: { self.applicationKey($0) == self.applicationKey(selection) })
            else {
                return .unavailable
            }
            return .route(Route(
                launchURL: loginURL,
                browserApplicationURL: candidate))
        }
    }

    static func supportedApplications(
        _ applicationURLs: [URL],
        supportsBrowser: BrowserSupportCheck)
        -> [URL]
    {
        var seen = Set<String>()
        return applicationURLs
            .filter { supportsBrowser($0) }
            .filter { seen.insert(self.applicationKey($0)).inserted }
            .sorted(by: self.applicationSortsBefore)
    }

    static func applicationLabels(_ applicationURLs: [URL]) -> [String] {
        let names = applicationURLs.map(self.applicationName)
        let counts = Dictionary(grouping: names, by: { $0 }).mapValues(\.count)
        return zip(applicationURLs, names).map { applicationURL, name in
            guard counts[name, default: 0] > 1 else { return name }
            return "\(name) (\(applicationURL.deletingLastPathComponent().path))"
        }
    }

    static func chooseApplication(_ applicationURLs: [URL]) -> URL? {
        guard !applicationURLs.isEmpty else { return nil }

        let popup = NSPopUpButton(
            frame: NSRect(x: 0, y: 0, width: 320, height: 26),
            pullsDown: false)
        popup.addItems(withTitles: self.applicationLabels(applicationURLs))
        popup.selectItem(at: 0)

        let alert = NSAlert()
        alert.messageText = L("Open Browser")
        alert.informativeText = L("Choose a supported browser so CodexBar can read the matching account.")
        alert.accessoryView = popup
        alert.addButton(withTitle: L("Open Browser"))
        alert.addButton(withTitle: L("Cancel"))

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let selectedIndex = popup.indexOfSelectedItem
        guard applicationURLs.indices.contains(selectedIndex) else { return nil }
        return applicationURLs[selectedIndex]
    }

    private static func applicationName(_ applicationURL: URL) -> String {
        let bundle = Bundle(url: applicationURL)
        return (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle?.object(forInfoDictionaryKey: kCFBundleNameKey as String) as? String)
            ?? applicationURL.deletingPathExtension().lastPathComponent
    }

    private static func applicationKey(_ applicationURL: URL) -> String {
        applicationURL.standardizedFileURL.path
    }

    private static func applicationSortsBefore(_ lhs: URL, _ rhs: URL) -> Bool {
        let lhsName = self.applicationName(lhs)
        let rhsName = self.applicationName(rhs)
        let nameComparison = lhsName.localizedCaseInsensitiveCompare(rhsName)
        if nameComparison != .orderedSame {
            return nameComparison == .orderedAscending
        }
        return self.applicationKey(lhs).localizedCaseInsensitiveCompare(self.applicationKey(rhs)) == .orderedAscending
    }
}
