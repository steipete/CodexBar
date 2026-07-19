import Foundation
import SweetCookieKit
import Testing
@testable import CodexBarCore

struct WindsurfDevinSessionImporterTests {
    @Test
    func `defaults to Chrome before fallback Chromium browsers`() {
        #expect(WindsurfDevinSessionImporter.defaultPreferredBrowsers == [.chrome])
        #expect(!WindsurfDevinSessionImporter.fallbackBrowsers.contains(.chrome))
        #expect(WindsurfDevinSessionImporter.fallbackBrowsersExcluding([.chrome, .edge]).first == .chromeBeta)
        #expect(!WindsurfDevinSessionImporter.fallbackBrowsersExcluding([.chrome, .edge]).contains(.edge))
    }

    @Test
    func `reads Devin app storage before legacy Windsurf origin`() {
        #expect(WindsurfDevinSessionImporter.localStorageOrigins.map(\.absoluteString) == [
            "https://app.devin.ai",
            "https://windsurf.com",
        ])
    }

    @Test
    func `decodes quoted local storage strings`() {
        #expect(WindsurfDevinSessionImporter
            .decodedStorageValue(#""devin-session-token$abc""#) == "devin-session-token$abc")
        #expect(WindsurfDevinSessionImporter.decodedStorageValue("auth1_xyz") == "auth1_xyz")
    }

    @Test
    func `builds session only when all local storage keys exist`() {
        let storage = [
            "devin_session_token": "devin-session-token$abc",
            "devin_auth1_token": "auth1_xyz",
            "devin_account_id": "account-123",
            "devin_primary_org_id": "org-456",
        ]

        let session = WindsurfDevinSessionImporter.session(from: storage, sourceLabel: "Chrome Default")

        #expect(session?.session.sessionToken == "devin-session-token$abc")
        #expect(session?.session.auth1Token == "auth1_xyz")
        #expect(session?.session.accountID == "account-123")
        #expect(session?.session.primaryOrgID == "org-456")
        #expect(session?.sourceLabel == "Chrome Default")
    }

    @Test
    func `keeps partial app origin separate from complete legacy origin`() throws {
        let appOrigin = try #require(URL(string: "https://app.devin.ai"))
        let legacyOrigin = try #require(URL(string: "https://windsurf.com"))

        let snapshots = WindsurfDevinSessionImporter.localStorageSnapshots(from: [
            (
                origin: appOrigin,
                entries: [
                    Self.entry(origin: appOrigin, key: "devin_session_token", value: "app-session"),
                    Self.entry(origin: appOrigin, key: "devin_auth1_token", value: "app-auth1"),
                ]),
            (
                origin: legacyOrigin,
                entries: [
                    Self.entry(origin: legacyOrigin, key: "devin_session_token", value: "legacy-session"),
                    Self.entry(origin: legacyOrigin, key: "devin_auth1_token", value: "legacy-auth1"),
                    Self.entry(origin: legacyOrigin, key: "devin_account_id", value: "legacy-account"),
                    Self.entry(origin: legacyOrigin, key: "devin_primary_org_id", value: "legacy-org"),
                ]),
        ])

        #expect(snapshots == [
            WindsurfDevinSessionImporter.LocalStorageSnapshot(
                storage: [
                    "devin_session_token": "legacy-session",
                    "devin_auth1_token": "legacy-auth1",
                    "devin_account_id": "legacy-account",
                    "devin_primary_org_id": "legacy-org",
                ],
                sourceSuffix: "windsurf.com"),
        ])
    }

    @Test
    func `keeps text entry fallback after structured origin snapshots`() throws {
        let appOrigin = try #require(URL(string: "https://app.devin.ai"))

        let snapshots = WindsurfDevinSessionImporter.localStorageSnapshots(
            from: [
                (
                    origin: appOrigin,
                    entries: [
                        Self.entry(origin: appOrigin, key: "devin_session_token", value: "stale-app-session"),
                        Self.entry(origin: appOrigin, key: "devin_auth1_token", value: "stale-app-auth1"),
                        Self.entry(origin: appOrigin, key: "devin_account_id", value: "stale-app-account"),
                        Self.entry(origin: appOrigin, key: "devin_primary_org_id", value: "stale-app-org"),
                    ]),
            ],
            textEntries: [
                Self.textEntry(key: "devin_session_token", value: "legacy-text-session"),
                Self.textEntry(key: "devin_auth1_token", value: "legacy-text-auth1"),
                Self.textEntry(key: "devin_account_id", value: "legacy-text-account"),
                Self.textEntry(key: "devin_primary_org_id", value: "legacy-text-org"),
            ])

        #expect(snapshots == [
            WindsurfDevinSessionImporter.LocalStorageSnapshot(
                storage: [
                    "devin_session_token": "stale-app-session",
                    "devin_auth1_token": "stale-app-auth1",
                    "devin_account_id": "stale-app-account",
                    "devin_primary_org_id": "stale-app-org",
                ],
                sourceSuffix: "app.devin.ai"),
            WindsurfDevinSessionImporter.LocalStorageSnapshot(
                storage: [
                    "devin_session_token": "legacy-text-session",
                    "devin_auth1_token": "legacy-text-auth1",
                    "devin_account_id": "legacy-text-account",
                    "devin_primary_org_id": "legacy-text-org",
                ],
                sourceSuffix: nil),
        ])
    }

    @Test
    func `deduplicates repeated session tokens while preserving first source`() {
        let sessions = [
            WindsurfDevinSessionImporter.SessionInfo(
                session: WindsurfDevinSessionAuth(
                    sessionToken: "devin-session-token$abc",
                    auth1Token: "auth1_xyz",
                    accountID: "account-123",
                    primaryOrgID: "org-456"),
                sourceLabel: "Chrome Default"),
            WindsurfDevinSessionImporter.SessionInfo(
                session: WindsurfDevinSessionAuth(
                    sessionToken: "devin-session-token$abc",
                    auth1Token: "auth1_other",
                    accountID: "account-999",
                    primaryOrgID: "org-999"),
                sourceLabel: "Chrome Profile 1"),
            WindsurfDevinSessionImporter.SessionInfo(
                session: WindsurfDevinSessionAuth(
                    sessionToken: "devin-session-token$def",
                    auth1Token: "auth1_def",
                    accountID: "account-456",
                    primaryOrgID: "org-789"),
                sourceLabel: "Chrome Profile 2"),
        ]

        let deduplicated = WindsurfDevinSessionImporter.deduplicateSessions(sessions)

        #expect(deduplicated.count == 2)
        #expect(deduplicated[0].sourceLabel == "Chrome Default")
        #expect(deduplicated[0].session.sessionToken == "devin-session-token$abc")
        #expect(deduplicated[1].session.sessionToken == "devin-session-token$def")
    }

    private static func entry(origin: URL, key: String, value: String) -> ChromiumLocalStorageEntry {
        ChromiumLocalStorageEntry(
            origin: origin.absoluteString,
            key: key,
            value: value,
            rawValueLength: value.utf8.count)
    }

    private static func textEntry(key: String, value: String) -> ChromiumLevelDBTextEntry {
        ChromiumLevelDBTextEntry(key: key, value: value)
    }
}
