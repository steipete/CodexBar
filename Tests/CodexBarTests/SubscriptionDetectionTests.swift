import Foundation
import Testing
@testable import CodexBar

@Suite
struct SubscriptionDetectionTests {
    // MARK: - Subscription plans should be detected

    @Test
    func detectsMaxPlan() {
        #expect(UsageStore.isSubscriptionPlan("Claude Max") == true)
        #expect(UsageStore.isSubscriptionPlan("Max") == true)
        #expect(UsageStore.isSubscriptionPlan("claude max") == true)
        #expect(UsageStore.isSubscriptionPlan("MAX") == true)
    }

    @Test
    func detectsProPlan() {
        #expect(UsageStore.isSubscriptionPlan("Claude Pro") == true)
        #expect(UsageStore.isSubscriptionPlan("Pro") == true)
        #expect(UsageStore.isSubscriptionPlan("pro") == true)
    }

    @Test
    func detectsUltraPlan() {
        #expect(UsageStore.isSubscriptionPlan("Claude Ultra") == true)
        #expect(UsageStore.isSubscriptionPlan("Ultra") == true)
        #expect(UsageStore.isSubscriptionPlan("ultra") == true)
    }

    @Test
    func detectsTeamPlan() {
        #expect(UsageStore.isSubscriptionPlan("Claude Team") == true)
        #expect(UsageStore.isSubscriptionPlan("Team") == true)
        #expect(UsageStore.isSubscriptionPlan("team") == true)
    }

    @Test
    func enterprisePlanDoesNotCountAsSubscription() {
        #expect(UsageStore.isSubscriptionPlan("Claude Enterprise") == false)
        #expect(UsageStore.isSubscriptionPlan("Enterprise") == false)
    }

    // MARK: - Non-subscription plans should return false

    @Test
    func nilLoginMethodReturnsFalse() {
        #expect(UsageStore.isSubscriptionPlan(nil) == false)
    }

    @Test
    func emptyLoginMethodReturnsFalse() {
        #expect(UsageStore.isSubscriptionPlan("") == false)
        #expect(UsageStore.isSubscriptionPlan("   ") == false)
    }

    @Test
    func unknownPlanReturnsFalse() {
        #expect(UsageStore.isSubscriptionPlan("API") == false)
        #expect(UsageStore.isSubscriptionPlan("Free") == false)
        #expect(UsageStore.isSubscriptionPlan("Unknown") == false)
        #expect(UsageStore.isSubscriptionPlan("Claude") == false)
    }

    @Test
    func apiKeyUsersReturnFalse() {
        // API users typically don't have a login method or have non-subscription identifiers
        #expect(UsageStore.isSubscriptionPlan("api_key") == false)
        #expect(UsageStore.isSubscriptionPlan("console") == false)
    }
}
