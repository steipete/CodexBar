import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct QuotaHTTP: Sendable {
    let transport: any ProviderHTTPTransport

    func get(_ url: String, token: String, headers: [String: String] = [:]) async throws -> Data {
        var request = URLRequest(url: URL(string: url)!)
        request.allHTTPHeaderFields = headers
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return try await self.send(request)
    }

    func send(_ request: URLRequest) async throws -> Data {
        var request = request
        request.timeoutInterval = 15
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let response = try await self.transport.response(for: request)
        switch response.statusCode {
        case 200: return response.data
        case 401: throw QuotaError.unauthorized
        default: throw QuotaError.http(response.statusCode)
        }
    }
}

package struct KimiGrant: Codable, Sendable {
    package let key: String
    let region: KimiRegion

    package init(key: String, region: KimiRegion) {
        self.key = key
        self.region = region
    }
}

package struct QuotaCredentials: Sendable {
    let codex: @Sendable () throws -> CodexGrant?
    let saveCodex: @Sendable (CodexGrant) throws -> Void
    let kimi: @Sendable () throws -> KimiGrant?
    let google: @Sendable () throws -> AntigravityOAuthCredentials?
    let saveGoogle: @Sendable (AntigravityOAuthCredentials) throws -> Void
}

/// All paths belong to CodexBar. Google uses the store written by CodexBar's interactive sign-in.
package struct QuotaCredentialFiles: Sendable {
    let directory: URL
    let googleStore: AntigravityOAuthCredentialsStore

    package init(directory: URL, googleStore: AntigravityOAuthCredentialsStore) {
        self.directory = directory
        self.googleStore = googleStore
    }

    package var credentials: QuotaCredentials {
        QuotaCredentials(
            codex: { try self.read(CodexGrant.self, provider: .codex) },
            saveCodex: { try self.save($0, provider: .codex) },
            kimi: { try self.read(KimiGrant.self, provider: .kimi) },
            google: { try self.googleStore.load() },
            saveGoogle: { try self.googleStore.save($0) })
    }

    private func read<T: Decodable>(_ type: T.Type, provider: Subscription) throws -> T? {
        do {
            let data = try Data(contentsOf: self.directory.appendingPathComponent(provider.rawValue))
            return try JSONDecoder().decode(type, from: data)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
    }

    private func save(_ value: some Encodable, provider: Subscription) throws {
        try CredentialFileWriter.writePrivate(
            JSONEncoder().encode(value), to: self.directory.appendingPathComponent(provider.rawValue))
    }

    package func saveKimi(_ grant: KimiGrant) throws {
        try self.save(grant, provider: .kimi)
    }

    package func disconnect(_ provider: Subscription) throws {
        if provider == .antigravity {
            try self.googleStore.deleteIfPresent()
            return
        }
        do {
            try FileManager.default.removeItem(at: self.directory.appendingPathComponent(provider.rawValue))
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return
        }
    }
}

package struct QuotaService: Sendable {
    let credentials: QuotaCredentials
    let http: QuotaHTTP

    package init(credentials: QuotaCredentials, transport: (any ProviderHTTPTransport)? = nil) {
        self.credentials = credentials
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.urlCache = nil
        self.http = QuotaHTTP(transport: transport ?? ProviderHTTPClient(
            session: ProviderHTTPClient.redirectGuardedSession(configuration: config)))
    }

    package func fetch(_ provider: Subscription) async throws -> [QuotaWindow] {
        let windows: [QuotaWindow]
        switch provider {
        case .antigravity:
            guard let grant = try self.credentials.google() else { throw QuotaError.missingCredential }
            windows = try await AntigravityQuota.fetch(grant, http: self.http, save: self.credentials.saveGoogle)
        case .codex:
            guard let grant = try self.credentials.codex() else { throw QuotaError.missingCredential }
            do {
                windows = try await CodexQuota.fetch(grant: grant, http: self.http)
            } catch QuotaError.unauthorized {
                let renewed = try await CodexDeviceLogin.refresh(grant, http: self.http)
                try self.credentials.saveCodex(renewed)
                windows = try await CodexQuota.fetch(grant: renewed, http: self.http)
            }
        case .kimi:
            guard let grant = try self.credentials.kimi() else { throw QuotaError.missingCredential }
            let url = grant.region.apiBaseURL.appendingPathComponent("coding/v1/usages")
            let data = try await self.http.get(url.absoluteString, token: grant.key)
            windows = try KimiQuota.windows(data)
        }
        guard !windows.isEmpty else { throw QuotaError.unavailable }
        return windows
    }
}
