import Foundation
import SweetCookieKit
import Testing
@testable import CodexBarCore

struct ProviderBrowserProfileDisplayNameTests {
    @Test(arguments: [Browser.edge, .chrome])
    func `picker uses browser profile names and preserves selected store identity`(browser: Browser) throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("ProfileNames-\(UUID())")
        defer { try? FileManager.default.removeItem(at: home) }
        let root = try Self.makeProfiles(home: home, browser: browser)
        try Data("""
        {"profile":{"info_cache":{
          "Default":{"name":"Work","gaia_given_name":"Account name"},
          "Profile 1":{"name":"Personal"},
          "Profile 2":{"name":"  Projects  "},
          "Profile 99":{"name":"Deleted profile"}
        }}}
        """.utf8).write(to: root.appendingPathComponent("Local State"))
        let client = BrowserCookieClient(configuration: .init(homeDirectories: [home]))
        let stores = try client.codexBarStores(for: browser)
        let profiles = ProviderBrowserProfile.selectableProfiles(from: stores)
        #expect(profiles.count == 3)
        let names = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0.name) })
        for (directory, name) in [("Default", "Work"), ("Profile 1", "Personal"), ("Profile 2", "Projects")] {
            let id = try #require(stores.first { $0.profile.name == directory }).profile.id
            #expect(names[id] == name)
            let selected = try ProviderBrowserProfile.selectedStore(
                .init(browserID: browser.rawValue, profileID: id), from: stores)
            #expect(selected.profile.id == id)
            #expect(selected.kind == .network)
        }
        try Data(#"{"profile":{"info_cache":{"Default":{"name":"Renamed work"}}}}"#.utf8)
            .write(to: root.appendingPathComponent("Local State"))
        let refreshed = ProviderBrowserProfile.selectableProfiles(from: stores)
        let defaultID = try #require(stores.first { $0.profile.name == "Default" }).profile.id
        #expect(refreshed.first { $0.id == defaultID }?.name == "Renamed work")
    }

    @Test(arguments: [
        "", "not JSON", "[]", #"{"profile":{}}"#,
        #"{"profile":{"info_cache":{"Default":{"name":42},"Profile 1":{"name":" "}}}}"#,
    ])
    func `missing or invalid names retain discoverable profiles`(localState: String) throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("ProfileNames-\(UUID())")
        defer { try? FileManager.default.removeItem(at: home) }
        let root = try Self.makeProfiles(home: home, browser: .edge)
        if !localState.isEmpty {
            try Data(localState.utf8).write(to: root.appendingPathComponent("Local State"))
        }
        let client = BrowserCookieClient(configuration: .init(homeDirectories: [home]))
        let stores = try client.codexBarStores(for: .edge)
        let profiles = ProviderBrowserProfile.selectableProfiles(from: stores)
        #expect(Set(profiles.map(\.name)) == ["Default", "Profile 1", "Profile 2"])
        #expect(Set(profiles.map(\.id)) == Set(stores.map(\.profile.id)))
    }

    @Test
    func `names belong to their browser root even when profile directories match`() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("ProfileNames-\(UUID())")
        defer { try? FileManager.default.removeItem(at: home) }
        let edge = try Self.makeProfiles(home: home, browser: .edge)
        let chrome = try Self.makeProfiles(home: home, browser: .chrome)
        for (root, name) in [(edge, "Edge work"), (chrome, "Chrome work")] {
            try JSONSerialization.data(withJSONObject: ["profile": ["info_cache": ["Default": ["name": name]]]])
                .write(to: root.appendingPathComponent("Local State"))
        }
        let client = BrowserCookieClient(configuration: .init(homeDirectories: [home]))
        let edgeStores = try client.codexBarStores(for: .edge)
        let chromeStores = try client.codexBarStores(for: .chrome)
        let profiles = ProviderBrowserProfile.selectableProfiles(from: edgeStores + chromeStores)
        #expect(profiles.count == 6)
        let edgeID = try #require(edgeStores.first { $0.profile.name == "Default" }).profile.id
        let chromeID = try #require(chromeStores.first { $0.profile.name == "Default" }).profile.id
        #expect(profiles.first { $0.id == edgeID }?.name == "Edge work")
        #expect(profiles.first { $0.id == chromeID }?.name == "Chrome work")
    }

    @Test
    func `a malformed name does not hide another profiles valid name`() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("ProfileNames-\(UUID())")
        defer { try? FileManager.default.removeItem(at: home) }
        let root = try Self.makeProfiles(home: home, browser: .edge)
        try Data("""
        {"profile":{"info_cache":{
          "Default":{"name":42},"Profile 1":{"name":"Personal"},"Profile 2":false
        }}}
        """.utf8).write(to: root.appendingPathComponent("Local State"))
        let client = BrowserCookieClient(configuration: .init(homeDirectories: [home]))
        let profiles = try ProviderBrowserProfile.selectableProfiles(from: client.codexBarStores(for: .edge))
        #expect(Set(profiles.map(\.name)) == ["Default", "Personal", "Profile 2"])
    }

    @Test
    func `Safari keeps its existing labels and exact cookie file identifiers`() {
        let file = URL(fileURLWithPath: "/synthetic/Safari/Cookies.binarycookies")
        let stores = [
            BrowserCookieStore(
                browser: .safari,
                profile: .init(id: "safari.default", name: "Personal"),
                kind: .safari,
                label: "Safari",
                databaseURL: file),
            BrowserCookieStore(
                browser: .safari,
                profile: .init(id: "placeholder", name: "Placeholder"),
                kind: .safari,
                label: "Safari",
                databaseURL: nil),
        ]
        #expect(ProviderBrowserProfile.selectableProfiles(from: stores) == [
            BrowserProfile(id: file.path, name: "Personal"),
        ])
    }

    private static func makeProfiles(home: URL, browser: Browser) throws -> URL {
        let root = try #require(ChromiumProfileLocator.roots(for: [browser], homeDirectories: [home]).first)
            .url
        for directory in ["Default", "Profile 1", "Profile 2"] {
            let profile = root.appendingPathComponent(directory)
            try FileManager.default.createDirectory(
                at: profile.appendingPathComponent("Network"), withIntermediateDirectories: true)
            try Data().write(to: profile.appendingPathComponent("Cookies"))
            try Data().write(to: profile.appendingPathComponent("Network/Cookies"))
        }
        return root
    }
}
