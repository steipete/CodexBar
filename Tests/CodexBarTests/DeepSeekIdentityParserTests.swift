import Foundation
import Testing
@testable import CodexBarCore

struct DeepSeekIdentityParserTests {
    private func data(_ json: String) -> Data {
        Data(json.utf8)
    }

    @Test
    func `parses masked email and mobile`() throws {
        let json = """
        {
          "code": 0,
          "data": { "biz_code": 0, "biz_data": {
            "email": "y.q*****ro@gmail.com",
            "mobile_number": "186******44",
            "area_code": "+86",
            "currency": "CNY",
            "balance_alert": { "CNY": { "enabled": false, "alert_bound": "1" } }
          }}
        }
        """
        let identity = try DeepSeekUsageFetcher._parseIdentityForTesting(self.data(json))
        #expect(identity.email == "y.q*****ro@gmail.com")
        #expect(identity.maskedMobile == "186******44")
        #expect(identity.currency == "CNY")
        #expect(identity.balanceAlertEnabled == false)
        #expect(identity.balanceAlertBound == 1)
    }

    @Test
    func `balance alert enabled parses bound for selected currency`() throws {
        let json = """
        {
          "code": 0,
          "data": { "biz_code": 0, "biz_data": {
            "email": "a@b.com",
            "currency": "CNY",
            "balance_alert": {
              "CNY": { "enabled": true, "alert_bound": "5" },
              "USD": { "enabled": false, "alert_bound": "1" }
            }
          }}
        }
        """
        let identity = try DeepSeekUsageFetcher._parseIdentityForTesting(self.data(json))
        #expect(identity.balanceAlertEnabled == true)
        #expect(identity.balanceAlertBound == 5)
    }

    @Test
    func `auth failure throws invalid credentials`() {
        let json = #"{ "code": 40002, "msg": "missing token" }"#
        #expect(throws: DeepSeekUsageError.self) {
            _ = try DeepSeekUsageFetcher._parseIdentityForTesting(data(json))
        }
    }
}
