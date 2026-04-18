import Foundation
import Testing
@testable import CodexBarCore

struct ClaudePlanResolverTests {
    @Test
    func `oauth rate limit tier maps to branded plan`() {
        #expect(ClaudePlan.oauthLoginMethod(rateLimitTier: "default_claude_max_20x") == "Claude Max")
        #expect(ClaudePlan.oauthLoginMethod(rateLimitTier: "claude_pro") == "Claude Pro")
        #expect(ClaudePlan.oauthLoginMethod(rateLimitTier: "claude_team") == "Claude Team")
        #expect(ClaudePlan.oauthLoginMethod(rateLimitTier: "claude_enterprise") == "Claude Enterprise")
    }

    @Test
    func `web fallback preserves stripe Claude compatibility`() {
        #expect(
            ClaudePlan.webLoginMethod(
                rateLimitTier: "default_claude",
                billingType: "stripe_subscription")
                == "Claude Pro")
    }

    @Test
    func `compatibility parser understands current labels`() {
        #expect(ClaudePlan.fromCompatibilityLoginMethod("Claude Max") == .max)
        #expect(ClaudePlan.fromCompatibilityLoginMethod("Max") == .max)
        #expect(ClaudePlan.fromCompatibilityLoginMethod("Claude Pro") == .pro)
        #expect(ClaudePlan.fromCompatibilityLoginMethod("Ultra") == .ultra)
        #expect(ClaudePlan.fromCompatibilityLoginMethod("Claude Team") == .team)
        #expect(ClaudePlan.fromCompatibilityLoginMethod("Claude Enterprise") == .enterprise)
    }

    @Test
    func `CLI projection keeps compact compatibility and unknown fallback`() {
        #expect(ClaudePlan.cliCompatibilityLoginMethod("Claude Max Account") == "Max")
        #expect(ClaudePlan.cliCompatibilityLoginMethod("Team") == "Team")
        #expect(ClaudePlan.cliCompatibilityLoginMethod("Claude Enterprise Account") == "Enterprise")
        #expect(ClaudePlan.cliCompatibilityLoginMethod("Claude Ultra Account") == "Ultra")
        #expect(ClaudePlan.cliCompatibilityLoginMethod("Experimental") == "Experimental")
        #expect(ClaudePlan.cliCompatibilityLoginMethod("Profile") == "Profile")
        #expect(ClaudePlan.cliCompatibilityLoginMethod("Browser profile") == "Browser profile")
    }

    @Test
    func `subscription compatibility preserves ultra and excludes enterprise`() {
        #expect(ClaudePlan.isSubscriptionLoginMethod("Claude Max"))
        #expect(ClaudePlan.isSubscriptionLoginMethod("Pro"))
        #expect(ClaudePlan.isSubscriptionLoginMethod("Ultra"))
        #expect(ClaudePlan.isSubscriptionLoginMethod("Team"))
        #expect(!ClaudePlan.isSubscriptionLoginMethod("Claude Enterprise"))
        #expect(!ClaudePlan.isSubscriptionLoginMethod("Profile"))
        #expect(!ClaudePlan.isSubscriptionLoginMethod("Browser profile"))
        #expect(!ClaudePlan.isSubscriptionLoginMethod("API"))
    }
}
