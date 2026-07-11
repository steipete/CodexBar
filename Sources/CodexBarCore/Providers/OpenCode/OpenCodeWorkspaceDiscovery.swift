import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct OpenCodeDiscoveredWorkspace: Codable, Identifiable, Sendable, Equatable {
    public let workspaceID: String
    public let label: String
    public let ownerLabel: String?

    public var id: String {
        self.workspaceID
    }

    public init(workspaceID: String, label: String, ownerLabel: String? = nil) {
        self.workspaceID = workspaceID
        self.label = label
        self.ownerLabel = ownerLabel
    }
}

public enum OpenCodeWorkspaceDiscoveryResult: Equatable, Sendable {
    case discovered([OpenCodeDiscoveredWorkspace])
    case missingReusableCredential
    case invalidWorkspaceID
    case discoveryFailed(String)
}

public enum OpenCodeWorkspaceDiscovery {
    public static func discover(
        cookieHeader: String,
        timeout: TimeInterval,
        session: URLSession = .shared) async throws -> [OpenCodeDiscoveredWorkspace]
    {
        try await OpenCodeUsageFetcher.discoverWorkspaces(
            cookieHeader: cookieHeader,
            timeout: timeout,
            session: session)
    }

    public static func resolve(
        cookieHeader: String?,
        workspaceID: String? = nil,
        timeout: TimeInterval,
        session: URLSession = .shared) async -> OpenCodeWorkspaceDiscoveryResult
    {
        guard let cookieHeader,
              OpenCodeWebCookieSupport.requestCookieHeader(from: cookieHeader) != nil
        else {
            return .missingReusableCredential
        }
        if let workspaceID,
           OpenCodeWorkspaceAccount.normalizeWorkspaceID(workspaceID) == nil
        {
            return .invalidWorkspaceID
        }
        do {
            return try await .discovered(self.discover(
                cookieHeader: cookieHeader,
                timeout: timeout,
                session: session))
        } catch {
            return .discoveryFailed(error.localizedDescription)
        }
    }
}
