import Foundation
import Testing
@testable import CodexBarCore

struct ClaudePlanResolverTests {
    @Test
    func `oauth rate limit tier maps to branded plan`() {
        #expect(ClaudePlan.oauthLoginMethod(rateLimitTier: "claude_pro") == "Claude Pro")
        #expect(ClaudePlan.oauthLoginMethod(rateLimitTier: "claude_team") == "Claude Team")
        #expect(ClaudePlan.oauthLoginMethod(rateLimitTier: "claude_enterprise") == "Claude Enterprise")
    }

    @Test
    func `oauth rate limit tier preserves the Max usage multiplier`() {
        #expect(ClaudePlan.oauthLoginMethod(rateLimitTier: "default_claude_max_5x") == "Claude Max 5x")
        #expect(ClaudePlan.oauthLoginMethod(rateLimitTier: "default_claude_max_20x") == "Claude Max 20x")
        #expect(ClaudePlan.oauthLoginMethod(rateLimitTier: "v2_default_claude_max_20x") == "Claude Max 20x")
        // A bare Max tier without a multiplier keeps the plain label.
        #expect(ClaudePlan.oauthLoginMethod(rateLimitTier: "claude_max") == "Claude Max")
        #expect(ClaudePlan.oauthLoginMethod(rateLimitTier: "default_claude_team_5x") == "Claude Team")
        // A resolved non-Max plan never inherits a Max multiplier from a disagreeing tier.
        #expect(
            ClaudePlan.oauthLoginMethod(subscriptionType: "team", rateLimitTier: "default_claude_max_5x")
                == "Claude Team")
        #expect(
            ClaudePlan.webLoginMethod(rateLimitTier: "default_claude_max_20x", billingType: nil)
                == "Claude Max 20x")
    }

    @Test
    func `oauth subscription type overrides generic rate limit tier`() {
        #expect(
            ClaudePlan.oauthLoginMethod(subscriptionType: "pro", rateLimitTier: "default_claude_ai")
                == "Claude Pro")
        #expect(
            ClaudePlan.oauthLoginMethod(subscriptionType: "team", rateLimitTier: "default_claude_max_5x")
                == "Claude Team")
        #expect(ClaudePlan.oauthLoginMethod(subscriptionType: nil, rateLimitTier: "default_claude_ai") == nil)
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
    func `web team seat tiers map to specific labels`() {
        #expect(
            ClaudePlan.webLoginMethod(
                rateLimitTier: "claude_team",
                billingType: "stripe_subscription",
                seatTier: "team_standard")
                == "Claude Team Standard")
        #expect(
            ClaudePlan.webLoginMethod(
                rateLimitTier: "claude_team",
                billingType: "stripe_subscription",
                seatTier: "team_tier_1")
                == "Claude Team Premium")
        #expect(
            ClaudePlan.webLoginMethod(
                rateLimitTier: nil,
                billingType: nil,
                seatTier: "team_standard")
                == "Claude Team Standard")
    }

    @Test
    func `web team seat tier near misses use existing plan inference`() {
        #expect(
            ClaudePlan.webLoginMethod(
                rateLimitTier: "claude_team",
                billingType: "stripe_subscription",
                seatTier: "team_premium")
                == "Claude Team")
        #expect(
            ClaudePlan.webLoginMethod(
                rateLimitTier: "claude_team",
                billingType: "stripe_subscription",
                seatTier: "team_standard_plus")
                == "Claude Team")
    }

    @Test
    func `web enterprise seat tiers preserve the enterprise label`() {
        #expect(
            ClaudePlan.webLoginMethod(
                rateLimitTier: "claude_enterprise",
                billingType: "stripe_subscription",
                seatTier: "team_standard")
                == "Claude Enterprise")
        #expect(
            ClaudePlan.webLoginMethod(
                rateLimitTier: "claude_enterprise",
                billingType: "stripe_subscription",
                seatTier: "team_tier_1")
                == "Claude Enterprise")
    }

    @Test
    func `missing web seat tier preserves existing plan labels`() {
        #expect(
            ClaudePlan.webLoginMethod(
                rateLimitTier: "default_claude_max_20x",
                billingType: nil,
                seatTier: nil)
                == "Claude Max 20x")
        #expect(
            ClaudePlan.webLoginMethod(
                rateLimitTier: "claude_pro",
                billingType: "stripe_subscription",
                seatTier: nil)
                == "Claude Pro")
        #expect(
            ClaudePlan.webLoginMethod(
                rateLimitTier: "claude_team",
                billingType: "stripe_subscription",
                seatTier: nil)
                == "Claude Team")
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
