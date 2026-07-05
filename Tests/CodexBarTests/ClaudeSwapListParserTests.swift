import Foundation
import Testing
@testable import CodexBarCore

struct ClaudeSwapListParserTests {
    private func parse(_ json: String) throws -> ClaudeSwapAccountList {
        try ClaudeSwapListParser.parse(Data(json.utf8))
    }

    @Test
    func `parses schema v1 list payload`() throws {
        let json = """
        {
          "schemaVersion": 1,
          "activeAccountNumber": 2,
          "accounts": [
            {
              "number": 1,
              "email": "work@example.com",
              "organizationName": "",
              "organizationUuid": "",
              "isOrganization": false,
              "active": false,
              "usageStatus": "ok",
              "usage": {
                "fiveHour": {"pct": 25.0, "resetsAt": "2026-06-22T23:29:59Z", "countdown": "1h"},
                "sevenDay": {"pct": 16.5, "resetsAt": "2026-06-26T17:59:59Z"}
              },
              "usageFetchedAt": "2026-06-22T20:00:00Z",
              "usageAgeSeconds": 42.0
            },
            {
              "number": 2,
              "email": "personal@example.com",
              "active": true,
              "usageStatus": "ok",
              "usage": {"fiveHour": {"pct": 80}}
            }
          ]
        }
        """

        let list = try self.parse(json)
        #expect(list.activeAccountNumber == 2)
        #expect(list.accounts.count == 2)

        let first = try #require(list.accounts.first)
        #expect(first.number == 1)
        #expect(first.email == "work@example.com")
        #expect(first.isActive == false)
        #expect(first.usageStatus == .ok)
        #expect(first.fiveHour?.usedPercent == 25.0)
        #expect(first.fiveHour?.resetsAt == Date(timeIntervalSince1970: 1_782_170_999))
        #expect(first.sevenDay?.usedPercent == 16.5)

        let second = try #require(list.accounts.last)
        #expect(second.isActive == true)
        #expect(second.fiveHour?.usedPercent == 80)
        #expect(second.fiveHour?.resetsAt == nil)
        #expect(second.sevenDay == nil)
    }

    @Test
    func `parses empty account list without accounts configured`() throws {
        let json = """
        {"schemaVersion": 1, "activeAccountNumber": null, "accounts": []}
        """

        let list = try self.parse(json)
        #expect(list.activeAccountNumber == nil)
        #expect(list.accounts.isEmpty)
    }

    @Test
    func `maps usage status sentinels including unknown values`() throws {
        let json = """
        {
          "schemaVersion": 1,
          "activeAccountNumber": 1,
          "accounts": [
            {"number": 1, "email": "a@b.c", "active": true, "usageStatus": "token_expired", "usage": null},
            {"number": 2, "email": "d@e.f", "active": false, "usageStatus": "api_key", "usage": null},
            {"number": 3, "email": "g@h.i", "active": false, "usageStatus": "keychain_unavailable", "usage": null},
            {"number": 4, "email": "j@k.l", "active": false, "usageStatus": "no_credentials", "usage": null},
            {"number": 5, "email": "m@n.o", "active": false, "usageStatus": "unavailable", "usage": null},
            {"number": 6, "email": "p@q.r", "active": false, "usageStatus": "brand_new_status", "usage": null}
          ]
        }
        """

        let statuses = try self.parse(json).accounts.map(\.usageStatus)
        #expect(statuses == [
            .tokenExpired,
            .apiKey,
            .keychainUnavailable,
            .noCredentials,
            .unavailable,
            .unknown("brand_new_status"),
        ])
    }

    @Test
    func `surfaces schema v1 error envelope`() throws {
        let json = """
        {"schemaVersion": 1, "error": {"type": "SwitchError", "message": "boom"}}
        """

        #expect(throws: ClaudeSwapListParserError.reportedError(type: "SwitchError", message: "boom")) {
            try self.parse(json)
        }
    }

    @Test
    func `rejects unknown schema versions`() throws {
        let json = """
        {"schemaVersion": 2, "activeAccountNumber": 1, "accounts": []}
        """

        #expect(throws: ClaudeSwapListParserError.unsupportedSchemaVersion(2)) {
            try self.parse(json)
        }
    }

    @Test
    func `rejects payloads without schema version or accounts`() throws {
        #expect(throws: ClaudeSwapListParserError.missingSchemaVersion) {
            try self.parse(#"{"accounts": []}"#)
        }
        #expect(throws: ClaudeSwapListParserError.malformedShape("missing accounts array")) {
            try self.parse(#"{"schemaVersion": 1}"#)
        }
        #expect(throws: ClaudeSwapListParserError.malformedShape("missing activeAccountNumber")) {
            try self.parse(#"{"schemaVersion": 1, "accounts": []}"#)
        }
        #expect(throws: ClaudeSwapListParserError.notJSONObject) {
            try self.parse("not json at all")
        }
        #expect(throws: ClaudeSwapListParserError.notJSONObject) {
            try self.parse(#"["schemaVersion", 1]"#)
        }
    }

    @Test
    func `rejects invalid or duplicate account slots`() throws {
        #expect(throws: ClaudeSwapListParserError.malformedShape("account slot must be positive")) {
            try self.parse("""
            {"schemaVersion": 1, "activeAccountNumber": null, "accounts": [
              {"number": 0, "active": false, "usageStatus": "ok"}
            ]}
            """)
        }
        #expect(throws: ClaudeSwapListParserError.malformedShape("duplicate account slot 1")) {
            try self.parse("""
            {"schemaVersion": 1, "activeAccountNumber": 1, "accounts": [
              {"number": 1, "active": true, "usageStatus": "ok"},
              {"number": 1, "active": false, "usageStatus": "ok"}
            ]}
            """)
        }
        #expect(throws: ClaudeSwapListParserError.malformedShape(
            "activeAccountNumber is not a numeric slot or null"))
        {
            try self.parse(#"{"schemaVersion": 1, "activeAccountNumber": "1", "accounts": []}"#)
        }
        #expect(throws: ClaudeSwapListParserError.malformedShape("active account fields disagree")) {
            try self.parse("""
            {"schemaVersion": 1, "activeAccountNumber": 2, "accounts": [
              {"number": 1, "active": true, "usageStatus": "ok"},
              {"number": 2, "active": false, "usageStatus": "ok"}
            ]}
            """)
        }
    }

    @Test
    func `rejects rows with missing required fields`() throws {
        #expect(throws: (any Error).self) {
            try self.parse("""
            {"schemaVersion": 1, "activeAccountNumber": 1, "accounts": [
              {"email": "a@b.c", "active": true, "usageStatus": "ok"}
            ]}
            """)
        }
        #expect(throws: (any Error).self) {
            try self.parse("""
            {"schemaVersion": 1, "activeAccountNumber": 1, "accounts": [
              {"number": 1, "email": "a@b.c", "usageStatus": "ok"}
            ]}
            """)
        }
        #expect(throws: (any Error).self) {
            try self.parse("""
            {"schemaVersion": 1, "activeAccountNumber": 1, "accounts": [
              {"number": 1, "email": "a@b.c", "active": true}
            ]}
            """)
        }
    }

    @Test
    func `rejects invalid percentages and timestamps`() throws {
        #expect(throws: (any Error).self) {
            try self.parse("""
            {"schemaVersion": 1, "activeAccountNumber": 1, "accounts": [
              {"number": 1, "email": "a@b.c", "active": true, "usageStatus": "ok",
               "usage": {"fiveHour": {"pct": "not-a-number"}}}
            ]}
            """)
        }
        #expect(throws: (any Error).self) {
            try self.parse("""
            {"schemaVersion": 1, "activeAccountNumber": 1, "accounts": [
              {"number": 1, "email": "a@b.c", "active": true, "usageStatus": "ok",
               "usage": {"fiveHour": {"pct": true}}}
            ]}
            """)
        }
        #expect(throws: (any Error).self) {
            try self.parse("""
            {"schemaVersion": 1, "activeAccountNumber": 1, "accounts": [
              {"number": 1, "email": "a@b.c", "active": true, "usageStatus": "ok",
               "usage": {"fiveHour": {"pct": 10, "resetsAt": "yesterday-ish"}}}
            ]}
            """)
        }
    }

    @Test
    func `clamps out of range percentages`() throws {
        let json = """
        {"schemaVersion": 1, "activeAccountNumber": 1, "accounts": [
          {"number": 1, "email": "a@b.c", "active": true, "usageStatus": "ok",
           "usage": {"fiveHour": {"pct": 130.5}, "sevenDay": {"pct": -4}}}
        ]}
        """

        let row = try #require(self.parse(json).accounts.first)
        #expect(row.fiveHour?.usedPercent == 100)
        #expect(row.sevenDay?.usedPercent == 0)
    }

    @Test
    func `parses fractional second timestamps`() throws {
        let json = """
        {"schemaVersion": 1, "activeAccountNumber": 1, "accounts": [
          {"number": 1, "email": "a@b.c", "active": true, "usageStatus": "ok",
           "usage": {"fiveHour": {"pct": 10, "resetsAt": "2026-06-22T23:29:59.500Z"}}}
        ]}
        """

        let row = try #require(self.parse(json).accounts.first)
        #expect(row.fiveHour?.resetsAt == Date(timeIntervalSince1970: 1_782_170_999.5))
    }
}
