import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCore

struct IBMBobUsageFetcherTests {
    @Test
    func `reads and cleans BOBSHELL API key`() {
        #expect(IBMBobSettingsReader.apiKey(environment: ["BOBSHELL_API_KEY": "  \"bob-key\"  "]) == "bob-key")
        #expect(IBMBobSettingsReader.apiKey(environment: ["BOBSHELL_API_KEY": "   "]) == nil)
    }

    @Test
    func `fetches profile and regional team budgets`() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let recorder = IBMBobRequestRecorder()
        let transport = ProviderHTTPTransportHandler { request in
            await recorder.append(request)
            let data: Data
            if request.url?.path == "/admin/v1/profile" {
                data = Self.profileData
            } else if request.url?.path == "/admin/v1/teams/team-one/users/user-one" {
                data = Data(#"{"usage":10}"#.utf8)
            } else if request.url?.path == "/admin/v1/teams/team-two/users/user-two" {
                data = Data(#"{"usage":25}"#.utf8)
            } else {
                Issue.record("Unexpected URL: \(request.url?.absoluteString ?? "nil")")
                data = Data()
            }
            let response = try HTTPURLResponse(
                url: #require(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil)!
            return (data, response)
        }

        let snapshot = try await IBMBobUsageFetcher._fetchUsageForTesting(
            apiKey: "fixture-key",
            transport: transport,
            now: now)
        let requests = await recorder.values

        #expect(snapshot.usedBobcoins == 35)
        #expect(snapshot.limitBobcoins == 200)
        #expect(snapshot.updatedAt == now)
        #expect(snapshot.teams.count == 2)
        #expect(snapshot.toUsageSnapshot().primary?.usedPercent == 17.5)
        #expect(snapshot.toUsageSnapshot().identity?.providerID == .ibmbob)
        #expect(requests.count == 3)
        #expect(requests[0].url?.host == "api.us-east.bob.ibm.com")
        #expect(requests[1].url?.host == "api.us-east.bob.ibm.com")
        #expect(requests[2].url?.host == "api.eu-de.bob.ibm.com")
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Apikey fixture-key" })
        #expect(requests[1].value(forHTTPHeaderField: "x-instance-id") == "instance-one")
        #expect(requests[1].value(forHTTPHeaderField: "x-team-id") == "team-one")
    }

    @Test
    func `decodes live profile names unix resets and team budget`() async throws {
        let transport = ProviderHTTPTransportHandler { request in
            let data = request.url?.path == "/admin/v1/profile"
                ? Self.liveProfileData
                : Data(#"{"usage":12.5,"budget_limit":80}"#.utf8)
            let response = try HTTPURLResponse(
                url: #require(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil)!
            return (data, response)
        }

        let snapshot = try await IBMBobUsageFetcher._fetchUsageForTesting(
            apiKey: "fixture-key",
            transport: transport)

        #expect(snapshot.teams.count == 1)
        #expect(snapshot.teams[0].instanceName == "Personal")
        #expect(snapshot.teams[0].usedBobcoins == 12.5)
        #expect(snapshot.teams[0].limitBobcoins == 80)
        #expect(snapshot.teams[0].resetsAt == Date(timeIntervalSince1970: 1_788_220_800))
    }

    @Test
    func `uses bearer authorization for JWT credentials`() async throws {
        let token = "header.eyJzdWIiOiJ1c2VyIn0.signature"
        let recorder = IBMBobRequestRecorder()
        let transport = ProviderHTTPTransportHandler { request in
            await recorder.append(request)
            let data = request.url?.path == "/admin/v1/profile"
                ? Self.singleTeamProfileData
                : Data(#"{"usage":4}"#.utf8)
            let response = try HTTPURLResponse(
                url: #require(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil)!
            return (data, response)
        }

        _ = try await IBMBobUsageFetcher._fetchUsageForTesting(apiKey: token, transport: transport)
        let requests = await recorder.values
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer \(token)" })
    }

    @Test
    func `rejects regional hosts outside bob domain before sending credentials`() async {
        let recorder = IBMBobRequestRecorder()
        let transport = ProviderHTTPTransportHandler { request in
            await recorder.append(request)
            let response = try HTTPURLResponse(
                url: #require(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil)!
            return (Self.regionalProfileData(regionDomain: "evil.example"), response)
        }

        await #expect {
            _ = try await IBMBobUsageFetcher._fetchUsageForTesting(
                apiKey: "fixture-key",
                transport: transport)
        } throws: { error in
            guard case IBMBobUsageError.untrustedRegion("api.evil.example") = error else { return false }
            return true
        }
        #expect(await recorder.values.count == 1)
    }

    @Test(arguments: [
        "evil.example/x.bob.ibm.com",
        "bob.ibm.com.evil.example",
        "x@evil.example",
        "evil.example/path/.bob.ibm.com",
        "evil.example?next=.bob.ibm.com",
        "evil.example#.bob.ibm.com",
        "evil.example@us-east.bob.ibm.com",
        "us-east.bob.ibm.com:443",
    ])
    func `rejects regional URL component bypasses before sending credentials`(regionDomain: String) async {
        let recorder = IBMBobRequestRecorder()
        let transport = ProviderHTTPTransportHandler { request in
            await recorder.append(request)
            let response = try HTTPURLResponse(
                url: #require(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil)!
            return (Self.regionalProfileData(regionDomain: regionDomain), response)
        }

        await #expect {
            _ = try await IBMBobUsageFetcher._fetchUsageForTesting(
                apiKey: "fixture-key",
                transport: transport)
        } throws: { error in
            guard case IBMBobUsageError.untrustedRegion = error else { return false }
            return true
        }
        #expect(await recorder.values.count == 1)
    }

    @Test
    func `descriptor registers API strategy token accounts and branding`() {
        let descriptor = ProviderDescriptorRegistry.descriptor(for: .ibmbob)
        #expect(descriptor.metadata.displayName == "IBM Bob")
        #expect(descriptor.metadata.shortDisplayName == "IBM Bob")
        #expect(descriptor.metadata.dashboardURL == "https://bob.ibm.com")
        #expect(descriptor.metadata.statusLinkURL == "https://status.bob.ibm.com")
        #expect(descriptor.branding.iconResourceName == "ProviderIcon-ibmbob")
        #expect(descriptor.fetchPlan.sourceModes == Set([.auto, .api]))
        #expect(descriptor.credentials?.tokenAccountSupport != nil)
    }

    private static let profileData = Data(
        """
        {
          "instances": [
            {
              "instance_id": "instance-one",
              "name": "Personal",
              "user_id": "user-one",
              "plan_name": "Pro+",
              "refresh_at": "2026-09-01T00:00:00Z",
              "region_domain": "us-east.bob.ibm.com",
              "teams": [{"id": "team-one", "name": "Solo", "budget_limit": 40}]
            },
            {
              "instance_id": "instance-two",
              "name": "Work",
              "user_id": "user-two",
              "plan_name": "Enterprise",
              "refresh_at": "2026-09-05T00:00:00.000Z",
              "region_domain": "api.eu-de.bob.ibm.com",
              "teams": [{"id": "team-two", "name": "Platform", "budget_limit": 160}]
            }
          ]
        }
        """.utf8)

    private static let singleTeamProfileData = Data(
        """
        {
          "instances": [{
            "instance_id": "instance-one",
            "user_id": "user-one",
            "teams": [{"id": "team-one", "budget_limit": 40}]
          }]
        }
        """.utf8)

    private static let liveProfileData = Data(
        """
        {
          "instances": [{
            "instance_id": "instance-one",
            "instance_name": "Personal",
            "user_id": "user-one",
            "plan_name": "Pro+",
            "refresh_at": 1788220800,
            "region_domain": "us-east.bob.ibm.com",
            "teams": [{"id": "team-one", "name": "Solo", "budget_limit": 40, "usage": 10}]
          }]
        }
        """.utf8)

    private static func regionalProfileData(regionDomain: String) -> Data {
        Data(
            """
            {
              "instances": [{
                "instance_id": "instance-one",
                "user_id": "user-one",
                "region_domain": "\(regionDomain)",
                "teams": [{"id": "team-one", "budget_limit": 40}]
              }]
            }
            """.utf8)
    }
}

private actor IBMBobRequestRecorder {
    private(set) var values: [URLRequest] = []

    func append(_ request: URLRequest) {
        self.values.append(request)
    }
}
