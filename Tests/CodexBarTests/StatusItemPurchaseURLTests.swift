import Foundation
import Testing
@testable import CodexBar

struct StatusItemPurchaseURLTests {
    @Test
    @MainActor
    func `purchase URL accepts ChatGPT hosts`() {
        #expect(
            StatusItemController.sanitizedCreditsPurchaseURL("https://chatgpt.com/settings/billing")
                == "https://chatgpt.com/settings/billing")
        #expect(
            StatusItemController
                .sanitizedCreditsPurchaseURL("https://chatgpt.com/usage/credits?token=secret#fragment")
                == "https://chatgpt.com/usage/credits")
        #expect(
            StatusItemController.sanitizedCreditsPurchaseURL("https://team.chatgpt.com/settings/billing")
                == "https://team.chatgpt.com/settings/billing")
    }

    @Test
    @MainActor
    func `purchase URL rejects lookalike hosts`() {
        #expect(
            StatusItemController
                .sanitizedCreditsPurchaseURL("https://chatgpt.com.evil.example/settings/billing") == nil)
        #expect(
            StatusItemController.sanitizedCreditsPurchaseURL("https://evil-chatgpt.com/settings/billing")
                == nil)
        #expect(
            StatusItemController.sanitizedCreditsPurchaseURL("https://notchatgpt.com/settings/billing")
                == nil)
    }

    @Test
    @MainActor
    func `purchase URL rejects non HTTPS and unrelated paths`() {
        #expect(
            StatusItemController.sanitizedCreditsPurchaseURL("http://chatgpt.com/settings/billing")
                == nil)
        #expect(
            StatusItemController.sanitizedCreditsPurchaseURL("https://chatgpt.com/backend-api/accounts")
                == nil)
        #expect(
            StatusItemController.sanitizedCreditsPurchaseURL("https://chatgpt.com/backend-api/settings-token")
                == nil)
        #expect(StatusItemController.sanitizedCreditsPurchaseURL("not a url") == nil)
    }
}
