import Foundation
import Testing
@testable import CodexBar

@MainActor
struct GoogleWorkspaceStatusTests {
    private let productID = "npdyhgECDJ6tB66MxXyo"

    @Test
    func `parse workspace status selects worst incident`() throws {
        let data = Data(#"""
        [
          {
            "id": "inc-1",
            "begin": "2025-12-02T09:00:00+00:00",
            "end": null,
            "affected_products": [
              {"title": "Gemini", "id": "npdyhgECDJ6tB66MxXyo"}
            ],
            "most_recent_update": {
              "when": "2025-12-02T10:00:00+00:00",
              "status": "SERVICE_INFORMATION",
              "text": "**Summary**\nMinor issue.\n"
            }
          },
          {
            "id": "inc-2",
            "begin": "2025-12-02T11:00:00+00:00",
            "end": null,
            "affected_products": [
              {"title": "Gemini", "id": "npdyhgECDJ6tB66MxXyo"}
            ],
            "most_recent_update": {
              "when": "2025-12-02T12:00:00+00:00",
              "status": "SERVICE_OUTAGE",
              "text": "**Summary**\nGemini API error.\n"
            }
          }
        ]
        """#.utf8)

        let status = try UsageStore.parseGoogleWorkspaceStatus(data: data, productID: self.productID)
        #expect(status.indicator == .critical)
        #expect(status.description == "Gemini API error.")
        #expect(status.updatedAt != nil)
    }

    @Test
    func `parse workspace status ignores resolved incidents`() throws {
        let data = Data(#"""
        [
          {
            "id": "inc-3",
            "begin": "2025-12-02T08:00:00+00:00",
            "end": "2025-12-02T09:00:00+00:00",
            "affected_products": [
              {"title": "Gemini", "id": "npdyhgECDJ6tB66MxXyo"}
            ],
            "most_recent_update": {
              "when": "2025-12-02T09:00:00+00:00",
              "status": "AVAILABLE",
              "text": "**Summary**\nResolved.\n"
            }
          }
        ]
        """#.utf8)

        let status = try UsageStore.parseGoogleWorkspaceStatus(data: data, productID: self.productID)
        #expect(status.indicator == .none)
        #expect(status.description == nil)
    }
}
