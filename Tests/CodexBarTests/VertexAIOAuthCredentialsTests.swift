import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct VertexAIOAuthCredentialsTests {
    @Test
    func `service account credentials from GOOGLE_APPLICATION_CREDENTIALS use gcloud token`() async throws {
        let fileURL = try Self.writeServiceAccountCredentials()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let env = ["GOOGLE_APPLICATION_CREDENTIALS": fileURL.path]

        #expect(VertexAIOAuthCredentialsStore.hasCredentials(environment: env))

        let override: @Sendable ([String: String]) async throws -> String = { environment in
            #expect(environment["GOOGLE_APPLICATION_CREDENTIALS"] == fileURL.path)
            return "ya29.service-account\n"
        }
        let credentials = try await VertexAIOAuthCredentialsStore.$gcloudAccessTokenOverrideForTesting.withValue(
            override)
        {
            try await VertexAIOAuthCredentialsStore.loadForFetch(environment: env)
        }

        #expect(credentials.accessToken == "ya29.service-account")
        #expect(credentials.projectId == "service-project")
        #expect(credentials.email == "codexbar@test.iam.gserviceaccount.com")
        #expect(!credentials.needsRefresh)
    }

    @Test
    func `user ADC credentials still parse from CLOUDSDK_CONFIG`() throws {
        let configDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-vertex-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: configDir) }

        let credentialsURL = configDir.appendingPathComponent("application_default_credentials.json")
        let credentialsJSON = """
        {
          "client_id": "client-id",
          "client_secret": "client-secret",
          "refresh_token": "refresh-token"
        }
        """
        try credentialsJSON.write(to: credentialsURL, atomically: true, encoding: .utf8)

        let configurationsDir = configDir
            .appendingPathComponent("configurations", isDirectory: true)
        try FileManager.default.createDirectory(at: configurationsDir, withIntermediateDirectories: true)
        try "project = configured-project\n".write(
            to: configurationsDir.appendingPathComponent("config_default"),
            atomically: true,
            encoding: .utf8)

        let env = ["CLOUDSDK_CONFIG": configDir.path]
        let credentials = try VertexAIOAuthCredentialsStore.load(environment: env)

        #expect(credentials.refreshToken == "refresh-token")
        #expect(credentials.projectId == "configured-project")
    }

    private static func writeServiceAccountCredentials() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-vertex-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("service-account.json")
        let json = """
        {
          "type": "service_account",
          "project_id": "service-project",
          "private_key_id": "key-id",
          "private_key": "-----BEGIN PRIVATE KEY-----\\nabc\\n-----END PRIVATE KEY-----\\n",
          "client_email": "codexbar@test.iam.gserviceaccount.com",
          "client_id": "1234567890",
          "token_uri": "https://oauth2.googleapis.com/token"
        }
        """
        try json.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }
}
