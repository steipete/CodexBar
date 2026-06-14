import Foundation

public struct GrokUsageSnapshot: Sendable {
    public let billing: GrokBillingResponse?
    public let webBilling: GrokWebBillingSnapshot?
    public let credentials: GrokCredentials?
    public let localSummary: GrokLocalSessionSummary?
    public let cliVersion: String?
    public let updatedAt: Date

    public init(
        billing: GrokBillingResponse?,
        webBilling: GrokWebBillingSnapshot? = nil,
        credentials: GrokCredentials?,
        localSummary: GrokLocalSessionSummary?,
        cliVersion: String?,
        updatedAt: Date)
    {
        self.billing = billing
        self.webBilling = webBilling
        self.credentials = credentials
        self.localSummary = localSummary
        self.cliVersion = cliVersion
        self.updatedAt = updatedAt
    }

    public func toUsageSnapshot() -> UsageSnapshot {
        // Primary window: credit usage (against included limit) from the CLI RPC,
        // falling back to the web billing RPC used by grok.com when the agent surface lacks billing.
        var primary: RateWindow?
        if let billing,
           let percent = billing.monthlyUsedPercent
        {
            primary = RateWindow(
                usedPercent: percent,
                windowMinutes: billing.billingPeriodMinutes,
                resetsAt: billing.billingPeriodEndDate,
                resetDescription: nil)
        } else if let webBilling,
                  let percent = webBilling.usedPercent
        {
            primary = RateWindow(
                usedPercent: percent,
                windowMinutes: nil,
                resetsAt: webBilling.resetsAt,
                resetDescription: nil)
        }

        let identity = ProviderIdentitySnapshot(
            providerID: .grok,
            accountEmail: self.credentials?.email,
            accountOrganization: self.credentials?.teamId,
            loginMethod: self.credentials?.loginMethod)

        return UsageSnapshot(
            primary: primary,
            secondary: nil,
            tertiary: nil,
            updatedAt: self.updatedAt,
            identity: identity)
    }
}

public struct GrokStatusProbe: Sendable {
    public init() {}

    public static func detectVersion(env: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        guard let binary = BinaryLocator.resolveGrokBinary(env: env) else { return nil }
        guard let output = ProviderVersionDetector.run(
            path: binary,
            args: ["--version"],
            environment: env,
            mergeStandardError: true)
        else { return nil }
        // Output is like "grok 0.1.210 (8b63e9068c)" — strip the leading "grok " so
        // callers can prefix the CLI name themselves without duplicating it.
        let withoutPrefix = output.replacingOccurrences(
            of: #"^grok\s+"#,
            with: "",
            options: [.regularExpression])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return withoutPrefix.isEmpty ? nil : withoutPrefix
    }

    public func fetch(env: [String: String] = ProcessInfo.processInfo.environment) async throws -> GrokUsageSnapshot {
        // Credentials are optional: we still show identity-less state if the user
        // hasn't logged in, with a clear hint via the RPC error.
        let credentials = try? GrokCredentialsStore.load(env: env)

        var billing: GrokBillingResponse?
        var rpcError: Error?
        do {
            let client = try GrokRPCClient(environment: env)
            defer { client.shutdown() }
            try await client.initialize()
            billing = try await client.fetchBilling()
        } catch {
            rpcError = error
        }

        // Local fallback summary always succeeds (empty if no sessions yet).
        let localSummary = GrokLocalSessionScanner.summarize(env: env)
        let cliVersion = Self.detectVersion(env: env)

        // `localSummary` is *not* currently projected into a visible RateWindow or
        // identity field, so a stale `~/.grok/sessions/` directory must not
        // suppress the auth-required hint. CLI-only fetches need a billing
        // response; the provider pipeline owns the separate web fallback.
        if billing == nil {
            throw rpcError ?? GrokRPCError.notAuthenticated
        }

        return GrokUsageSnapshot(
            billing: billing,
            webBilling: nil,
            credentials: Self.credentialsForSnapshot(
                credentials: credentials,
                billing: billing,
                webBilling: nil),
            localSummary: localSummary,
            cliVersion: cliVersion,
            updatedAt: Date())
    }

    static func credentialsForSnapshot(
        credentials: GrokCredentials?,
        billing: GrokBillingResponse?,
        webBilling: GrokWebBillingSnapshot? = nil) -> GrokCredentials?
    {
        // If remote usage succeeded, xAI accepted auth and the local
        // identity is still useful even when the persisted expires_at is stale.
        if billing != nil || webBilling != nil { return credentials }
        return credentials.flatMap { $0.isExpired ? nil : $0 }
    }

    static func shouldSurfaceRemoteAuthError(_ error: Error?) -> Bool {
        guard let error = error as? GrokWebBillingError else { return false }
        switch error {
        case let .requestFailed(status, _):
            return status == 401 || status == 403
        case let .rpcFailed(status, _):
            return status == 16
        case .missingCredentials, .emptyResponse, .invalidResponse, .parseFailed:
            return false
        }
    }
}
