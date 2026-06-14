import CodexBarCore
import Foundation
import Testing

struct ZedStatusProbeTests {
    private struct StubCredentialsReader: ZedCredentialsReading {
        let credentials: ZedCredentials?

        func loadCredentials(serviceURL _: String) throws -> ZedCredentials? {
            self.credentials
        }
    }

    private static let subscriptionPeriod = """
    "subscription_period": {
      "started_at": "2026-05-13T00:00:00.000Z",
      "ended_at": "2026-06-13T00:00:00.000Z"
    }
    """

    private static func fixture(plan: String, used: Int, limit: String, overdue: Bool = false) -> Data {
        Data(
            """
            {
              "user": {
                "id": 4242,
                "github_login": "octocat",
                "name": "The Octocat"
              },
              "feature_flags": [],
              "plan": {
                "plan_v3": "\(plan)",
                \(self.subscriptionPeriod),
                "usage": {
                  "edit_predictions": {
                    "used": \(used),
                    "limit": \(limit)
                  }
                },
                "has_overdue_invoices": \(overdue)
              }
            }
            """.utf8)
    }

    private static func httpResponse(data: Data, statusCode: Int) -> (Data, URLResponse) {
        let response = HTTPURLResponse(
            url: URL(string: "https://cloud.zed.dev/client/users/me")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil)!
        return (data, response)
    }

    @Test
    func `decodes free plan with limited edit predictions`() throws {
        let response = try ZedStatusProbe.parseResponse(Self.fixture(plan: "zed_free", used: 12, limit: "50"))
        #expect(response.plan.planV3 == "zed_free")
        #expect(response.plan.usage.editPredictions.used == 12)
        #expect(response.plan.usage.editPredictions.limit == .limited(50))
        #expect(response.user.githubLogin == "octocat")
    }

    @Test
    func `decodes pro plan with unlimited edit predictions`() throws {
        let response = try ZedStatusProbe.parseResponse(Self.fixture(plan: "zed_pro", used: 0, limit: "\"unlimited\""))
        #expect(response.plan.planV3 == "zed_pro")
        #expect(response.plan.usage.editPredictions.limit == .unlimited)
    }

    @Test
    func `decodes pro trial student and business plans`() throws {
        let trial = try ZedStatusProbe.parseResponse(Self.fixture(
            plan: "zed_pro_trial",
            used: 3,
            limit: "\"unlimited\""))
        let student = try ZedStatusProbe.parseResponse(Self.fixture(plan: "zed_student", used: 1, limit: "25"))
        let business = try ZedStatusProbe.parseResponse(Self.fixture(
            plan: "zed_business",
            used: 0,
            limit: "\"unlimited\""))

        #expect(trial.plan.planV3 == "zed_pro_trial")
        #expect(student.plan.planV3 == "zed_student")
        #expect(business.plan.planV3 == "zed_business")
    }

    @Test
    func `maps free plan to usage snapshot`() throws {
        let response = try ZedStatusProbe.parseResponse(Self.fixture(plan: "zed_free", used: 10, limit: "20"))
        let snapshot = ZedUsageSnapshot(response: response).toUsageSnapshot()

        #expect(snapshot.identity?.loginMethod == "Zed Free")
        #expect(snapshot.identity?.accountEmail == "octocat")
        #expect(snapshot.primary?.resetDescription == "10 / 20 predictions")
        #expect(snapshot.primary?.usedPercent == 50)
        #expect(snapshot.secondary?.resetsAt != nil)
        #expect(snapshot.extraRateWindows?.contains(where: { $0.id == "zed.token-spend-note" }) == true)
        #expect(snapshot.extraRateWindows?.contains(where: { $0.id == "zed.token-credits" }) == false)
    }

    @Test
    func `maps pro plan with static token credit label`() throws {
        let response = try ZedStatusProbe.parseResponse(Self.fixture(plan: "zed_pro", used: 0, limit: "\"unlimited\""))
        let snapshot = ZedUsageSnapshot(response: response).toUsageSnapshot()

        #expect(snapshot.identity?.loginMethod == "Zed Pro")
        #expect(snapshot.primary?.resetDescription == "Unlimited")
        #expect(snapshot.extraRateWindows?.contains(where: { $0.id == "zed.token-credits" }) == true)
        #expect(snapshot.extraRateWindows?.first(where: { $0.id == "zed.token-credits" })?.window.resetDescription?
            .contains("$5 included") == true)
    }

    @Test
    func `maps student and trial included credit labels`() throws {
        let student = try ZedStatusProbe.parseResponse(Self.fixture(plan: "zed_student", used: 2, limit: "25"))
        let trial = try ZedStatusProbe.parseResponse(Self.fixture(
            plan: "zed_pro_trial",
            used: 0,
            limit: "\"unlimited\""))

        let studentCredits = ZedUsageSnapshot(response: student).toUsageSnapshot()
            .extraRateWindows?
            .first(where: { $0.id == "zed.token-credits" })?
            .window.resetDescription
        let trialCredits = ZedUsageSnapshot(response: trial).toUsageSnapshot()
            .extraRateWindows?
            .first(where: { $0.id == "zed.token-credits" })?
            .window.resetDescription

        #expect(studentCredits?.contains("$10 included") == true)
        #expect(trialCredits?.contains("$20 trial credits") == true)
    }

    @Test
    func `maps overdue invoices warning window`() throws {
        let response = try ZedStatusProbe.parseResponse(
            Self.fixture(plan: "zed_pro", used: 0, limit: "\"unlimited\"", overdue: true))
        let snapshot = ZedUsageSnapshot(response: response).toUsageSnapshot()

        #expect(snapshot.extraRateWindows?.contains(where: { $0.id == "zed.overdue-invoices" }) == true)
    }

    @Test
    func `reads credentials url from settings`() {
        let settings = ZedClientSettings(
            credentialsURL: "https://preview.zed.dev",
            serverURL: "https://zed.dev")
        #expect(settings.keychainServiceURL == "https://preview.zed.dev")

        let fallback = ZedClientSettings(credentialsURL: nil, serverURL: "https://custom.zed.dev")
        #expect(fallback.keychainServiceURL == "https://custom.zed.dev")

        let defaultSettings = ZedClientSettings(credentialsURL: nil, serverURL: nil)
        #expect(defaultSettings.keychainServiceURL == ZedStatusProbe.defaultKeychainServiceURL)
    }

    @Test
    func `display plan names normalize zed enums`() {
        #expect(ZedUsageSnapshot.displayPlanName("zed_pro") == "Zed Pro")
        #expect(ZedUsageSnapshot.displayPlanName("zed_pro_trial") == "Zed Pro Trial")
        #expect(ZedUsageSnapshot.displayPlanName("zed_student") == "Zed Student")
    }

    @Test
    func `fetch uses authorization header from keychain credentials`() async throws {
        let transport = ProviderHTTPTransportStub { request in
            #expect(request.url?.absoluteString == "https://cloud.zed.dev/client/users/me")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "4242 test-token")
            return Self.httpResponse(
                data: Self.fixture(plan: "zed_pro", used: 0, limit: "\"unlimited\""),
                statusCode: 200)
        }

        let probe = ZedStatusProbe(
            credentialsReader: StubCredentialsReader(
                credentials: ZedCredentials(userID: "4242", accessToken: "test-token")),
            transport: transport,
            settingsLoader: { ZedClientSettings(credentialsURL: nil, serverURL: nil) })

        let snapshot = try await probe.fetch()
        #expect(snapshot.response.plan.planV3 == "zed_pro")
    }

    @Test
    func `fetch surfaces not signed in when keychain is empty`() async {
        let probe = ZedStatusProbe(
            credentialsReader: StubCredentialsReader(credentials: nil),
            transport: ProviderHTTPTransportStub { _ in
                Issue.record("Should not call cloud API without credentials")
                return Self.httpResponse(data: Data(), statusCode: 500)
            },
            settingsLoader: { nil })

        await #expect(throws: ZedStatusProbeError.notSignedIn) {
            _ = try await probe.fetch()
        }
    }

    @Test
    func `fetch surfaces unauthorized responses`() async {
        let probe = ZedStatusProbe(
            credentialsReader: StubCredentialsReader(
                credentials: ZedCredentials(userID: "1", accessToken: "bad")),
            transport: ProviderHTTPTransportStub { _ in
                Self.httpResponse(data: Data("{}".utf8), statusCode: 401)
            },
            settingsLoader: { nil })

        await #expect(throws: ZedStatusProbeError.unauthorized) {
            _ = try await probe.fetch()
        }
    }
}
