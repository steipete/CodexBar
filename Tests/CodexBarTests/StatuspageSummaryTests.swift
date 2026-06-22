import Foundation
import Testing
@testable import CodexBar

@MainActor
struct StatuspageSummaryTests {
    @Test
    func `parse statuspage status decodes overall indicator`() throws {
        let data = Data(#"""
        {
          "page": {"updated_at": "2026-06-18T19:41:22Z"},
          "status": {"indicator": "minor", "description": "Partial System Degradation"}
        }
        """#.utf8)

        let status = try UsageStore.parseStatuspageStatus(data: data)
        #expect(status.indicator == .minor)
        #expect(status.description == "Partial System Degradation")
        #expect(status.updatedAt != nil)
    }

    @Test
    func `parse statuspage components maps and sorts leaf rows`() throws {
        // Mirrors components.json, which includes unlisted rows such as FedRAMP.
        let data = Data(#"""
        {
          "components": [
            {"id": "c-cli", "name": "CLI", "status": "operational", "position": 2},
            {"id": "c-api", "name": "Codex API", "status": "major_outage", "position": 1},
            {"id": "c-fed", "name": "FedRAMP", "status": "degraded_performance", "position": 25}
          ]
        }
        """#.utf8)

        let components = try UsageStore.parseStatuspageComponents(data: data)

        #expect(components.map(\.name) == ["Codex API", "CLI", "FedRAMP"])
        #expect(components.map(\.indicator) == [.critical, .none, .minor])
        #expect(components.allSatisfy { !$0.isGroup })
        #expect(components.last?.statusLabel == L("status_degraded"))
    }

    @Test
    func `parse statuspage components nests children under their group`() throws {
        let data = Data(#"""
        {
          "components": [
            {"id": "g1", "name": "API", "status": "degraded_performance", "group": true, "position": 0},
            {"id": "c-resp", "name": "Responses", "status": "operational", "group_id": "g1", "position": 2},
            {"id": "c-chat", "name": "Chat Completions", "status": "major_outage", "group_id": "g1", "position": 1},
            {"id": "c-cli", "name": "CLI", "status": "operational", "position": 3}
          ]
        }
        """#.utf8)

        let components = try UsageStore.parseStatuspageComponents(data: data)

        // Top level: the group followed by the ungrouped leaf. Children are not promoted.
        #expect(components.map(\.name) == ["API", "CLI"])

        let group = try #require(components.first)
        #expect(group.isGroup)
        #expect(group.indicator == .minor) // group's own status (degraded)
        // Children appear inside the group, sorted by position.
        #expect(group.children.map(\.name) == ["Chat Completions", "Responses"])
        #expect(group.children.map(\.indicator) == [.critical, .none])

        #expect(components[1].isGroup == false)
    }

    @Test
    func `parse statuspage components tolerates missing components`() throws {
        let components = try UsageStore.parseStatuspageComponents(data: Data("{}".utf8))
        #expect(components.isEmpty)
    }

    @Test
    func `parse incident io summary builds groups with aggregated status`() throws {
        // Shaped like status.openai.com/proxy/status.openai.com.
        let data = Data(#"""
        {
          "summary": {
            "affected_components": [
              {"component_id": "c-fed", "status": "degraded_performance"}
            ],
            "structure": {
              "items": [
                {"group": {"id": "g-codex", "name": "Codex", "hidden": false, "components": [
                  {"component_id": "c-cli", "name": "CLI", "hidden": false},
                  {"component_id": "c-web", "name": "Codex Web", "hidden": false},
                  {"component_id": "c-secret", "name": "Hidden", "hidden": true}
                ]}},
                {"group": {"id": "g-fed", "name": "FedRAMP", "hidden": false, "components": [
                  {"component_id": "c-fed", "name": "FedRAMP", "hidden": false}
                ]}},
                {"component": {"id": "c-top", "name": "Standalone", "hidden": false}}
              ]
            }
          }
        }
        """#.utf8)

        let result = try UsageStore.parseIncidentIOSummary(data: data)

        #expect(result.components.map(\.name) == ["Codex", "FedRAMP", "Standalone"])

        let codex = result.components[0]
        #expect(codex.isGroup)
        #expect(codex.indicator == .none) // all children operational
        #expect(codex.children.map(\.name) == ["CLI", "Codex Web"]) // hidden child dropped

        let fedramp = result.components[1]
        #expect(fedramp.isGroup)
        #expect(fedramp.indicator == .minor) // aggregates the degraded child
        #expect(fedramp.statusLabel == L("status_degraded"))

        #expect(result.components[2].isGroup == false) // standalone component

        // Overall page status reflects the worst leaf (FedRAMP degraded).
        #expect(result.status.indicator == .minor)
    }
}
