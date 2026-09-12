import Foundation
import SweetCookieKit
import Testing
@testable import CodexBarCore

struct BrowserCookieProfilesTests {
    @Test
    func `profile stores merge by expiry and retain network priority on ties`() throws {
        let early = Date(timeIntervalSince1970: 100)
        let late = Date(timeIntervalSince1970: 200)
        let profiles = BrowserCookieProfiles.merge([
            Self.source("alpha", label: "Alpha", kind: .primary, records: [
                Self.cookie("tie", value: "primary", expires: late),
                Self.cookie("newer", value: "primary-new", expires: late),
                Self.cookie("persistent", value: "primary", expires: early),
            ]),
            Self.source("alpha", label: "Alpha (Network)", kind: .network, records: [
                Self.cookie("tie", value: "network", expires: late),
                Self.cookie("newer", value: "network-old", expires: early),
                Self.cookie("persistent", value: "network-session", expires: nil),
            ]),
        ])
        let profile = try #require(profiles.first)
        #expect(profiles.count == 1)
        #expect(profile.label == "Alpha")
        let values = Dictionary(uniqueKeysWithValues: profile.records.map { ($0.name, $0.value) })
        #expect(values == ["tie": "network", "newer": "primary-new", "persistent": "primary"])
    }

    @Test
    func `profiles domains and paths remain separate`() {
        let profiles = BrowserCookieProfiles.merge([
            Self.source("beta", label: "Beta (Network)", kind: .network, records: [
                Self.cookie("session", value: "beta", expires: nil),
            ]),
            Self.source("alpha", label: "Alpha", kind: .primary, records: [
                Self.cookie("session", value: "root", expires: nil),
                Self.cookie("session", value: "path", expires: nil, path: "/other"),
                Self.cookie("session", value: "domain", expires: nil, domain: "other.test"),
            ]),
        ])
        #expect(profiles.map(\.label) == ["Alpha", "Beta"])
        #expect(Set(profiles[0].records.map(\.value)) == ["root", "path", "domain"])
        #expect(profiles[1].records.map(\.value) == ["beta"])
        #expect(BrowserCookieProfiles.merge([]).isEmpty)
    }

    private static func source(
        _ profile: String,
        label: String,
        kind: BrowserCookieStoreKind,
        records: [BrowserCookieRecord]) -> BrowserCookieStoreRecords
    {
        BrowserCookieStoreRecords(
            store: BrowserCookieStore(
                browser: .chrome,
                profile: BrowserProfile(id: profile, name: profile),
                kind: kind,
                label: label,
                databaseURL: nil),
            records: records)
    }

    private static func cookie(
        _ name: String,
        value: String,
        expires: Date?,
        domain: String = "example.test",
        path: String = "/") -> BrowserCookieRecord
    {
        BrowserCookieRecord(
            domain: domain,
            name: name,
            path: path,
            value: value,
            expires: expires,
            isSecure: true,
            isHTTPOnly: true)
    }
}
