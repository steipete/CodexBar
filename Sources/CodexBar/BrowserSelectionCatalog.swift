import AppKit
import CodexBarCore
import Foundation
import SweetCookieKit

struct BrowserSelectionEntry: Identifiable, Hashable {
    let id: String
    let displayName: String
    let statusText: String
    let hasProfileData: Bool
    let isInstalled: Bool
}

enum BrowserSelectionCatalog {
    static func entries(using detection: BrowserDetection) -> [BrowserSelectionEntry] {
        var entries = Browser.allCases.map { browser in
            let installed = detection.isAppInstalled(browser)
            let hasProfile = detection.hasUsableProfileData(browser)
            let status = Self.statusText(isInstalled: installed, hasProfileData: hasProfile)
            return BrowserSelectionEntry(
                id: browser.rawValue,
                displayName: browser.displayName,
                statusText: status,
                hasProfileData: hasProfile,
                isInstalled: installed)
        }

        let comet = Self.cometEntry()
        entries.append(comet)

        return entries.sorted { lhs, rhs in
            if lhs.hasProfileData != rhs.hasProfileData {
                return lhs.hasProfileData && !rhs.hasProfileData
            }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    static func defaultAllowedBrowserIDs(using detection: BrowserDetection) -> Set<String> {
        let entries = Self.entries(using: detection)
        return Set(entries.filter(\.hasProfileData).map(\.id))
    }

    private static func statusText(isInstalled: Bool, hasProfileData: Bool) -> String {
        if hasProfileData { return "Profile data found" }
        if isInstalled { return "Installed, no profile data" }
        return "Not installed"
    }

    private static func cometEntry() -> BrowserSelectionEntry {
        let installed = self.isCometInstalled()
        let hasProfile = self.hasCometProfileData()
        let status = Self.statusText(isInstalled: installed, hasProfileData: hasProfile)
        return BrowserSelectionEntry(
            id: "comet",
            displayName: "Comet",
            statusText: status,
            hasProfileData: hasProfile,
            isInstalled: installed)
    }

    private static func isCometInstalled() -> Bool {
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.perplexity.comet") != nil {
            return true
        }
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.perplexity.Comet") != nil {
            return true
        }
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let systemPath = "/Applications/Comet.app"
        let userPath = "\(home)/Applications/Comet.app"
        return fm.fileExists(atPath: systemPath) || fm.fileExists(atPath: userPath)
    }

    private static func hasCometProfileData() -> Bool {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let root = "\(home)/Library/Application Support/Comet"
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root, isDirectory: &isDir), isDir.boolValue else { return false }

        let defaultCookies = "\(root)/Default/Cookies"
        let defaultNetworkCookies = "\(root)/Default/Network/Cookies"
        if fm.fileExists(atPath: defaultCookies) || fm.fileExists(atPath: defaultNetworkCookies) {
            return true
        }

        guard let contents = try? fm.contentsOfDirectory(atPath: root) else { return false }
        for name in contents where name == "Default" || name.hasPrefix("Profile ") || name.hasPrefix("user-") {
            let legacy = "\(root)/\(name)/Cookies"
            let network = "\(root)/\(name)/Network/Cookies"
            if fm.fileExists(atPath: legacy) || fm.fileExists(atPath: network) {
                return true
            }
        }

        return false
    }
}
