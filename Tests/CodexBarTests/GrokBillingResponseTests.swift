import Foundation
import Testing
@testable import CodexBarCore

struct GrokBillingResponseTests {
    @Test
    func `decodes full BillingConfigResponse and computes percent`() throws {
        let json = #"""
        {
          "billingCycle": {
            "billingPeriodStart": "2026-05-01T00:00:00Z",
            "billingPeriodEnd": "2026-06-01T00:00:00Z"
          },
          "monthlyLimit": { "val": 99900 },
          "onDemandCap": { "val": 0 },
          "on_demand_enabled": false,
          "disabledByConfig": false,
          "usage": {
            "includedUsed": { "val": 49950 },
            "onDemandUsed": { "val": 0 },
            "totalUsed": { "val": 49950 }
          }
        }
        """#
        let data = Data(json.utf8)
        let response = try JSONDecoder().decode(GrokBillingResponse.self, from: data)

        #expect(response.monthlyLimit?.val == 99900)
        #expect(response.usage?.totalUsed?.val == 49950)
        #expect(response.monthlyUsedPercent == 50.0)
        #expect(response.billingPeriodEndDate != nil)
        #expect(response.billingPeriodMinutes == 31 * 24 * 60)
    }

    @Test
    func `monthlyUsedPercent returns nil when limit missing`() throws {
        let json = #"""
        {
          "usage": { "totalUsed": { "val": 100 } }
        }
        """#
        let data = Data(json.utf8)
        let response = try JSONDecoder().decode(GrokBillingResponse.self, from: data)
        #expect(response.monthlyUsedPercent == nil)
    }

    @Test
    func `monthlyUsedPercent clamps over-100 usage`() throws {
        let json = #"""
        {
          "monthlyLimit": { "val": 1000 },
          "usage": { "totalUsed": { "val": 5000 } }
        }
        """#
        let data = Data(json.utf8)
        let response = try JSONDecoder().decode(GrokBillingResponse.self, from: data)
        #expect(response.monthlyUsedPercent == 100.0)
    }

    @Test
    func `handles missing optional fields gracefully`() throws {
        let json = #"{}"#
        let data = Data(json.utf8)
        let response = try JSONDecoder().decode(GrokBillingResponse.self, from: data)
        #expect(response.billingCycle == nil)
        #expect(response.monthlyLimit == nil)
        #expect(response.monthlyUsedPercent == nil)
    }
}
