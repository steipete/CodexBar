import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

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
        #expect(components.last?.status == "degraded_performance")
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
    func `parse statuspage components drops blank names`() throws {
        let data = Data(#"""
        {
          "components": [
            {"id": "blank", "name": "   ", "status": "operational", "position": 1},
            {"id": "api", "name": " API ", "status": "operational", "position": 2}
          ]
        }
        """#.utf8)

        let components = try UsageStore.parseStatuspageComponents(data: data)

        #expect(components.map(\.name) == ["API"])
    }

    @Test
    func `fetchStatusSummary returns status with empty components when component feed fails`() async throws {
        let summaryJSON = Data(#"""
        {
          "page": {"updated_at": "2026-06-18T19:41:22Z"},
          "status": {"indicator": "minor", "description": "Partial Outage"}
        }
        """#.utf8)

        let stub = ProviderHTTPTransportStub { request in
            guard let path = request.url?.path else { throw URLError(.badURL) }
            if path.hasSuffix("summary.json") {
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (summaryJSON, response)
            }
            throw URLError(.notConnectedToInternet)
        }

        let baseURL = try #require(URL(string: "https://status.example.test"))
        let result = try await UsageStore.fetchStatusSummary(from: baseURL, transport: stub)

        #expect(result.status.indicator == .minor)
        #expect(result.status.description == "Partial Outage")
        #expect(result.components == nil)
    }

    @Test
    func `fetchStatusSummary overlays description and updatedAt when incident io succeeds`() async throws {
        let proxyJSON = Data(#"""
        {
          "summary": {
            "affected_components": [{"component_id": "c-api", "status": "degraded_performance"}],
            "structure": {"items": [
              {"component": {"component_id": "c-api", "name": "API", "hidden": false}}
            ]}
          }
        }
        """#.utf8)

        let statusJSON = Data(#"""
        {
          "page": {"updated_at": "2026-06-20T10:00:00Z"},
          "status": {"indicator": "minor", "description": "Elevated error rates"}
        }
        """#.utf8)

        let stub = ProviderHTTPTransportStub { request in
            guard let url = request.url else { throw URLError(.badURL) }
            let ok = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            if url.path.contains("/proxy/") { return (proxyJSON, ok) }
            if url.path.hasSuffix("status.json") { return (statusJSON, ok) }
            throw URLError(.notConnectedToInternet)
        }

        let baseURL = try #require(URL(string: "https://status.example.test"))
        let result = try await UsageStore.fetchStatusSummary(from: baseURL, transport: stub)

        #expect(result.status.indicator == .minor)
        #expect(result.status.description == "Elevated error rates")
        #expect(result.status.updatedAt != nil)
        #expect(result.components?.map(\.name) == ["API"])
    }

    @Test
    func `parse incident io summary builds groups with aggregated status`() throws {
        // Shaped like status.openai.com/proxy/status.openai.com.
        let data = Data(#"""
        {
          "summary": {
            "affected_components": [
              {"component_id": "c-fed", "status": "degraded_performance"},
              {"component_id": "c-top", "status": "full_outage"}
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
                {"component": {"component_id": "c-top", "name": "Standalone", "hidden": false}}
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
        #expect(fedramp.status == "degraded_performance")
        #expect(fedramp.statusLabel == L("status_degraded"))

        #expect(result.components[2].isGroup == false) // standalone component
        #expect(result.components[2].indicator == .critical)
        #expect(result.components[2].status == "full_outage")
        #expect(result.components[2].statusLabel == L("status_major_outage"))

        // Overall page status reflects the worst leaf (standalone full outage).
        #expect(result.status.indicator == .critical)
    }
}
