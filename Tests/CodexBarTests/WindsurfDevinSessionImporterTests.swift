import Foundation
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
}
