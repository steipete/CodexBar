import CodexBarCore
import Foundation
import Testing

struct DeepSeekProviderTests {
    @Test
    func `descriptor wires DeepSeek as API provider`() {
        let descriptor = ProviderDescriptorRegistry.descriptor(for: .deepseek)

        #expect(descriptor.id == .deepseek)
        #expect(descriptor.metadata.displayName == "DeepSeek")
        #expect(descriptor.metadata.defaultEnabled == false)
        #expect(descriptor.fetchPlan.sourceModes == [.auto, .api])
        #expect(descriptor.branding.iconStyle == .deepseek)
        #expect(descriptor.branding.iconResourceName == "ProviderIcon-deepseek")
    }

    @Test
    func `settings reader trims quoted environment API key`() {
        let env = [
            DeepSeekSettingsReader.apiKeyEnvironmentKey: "  \"sk-deepseek\"  ",
        ]

        #expect(DeepSeekSettingsReader.apiKey(environment: env) == "sk-deepseek")
        #expect(ProviderTokenResolver.deepSeekToken(environment: env) == "sk-deepseek")
    }

    @Test
    func `balance response decodes API payload`() throws {
        let data = Data("""
        {
          "is_available": true,
          "balance_infos": [
            {
              "currency": "CNY",
              "total_balance": "12.34",
              "topped_up_balance": "10.00",
              "granted_balance": "2.34"
            }
          ]
        }
        """.utf8)

        let response = try JSONDecoder().decode(DeepSeekBalanceResponse.self, from: data)

        #expect(response.isAvailable == true)
        #expect(response.balanceInfos.count == 1)
        #expect(response.balanceInfos[0].currency == "CNY")
        #expect(response.balanceInfos[0].totalBalance == "12.34")
    }

    @Test
    func `usage snapshot maps balance into provider identity`() {
        let updatedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = DeepSeekUsageSnapshot(
            totalBalance: 12.345,
            toppedUpBalance: 10,
            grantedBalance: 2.345,
            currency: "CNY",
            isAvailable: true,
            updatedAt: updatedAt)

        let usage = snapshot.toUsageSnapshot()

        #expect(usage.identity?.providerID == .deepseek)
        #expect(usage.identity?.loginMethod == "Balance: 12.35 CNY")
        #expect(usage.primary == nil)
        #expect(usage.updatedAt == updatedAt)
    }
}
