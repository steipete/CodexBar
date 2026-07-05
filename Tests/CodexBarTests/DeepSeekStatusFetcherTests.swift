import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct DeepSeekStatusFetcherTests {
    @Test
    func `parse active summary maps operational components`() throws {
        let data = Data(#"""
        {
          "data": {
            "page": {
              "components": [
                {
                  "component_id": "01KR3NC9ETZYF436Z8YT1HM047",
                  "name": "API 服务 (API Service)",
                  "order_id": 1
                },
                {
                  "component_id": "01KR3NC9ETESRRQ4GABE0TGW53",
                  "name": "网页对话服务 (Web Chat Service)",
                  "order_id": 2
                }
              ]
            },
            "active_changes": []
          }
        }
        """#.utf8)

        let summary = try DeepSeekStatusFetcher.parseActiveSummary(data: data)

        #expect(summary.indicator == "none")
        #expect(summary.description == nil)
        #expect(summary.components.map(\.name) == ["API Service", "Web Chat Service"])
        #expect(summary.components.allSatisfy { $0.status == "operational" })
        #expect(summary.providerComponents.map(\.indicator) == [.none, .none])
    }

    @Test
    func `parse active summary overlays active incident component statuses`() throws {
        let data = Data(#"""
        {
          "data": {
            "page": {
              "components": [
                {
                  "component_id": "api",
                  "name": "API 服务 (API Service)",
                  "order_id": 1
                },
                {
                  "component_id": "web",
                  "name": "网页对话服务 (Web Chat Service)",
                  "order_id": 2
                }
              ]
            },
            "active_changes": [
              {
                "title": "DeepSeek Web/API Degraded Performance",
                "affected_components": [
                  {"component_id": "api", "status": "degraded"},
                  {"component_id": "web", "status": "partial_outage"}
                ],
                "updates": [
                  {
                    "at_seconds": 1782986182,
                    "component_changes": [
                      {"component_id": "web", "status": "degraded"}
                    ]
                  }
                ]
              }
            ]
          }
        }
        """#.utf8)

        let summary = try DeepSeekStatusFetcher.parseActiveSummary(data: data)

        #expect(summary.indicator == "major")
        #expect(summary.description == "DeepSeek Web/API Degraded Performance")
        #expect(summary.updatedAt == Date(timeIntervalSince1970: 1_782_986_182))
        #expect(summary.components.map(\.status) == ["degraded", "partial_outage"])
        #expect(summary.providerComponents.map(\.indicator) == [.minor, .major])
        #expect(summary.providerComponents.map(\.statusLabel) == [
            L("status_degraded"),
            L("status_partial_outage"),
        ])
    }

    @Test
    func `display name prefers parenthetical english label`() {
        #expect(
            DeepSeekStatusFetcher.displayName("API 服务 (API Service)") == "API Service")
        #expect(
            DeepSeekStatusFetcher.displayName("网页对话服务 (Web Chat Service)") == "Web Chat Service")
        #expect(DeepSeekStatusFetcher.displayName("Plain Name") == "Plain Name")
    }
}
