import Foundation
#if os(macOS)
import SweetCookieKit
#endif

public struct ProviderBrowserProfile: Sendable, Equatable {
    public let browserID: String
    public let profileID: String

    public init(browserID: String, profileID: String) {
        self.browserID = browserID
        self.profileID = profileID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func selected(in config: ProviderConfig?, browsers: [String]) -> Self? {
        if config?.extensionValues["browserID"] != nil, config?.browserID == nil { return nil }
        guard let browserID = config?.browserID ?? browsers.first, browsers.contains(browserID) else { return nil }
        return Self(browserID: browserID, profileID: config?.browserProfileID ?? "")
    }

    #if os(macOS)
    public static func selectableProfile(for store: BrowserCookieStore) -> BrowserProfile? {
        guard let file = store.databaseURL else { return nil }
        // Safari datastore IDs can move to another file when a duplicate store disappears.
        return BrowserProfile(
            id: store.browser == .safari ? file.standardizedFileURL.path : store.profile.id,
            name: store.profile.name)
    }

    static func selectedStore(
        _ selection: Self,
        from stores: [BrowserCookieStore],
        homeDirectories: [URL] = [],
        listDirectory: (String) throws -> [String] = FileManager.default.contentsOfDirectory(atPath:)) throws
        -> BrowserCookieStore
    {
        let matching = stores.filter {
            $0.browser.rawValue == selection.browserID && Self.selectableProfile(for: $0)?.id == selection.profileID
        }
        guard let store = matching.first(where: { $0.kind == .network })
            ?? matching.first(where: { $0.kind == .primary })
            ?? matching.first(where: { $0.kind == .safari })
        else {
            if Self.safariStoreAccessDenied(selection, homeDirectories: homeDirectories, listDirectory: listDirectory) {
                throw ProviderFetchClassifiedError(
                    kind: .permissionDenied,
                    message: "Cannot read Safari cookies. Check Full Disk Access for CodexBar.")
            }
            throw ProviderFetchClassifiedError(
                kind: .missingCredential, message: "The selected browser profile has no discoverable cookie store.")
        }
        return store
    }

    private static func safariStoreAccessDenied(
        _ selection: Self,
        homeDirectories: [URL],
        listDirectory: (String) throws -> [String]) -> Bool
    {
        guard selection.browserID == "safari", selection.profileID.hasPrefix("/") else { return false }
        let file = URL(fileURLWithPath: selection.profileID).standardizedFileURL
        guard file.path == selection.profileID, file.lastPathComponent == "Cookies.binarycookies" else { return false }
        let parent = file.deletingLastPathComponent()
        let roots = homeDirectories.flatMap { home in
            [
                "Library/Cookies",
                "Library/Containers/com.apple.Safari/Data/Library/Cookies",
                "Library/Containers/com.apple.Safari/Data/Library/WebKit/WebsiteDataStore",
                "Library/WebKit/WebsiteDataStore",
            ].map { home.appendingPathComponent($0).standardizedFileURL }
        }
        guard let root = roots.first(where: {
            $0.lastPathComponent == "WebsiteDataStore" ? file.path.hasPrefix($0.path + "/") : parent.path == $0.path
        }), BrowserCookieAccessGate.cookieStoreAccessDecision(homeDirectories: homeDirectories) == .allowed
        else { return false }
        // Discovery can hide EPERM behind an absent store. Probe only this selection's directory metadata.
        for directory in root.path == parent.path ? [root] : [root, parent] {
            do {
                _ = try listDirectory(directory.path)
            } catch {
                return Self.isPermissionError(error)
            }
        }
        return false
    }

    private static func isPermissionError(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain, error.code == CocoaError.fileReadNoPermission.rawValue { return true }
        if error.domain == NSPOSIXErrorDomain, error.code == Int(EACCES) || error.code == Int(EPERM) { return true }
        guard let underlying = error.userInfo[NSUnderlyingErrorKey] as? Error else { return false }
        return Self.isPermissionError(underlying)
    }
    #endif

    static func read(_ selection: Self, domains: Set<String>) throws -> [ProviderPluginCookieRecord] {
        #if os(macOS)
        guard let browser = Browser(rawValue: selection.browserID) else {
            throw ProviderPluginError.secretAccess("unsupported selected browser")
        }
        guard BrowserCookieAccessGate.shouldAttempt(browser) else {
            throw ProviderFetchClassifiedError(
                kind: .permissionDenied,
                message: "Browser cookie access is blocked. Check Keychain access and refresh manually.")
        }
        let client = BrowserCookieClient()
        let store: BrowserCookieStore
        do {
            store = try Self.selectedStore(
                selection,
                from: client.codexBarStores(for: browser),
                homeDirectories: client.configuration.homeDirectories)
        } catch {
            if BrowserDetection.selectedChromiumProfileAccessIssue(
                profileID: selection.profileID,
                browser: browser,
                homeDirectories: client.configuration.homeDirectories) == .accessDenied
            {
                throw ProviderFetchClassifiedError(
                    kind: .permissionDenied,
                    message: "Cannot read the selected browser profile. Check Files & Folders access.")
            }
            throw error
        }
        do {
            return try client.codexBarRecords(
                matching: BrowserCookieQuery(domains: domains.sorted(), domainMatch: .exact), in: store)
                .map(ProviderPluginCookieRecord.init)
        } catch let error as BrowserCookieError {
            guard case .accessDenied = error else { throw error }
            throw ProviderFetchClassifiedError(
                kind: .permissionDenied,
                message: browser == .safari
                    ? "Cannot read Safari cookies. Check Full Disk Access for CodexBar."
                    : "Cannot decrypt the selected profile. Check browser Keychain access.")
        }
        #else
        throw ProviderFetchClassifiedError(
            kind: .missingCredential,
            message: "Selected browser profiles require macOS.")
        #endif
    }
}

extension ProviderConfig {
    public var browserID: String? {
        get { self.extensionValue(forKey: "browserID") }
        set { self.setExtensionValue(newValue, forKey: "browserID") }
    }

    public var browserProfileID: String? {
        get { self.extensionValue(forKey: "browserProfileID") }
        set { self.setExtensionValue(newValue, forKey: "browserProfileID") }
    }
}

extension ProviderSettingsSectionRegistration {
    var selectedProfileCookieOrder: BrowserCookieImportOrder? {
        #if os(macOS)
        self.selectedProfileBrowsers.map { $0.compactMap(Browser.init(rawValue:)) }
        #else
        nil
        #endif
    }
}
