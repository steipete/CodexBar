import Foundation
import Testing
@testable import CodexBarCore

struct ClaudeSwapSwitchParserTests {
    private func parse(_ json: String) throws -> ClaudeSwapAccountSwitchResult {
        try ClaudeSwapSwitchParser.parse(Data(json.utf8))
    }

    @Test
    func `parses direct switch result without retaining display identity`() throws {
        let result = try self.parse("""
        {
          "schemaVersion": 1,
          "switched": true,
          "from": {"number": 1, "email": "old@example.com"},
          "to": {"number": 2, "email": "new@example.com"},
          "strategy": "direct",
          "reason": "switched",
          "message": "Switched",
          "warnings": []
        }
        """)

        #expect(result == ClaudeSwapAccountSwitchResult(
            switched: true,
            fromAccountNumber: 1,
            toAccountNumber: 2,
            reason: "switched"))
    }

    @Test
    func `accepts unmanaged source and already active no op`() throws {
        let freshActivation = try self.parse("""
        {"schemaVersion":1,"switched":true,"from":null,
         "to":{"number":2},"reason":"switched"}
        """)
        #expect(freshActivation.fromAccountNumber == nil)
        #expect(freshActivation.toAccountNumber == 2)

        let unmanaged = try self.parse("""
        {"schemaVersion":1,"switched":true,"from":{"number":null},
         "to":{"number":3},"reason":"switched"}
        """)
        #expect(unmanaged.fromAccountNumber == nil)
        #expect(unmanaged.toAccountNumber == 3)

        let active = try self.parse("""
        {"schemaVersion":1,"switched":false,"from":{"number":3},
         "to":{"number":3},"reason":"already-active"}
        """)
        #expect(active.switched == false)
        #expect(active.reason == "already-active")
    }

    @Test
    func `surfaces switch error envelope`() {
        #expect(throws: ClaudeSwapSwitchParserError.reportedError(
            type: "SwitchError",
            message: "store locked"))
        {
            try self.parse("""
            {"schemaVersion":1,"error":{"type":"SwitchError","message":"store locked"}}
            """)
        }
    }

    @Test
    func `rejects malformed or unsupported switch results`() {
        #expect(throws: ClaudeSwapSwitchParserError.notJSONObject) {
            try self.parse("not json")
        }
        #expect(throws: ClaudeSwapSwitchParserError.missingSchemaVersion) {
            try self.parse(#"{"switched":true}"#)
        }
        #expect(throws: ClaudeSwapSwitchParserError.missingSchemaVersion) {
            try self.parse(#"{"schemaVersion":true}"#)
        }
        #expect(throws: ClaudeSwapSwitchParserError.unsupportedSchemaVersion(2)) {
            try self.parse(#"{"schemaVersion":2}"#)
        }
        #expect(throws: ClaudeSwapSwitchParserError.malformedShape("missing switched flag")) {
            try self.parse(#"{"schemaVersion":1}"#)
        }
        #expect(throws: (any Error).self) {
            try self.parse("""
            {"schemaVersion":1,"switched":true,"from":{"number":1},
             "to":{"number":true},"reason":"switched"}
            """)
        }
    }
}
