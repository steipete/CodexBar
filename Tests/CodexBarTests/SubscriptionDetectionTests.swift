import Foundation
import Testing
@testable import CodexBar

struct SubscriptionDetectionTests {
    // MARK: - Subscription plans should be detected

    @Test
    func `detects max plan`() {
        #expect(UsageStore.isSubscriptionPlan("Claude Max") == true)
        #expect(UsageStore.isSubscriptionPlan("Max") == true)
        #expect(UsageStore.isSubscriptionPlan("claude max") == true)
        #expect(UsageStore.isSubscriptionPlan("MAX") == true)
    }

    @Test
    func `detects pro plan`() {
        #expect(UsageStore.isSubscriptionPlan("Claude Pro") == true)
        #expect(UsageStore.isSubscriptionPlan("Pro") == true)
        #expect(UsageStore.isSubscriptionPlan("pro") == true)
    }

    @Test
    func `detects ultra plan`() {
        #expect(UsageStore.isSubscriptionPlan("Claude Ultra") == true)
        #expect(UsageStore.isSubscriptionPlan("Ultra") == true)
        #expect(UsageStore.isSubscriptionPlan("ultra") == true)
    }

    @Test
    func `detects team plan`() {
        #expect(UsageStore.isSubscriptionPlan("Claude Team") == true)
        #expect(UsageStore.isSubscriptionPlan("Team") == true)
        #expect(UsageStore.isSubscriptionPlan("team") == true)
    }

    @Test
    func `enterprise plan does not count as subscription`() {
        #expect(UsageStore.isSubscriptionPlan("Claude Enterprise") == false)
        #expect(UsageStore.isSubscriptionPlan("Enterprise") == false)
    }

    // MARK: - Non-subscription plans should return false

    @Test
    func `nil login method returns false`() {
        #expect(UsageStore.isSubscriptionPlan(nil) == false)
    }

    @Test
    func `empty login method returns false`() {
        #expect(UsageStore.isSubscriptionPlan("") == false)
        #expect(UsageStore.isSubscriptionPlan("   ") == false)
    }

    @Test
    func `unknown plan returns false`() {
        #expect(UsageStore.isSubscriptionPlan("API") == false)
        #expect(UsageStore.isSubscriptionPlan("Free") == false)
        #expect(UsageStore.isSubscriptionPlan("Unknown") == false)
        #expect(UsageStore.isSubscriptionPlan("Claude") == false)
    }

    @Test
    func `api key users return false`() {
        // API users typically don't have a login method or have non-subscription identifiers
        #expect(UsageStore.isSubscriptionPlan("api_key") == false)
        #expect(UsageStore.isSubscriptionPlan("console") == false)
    }
}
