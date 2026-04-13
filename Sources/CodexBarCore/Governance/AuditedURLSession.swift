import Foundation

public struct NetworkAuditOptions: Sendable {
    public let risk: AuditRisk?
    public let metadata: [String: String]
    public let context: GovernanceContext?

    public init(
        risk: AuditRisk? = nil,
        metadata: [String: String] = [:],
        context: GovernanceContext? = nil)
    {
        self.risk = risk
        self.metadata = metadata
        self.context = context
    }
}

public extension URLSession {
    func codexbarData(
        for request: URLRequest,
        audit options: NetworkAuditOptions = NetworkAuditOptions()) async throws -> (Data, URLResponse)
    {
        AuditLogger.recordNetwork(
            action: "request.started",
            request: request,
            risk: options.risk,
            metadata: options.metadata,
            context: options.context)
        do {
            let result = try await self.data(for: request)
            AuditLogger.recordNetwork(
                action: "request.completed",
                request: request,
                response: result.1,
                risk: options.risk,
                metadata: options.metadata,
                context: options.context)
            return result
        } catch {
            AuditLogger.recordNetwork(
                action: "request.failed",
                request: request,
                error: error,
                risk: options.risk,
                metadata: options.metadata,
                context: options.context)
            throw error
        }
    }

    func codexbarData(
        for request: URLRequest,
        delegate: (any URLSessionTaskDelegate)?,
        audit options: NetworkAuditOptions = NetworkAuditOptions()) async throws -> (Data, URLResponse)
    {
        AuditLogger.recordNetwork(
            action: "request.started",
            request: request,
            risk: options.risk,
            metadata: options.metadata,
            context: options.context)
        do {
            let result = try await self.data(for: request, delegate: delegate)
            AuditLogger.recordNetwork(
                action: "request.completed",
                request: request,
                response: result.1,
                risk: options.risk,
                metadata: options.metadata,
                context: options.context)
            return result
        } catch {
            AuditLogger.recordNetwork(
                action: "request.failed",
                request: request,
                error: error,
                risk: options.risk,
                metadata: options.metadata,
                context: options.context)
            throw error
        }
    }
}
