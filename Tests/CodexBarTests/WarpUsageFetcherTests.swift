import Foundation
import Testing
@testable import CodexBarCore

@Suite
struct WarpUsageFetcherTests {
    // MARK: - Helper to build a valid GraphQL response JSON

    private static func makeResponseJSON(
        typename: String = "UserOutput",
        isUnlimited: Any? = false,
        requestLimit: Any? = 100,
        requestsUsed: Any? = 42,
        nextRefreshTime: String? = "2025-02-01T00:00:00Z",
        bonusGrants: [[String: Any]] = [],
        workspaces: [[String: Any]] = [],
        errors: [[String: Any]]? = nil
    ) -> Data {
        var userObj: [String: Any] = [
            "__typename": typename,
        ]

        var innerUser: [String: Any] = [:]
        var limitInfo: [String: Any] = [:]
        if let isUnlimited { limitInfo["isUnlimited"] = isUnlimited }
        if let requestLimit { limitInfo["requestLimit"] = requestLimit }
        if let requestsUsed { limitInfo["requestsUsedSinceLastRefresh"] = requestsUsed }
        if let nextRefreshTime { limitInfo["nextRefreshTime"] = nextRefreshTime }
        innerUser["requestLimitInfo"] = limitInfo
        innerUser["bonusGrants"] = bonusGrants
        innerUser["workspaces"] = workspaces
        userObj["user"] = innerUser

        var root: [String: Any] = [
            "data": ["user": userObj],
        ]
        if let errors {
            root["errors"] = errors
        }
        return try! JSONSerialization.data(withJSONObject: root)
    }

    // MARK: - Tests

    @Test
    func parsesNormalResponse() throws {
        let data = Self.makeResponseJSON(
            isUnlimited: false,
            requestLimit: 200,
            requestsUsed: 75,
            nextRefreshTime: "2025-02-01T00:00:00Z")

        let snapshot = try WarpUsageFetcher._parseResponseForTesting(data)

        #expect(snapshot.requestLimit == 200)
        #expect(snapshot.requestsUsed == 75)
        #expect(snapshot.isUnlimited == false)
        #expect(snapshot.nextRefreshTime != nil)
    }

    @Test
    func handlesGraphQLErrors() throws {
        let json: [String: Any] = [
            "errors": [
                ["message": "Not authenticated"],
            ],
            "data": NSNull(),
        ]
        let data = try JSONSerialization.data(withJSONObject: json)

        #expect(throws: WarpUsageError.self) {
            try WarpUsageFetcher._parseResponseForTesting(data)
        }
    }

    @Test
    func handlesMissingUserField() throws {
        let json: [String: Any] = [
            "data": [
                "user": [
                    "__typename": "UserOutput",
                    // Missing "user" inner object
                ] as [String: Any],
            ] as [String: Any],
        ]
        let data = try JSONSerialization.data(withJSONObject: json)

        #expect(throws: WarpUsageError.self) {
            try WarpUsageFetcher._parseResponseForTesting(data)
        }
    }

    @Test
    func handlesNullIsUnlimited() throws {
        let data = Self.makeResponseJSON(isUnlimited: NSNull())

        let snapshot = try WarpUsageFetcher._parseResponseForTesting(data)
        #expect(snapshot.isUnlimited == false)
    }

    @Test
    func handlesNumericFieldsAsStrings() throws {
        let data = Self.makeResponseJSON(
            requestLimit: "500",
            requestsUsed: "123")

        let snapshot = try WarpUsageFetcher._parseResponseForTesting(data)
        #expect(snapshot.requestLimit == 500)
        #expect(snapshot.requestsUsed == 123)
    }

    @Test
    func parsesBonusCredits() throws {
        let userBonus: [String: Any] = [
            "requestCreditsGranted": 100,
            "requestCreditsRemaining": 50,
            "expiration": "2025-03-01T00:00:00Z",
        ]
        let workspaceBonus: [String: Any] = [
            "requestCreditsGranted": 200,
            "requestCreditsRemaining": 80,
            "expiration": "2025-04-01T00:00:00Z",
        ]
        let workspaces: [[String: Any]] = [
            [
                "bonusGrantsInfo": [
                    "grants": [workspaceBonus],
                ] as [String: Any],
            ],
        ]

        let data = Self.makeResponseJSON(
            bonusGrants: [userBonus],
            workspaces: workspaces)

        let snapshot = try WarpUsageFetcher._parseResponseForTesting(data)
        #expect(snapshot.bonusCreditsRemaining == 130) // 50 + 80
        #expect(snapshot.bonusCreditsTotal == 300) // 100 + 200
        #expect(snapshot.bonusNextExpiration != nil)
        #expect(snapshot.bonusNextExpirationRemaining == 50) // earliest expiry batch
    }

    @Test
    func handlesUnexpectedTypename() throws {
        let data = Self.makeResponseJSON(typename: "ErrorOutput")

        #expect(throws: WarpUsageError.self) {
            try WarpUsageFetcher._parseResponseForTesting(data)
        }
    }

    @Test
    func handlesMissingTypename() throws {
        // Build JSON without __typename
        let json: [String: Any] = [
            "data": [
                "user": [
                    "user": [
                        "requestLimitInfo": [
                            "isUnlimited": false,
                            "requestLimit": 100,
                            "requestsUsedSinceLastRefresh": 10,
                        ] as [String: Any],
                    ] as [String: Any],
                ] as [String: Any],
            ] as [String: Any],
        ]
        let data = try JSONSerialization.data(withJSONObject: json)

        #expect(throws: WarpUsageError.self) {
            try WarpUsageFetcher._parseResponseForTesting(data)
        }
    }
}
