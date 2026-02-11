import Foundation
import Testing
@testable import CodexBarCore

@Suite
struct TraeUsageParserTests {
    @Test
    func parsesActiveEntitlementWithProPlan() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let json = """
        {
            "user_entitlement_pack_list": [
                {
                    "entitlement_base_info": {
                        "quota": {
                            "premium_model_fast_request_limit": 600
                        },
                        "end_time": 1772277112,
                        "product_type": 1
                    },
                    "status": 1,
                    "usage": {
                        "premium_model_fast_amount": 91.26527
                    }
                }
            ]
        }
        """

        let snapshot = try TraeUsageParser.parse(json: json, now: now)

        #expect(snapshot.totalCredits == 600)
        #expect(snapshot.usedCredits == 91.26527)
        #expect(snapshot.planName == "Pro Plan")
        #expect(snapshot.expiresAt != nil)
    }

    @Test
    func parsesMultipleActiveEntitlements() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let json = """
        {
            "user_entitlement_pack_list": [
                {
                    "entitlement_base_info": {
                        "quota": {
                            "premium_model_fast_request_limit": 600
                        },
                        "end_time": 1772277112,
                        "product_type": 1
                    },
                    "status": 1,
                    "usage": {
                        "premium_model_fast_amount": 100
                    }
                },
                {
                    "entitlement_base_info": {
                        "quota": {
                            "premium_model_fast_request_limit": 300
                        },
                        "end_time": 1772277187,
                        "product_type": 2
                    },
                    "status": 1,
                    "usage": {
                        "premium_model_fast_amount": 50
                    }
                }
            ]
        }
        """

        let snapshot = try TraeUsageParser.parse(json: json, now: now)

        #expect(snapshot.totalCredits == 900)
        #expect(snapshot.usedCredits == 150)
        #expect(snapshot.planName.contains("Pro Plan"))
        #expect(snapshot.planName.contains("Package"))
    }

    @Test
    func includesInactiveEntitlementsWithQuota() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let json = """
        {
            "user_entitlement_pack_list": [
                {
                    "entitlement_base_info": {
                        "quota": {
                            "premium_model_fast_request_limit": 600
                        },
                        "end_time": 1772277112,
                        "product_type": 1
                    },
                    "status": 1,
                    "usage": {
                        "premium_model_fast_amount": 100
                    }
                },
                {
                    "entitlement_base_info": {
                        "quota": {
                            "premium_model_fast_request_limit": 300
                        },
                        "end_time": 1772277187,
                        "product_type": 2
                    },
                    "status": 0,
                    "usage": {
                        "premium_model_fast_amount": 50
                    }
                }
            ]
        }
        """

        let snapshot = try TraeUsageParser.parse(json: json, now: now)

        // Parser now includes all entitlements with valid quota (not just status=1)
        #expect(snapshot.totalCredits == 900)
        #expect(snapshot.usedCredits == 150)
        #expect(snapshot.activeEntitlements == 1)
        #expect(snapshot.totalEntitlements == 2)
    }

    @Test
    func calculatesUsagePercentCorrectly() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let json = """
        {
            "user_entitlement_pack_list": [
                {
                    "entitlement_base_info": {
                        "quota": {
                            "premium_model_fast_request_limit": 100
                        },
                        "end_time": 1772277112,
                        "product_type": 1
                    },
                    "status": 1,
                    "usage": {
                        "premium_model_fast_amount": 25
                    }
                }
            ]
        }
        """

        let snapshot = try TraeUsageParser.parse(json: json, now: now)
        let usage = snapshot.toUsageSnapshot(now: now)

        #expect(usage.primary?.usedPercent == 25)
    }

    @Test
    func handlesIntegerRequestLimits() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let json = """
        {
            "user_entitlement_pack_list": [
                {
                    "entitlement_base_info": {
                        "quota": {
                            "premium_model_fast_request_limit": 600
                        },
                        "end_time": 1772277112,
                        "product_type": 1
                    },
                    "status": 1,
                    "usage": {
                        "premium_model_fast_amount": 91
                    }
                }
            ]
        }
        """

        let snapshot = try TraeUsageParser.parse(json: json, now: now)

        #expect(snapshot.totalCredits == 600)
        #expect(snapshot.usedCredits == 91)
    }

    @Test
    func missingEntitlementListThrowsParseFailed() {
        let json = "{\"error\": \"not found\"}"

        #expect {
            try TraeUsageParser.parse(json: json)
        } throws: { error in
            guard case let TraeUsageError.parseFailed(message) = error else { return false }
            return message.contains("user_entitlement_pack_list")
        }
    }

    @Test
    func emptyEntitlementsWithQuotaThrowsParseFailed() {
        let json = """
        {
            "user_entitlement_pack_list": [
                {
                    "entitlement_base_info": {
                        "quota": {"premium_model_fast_request_limit": 0},
                        "end_time": 1772277112,
                        "product_type": 1
                    },
                    "status": 0,
                    "usage": {"premium_model_fast_amount": 0}
                }
            ]
        }
        """

        #expect {
            try TraeUsageParser.parse(json: json)
        } throws: { error in
            guard case let TraeUsageError.parseFailed(message) = error else { return false }
            return message.contains("No entitlements found with valid quotas")
        }
    }

    @Test
    func unauthorizedResponseThrowsNotLoggedIn() {
        let json = """
        {
            "error": "unauthorized"
        }
        """

        #expect {
            try TraeUsageParser.parse(json: json)
        } throws: { error in
            guard case TraeUsageError.notLoggedIn = error else { return false }
            return true
        }
    }

    @Test
    func invalidJsonThrowsParseFailed() {
        let json = "not valid json"

        #expect {
            try TraeUsageParser.parse(json: json)
        } throws: { error in
            guard case let TraeUsageError.parseFailed(message) = error else { return false }
            return message.contains("Invalid JSON")
        }
    }

    @Test
    func calculatesEarliestExpiry() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let json = """
        {
            "user_entitlement_pack_list": [
                {
                    "entitlement_base_info": {
                        "quota": {"premium_model_fast_request_limit": 600},
                        "end_time": 1772277112,
                        "product_type": 1
                    },
                    "status": 1,
                    "usage": {"premium_model_fast_amount": 100}
                },
                {
                    "entitlement_base_info": {
                        "quota": {"premium_model_fast_request_limit": 300},
                        "end_time": 1700000100,
                        "product_type": 2
                    },
                    "status": 1,
                    "usage": {"premium_model_fast_amount": 50}
                }
            ]
        }
        """

        let snapshot = try TraeUsageParser.parse(json: json, now: now)

        // Should use the earlier expiry (1700000100)
        #expect(snapshot.expiresAt == Date(timeIntervalSince1970: 1700000100))
    }
}
