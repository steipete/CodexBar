import Foundation

public struct GrokUsageSnapshot: Sendable {
    public let billing: GrokBillingResponse?
    public let webBilling: GrokWebBillingSnapshot?
    public let credentials: GrokCredentials?
    public let localSummary: GrokLocalSessionSummary?
    public let cliVersion: String?
    public let diagnostic: String?
    public let updatedAt: Date
    public let subscriptionTier: String?

    public init(
        billing: GrokBillingResponse?,
        webBilling: GrokWebBillingSnapshot? = nil,
        credentials: GrokCredentials?,
        localSummary: GrokLocalSessionSummary?,
        cliVersion: String?,
        updatedAt: Date,
        diagnostic: String? = nil,
        subscriptionTier: String? = nil)
    {
        self.billing = billing
        self.webBilling = webBilling
        self.credentials = credentials
        self.localSummary = localSummary
        self.cliVersion = cliVersion
        self.diagnostic = diagnostic
        self.updatedAt = updatedAt
        self.subscriptionTier = subscriptionTier
    }

    public func toUsageSnapshot(
        calendar: Calendar = .current,
        historyDays: Int = GrokLocalSessionScanner.defaultLookbackDays) -> UsageSnapshot
    {
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
            // Do not infer the full quota cadence from the remaining time until reset; a
            // monthly window near its reset would otherwise be misclassified as weekly.
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
            loginMethod: GrokPlan.loginMethod(
                subscriptionTier: self.subscriptionTier ?? self.webBilling?.subscriptionTier,
                credentials: self.credentials))

        return UsageSnapshot(
            primary: primary,
            secondary: nil,
            tertiary: nil,
            costUsage: self.localSummary?.toCostUsageTokenSnapshot(
                historyDays: historyDays,
                calendar: calendar),
            updatedAt: self.updatedAt,
            identity: identity)
    }
}

public struct GrokStatusProbe: Sendable {
    public static let teamUsageUnavailableMessage =
        "Grok team usage is unavailable from the current billing surface; identity is still available."
    public static let usageUnavailableMessage =
        "Grok usage is unavailable because its billing sources did not report a usage percentage."

    public init() {}

    public static func detectVersion(env: [String: String] = ProcessInfo.processInfo.environment)
        -> String?
    {
        guard let binary = BinaryLocator.resolveGrokBinary(env: env) else { return nil }
        guard
            let output = ProviderVersionDetector.run(
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

    public func fetch(
        env: [String: String] = ProcessInfo.processInfo.environment,
        calendar: Calendar = .current,
        lookbackDays: Int = GrokLocalSessionScanner.defaultLookbackDays) async throws
        -> GrokUsageSnapshot
    {
        // Credentials are optional: we still show identity-less state if the user
        // hasn't logged in, with a clear hint via the RPC error.
        let credentials = try? GrokCredentialsStore.load(env: env)

        var billing: GrokBillingResponse?
        var rpcError: Error?
        var billingAttempted = false
        do {
            let client = try GrokRPCClient(environment: env)
            defer { client.shutdown() }
            try await client.initialize()
            billingAttempted = true
            billing = try await client.fetchBilling()
        } catch {
            rpcError = error
        }

        // Local fallback summary always succeeds (empty if no sessions yet).
        let localSummary = try await GrokLocalSessionScanner.summarizeOffMainThread(
            env: env,
            lookbackDays: lookbackDays,
            calendar: calendar)
        let cliVersion = Self.detectVersion(env: env)

        // `localSummary` is *not* currently projected into a visible RateWindow or
        // identity field, so a stale `~/.grok/sessions/` directory must not
        // suppress the auth-required hint. CLI-only fetches need a billing
        // response; the provider pipeline owns the separate web fallback.
        if billing == nil,
           let credentials,
           Self.shouldUseIdentityOnlyFallback(
               credentials: credentials,
               billingAttempted: billingAttempted,
               error: rpcError)
        {
            let subscriptionTier = try await Self.loadSettingsTier(credentials: credentials)
            return Self.identityOnlySnapshot(
                credentials: credentials,
                localSummary: localSummary,
                cliVersion: cliVersion,
                subscriptionTier: subscriptionTier)
        }

        if billing == nil {
            throw rpcError ?? GrokRPCError.notAuthenticated
        }

        let subscriptionTier = try await Self.loadSettingsTier(credentials: credentials)
        return GrokUsageSnapshot(
            billing: billing,
            webBilling: nil,
            credentials: Self.credentialsForSnapshot(
                credentials: credentials,
                billing: billing,
                webBilling: nil),
            localSummary: localSummary,
            cliVersion: cliVersion,
            updatedAt: Date(),
            subscriptionTier: subscriptionTier)
    }

    static func identityOnlySnapshot(
        credentials: GrokCredentials,
        localSummary: GrokLocalSessionSummary?,
        cliVersion: String?,
        updatedAt: Date = .init(),
        subscriptionTier: String? = nil) -> GrokUsageSnapshot
    {
        GrokUsageSnapshot(
            billing: nil,
            webBilling: nil,
            credentials: credentials,
            localSummary: localSummary,
            cliVersion: cliVersion,
            updatedAt: updatedAt,
            diagnostic: GrokStatusProbe.teamUsageUnavailableMessage,
            subscriptionTier: subscriptionTier)
    }

    static let settingsJoinGrace = Duration.seconds(2)

    static func loadSettingsTier(
        credentials: GrokCredentials?,
        session transport: any ProviderHTTPTransport = ProviderHTTPClient.shared) async throws -> String?
    {
        guard let credentials, !credentials.isExpired else { return nil }
        let sourceTask = Task<String?, Error> {
            try await GrokCLISettingsFetcher.subscriptionTierDisplay(
                credentials: credentials,
                session: transport)
        }
        let outcome = await BoundedTaskJoin(sourceTask: sourceTask).value(joinGrace: Self.settingsJoinGrace)
        try Task.checkCancellation()
        switch outcome {
        case let .value(tier):
            return tier
        case .timedOut:
            return nil
        case let .failure(error):
            if error is CancellationError {
                throw CancellationError()
            }
            if let urlError = error as? URLError, urlError.code == .cancelled {
                throw urlError
            }
            return nil
        }
    }

    static func isBillingMethodUnavailable(_ error: Error?) -> Bool {
        guard let error,
              case let GrokRPCError.requestFailed(message) = error
        else {
            return false
        }
        let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "method not found" || normalized.hasPrefix("method not found:")
    }

    static func shouldUseIdentityOnlyFallback(
        credentials: GrokCredentials?,
        billingAttempted: Bool,
        error: Error?) -> Bool
    {
        guard billingAttempted,
              let credentials,
              !credentials.isExpired,
              credentials.isTeamPrincipal
        else {
            return false
        }
        return Self.isBillingMethodUnavailable(error)
    }

    static func credentialsForSnapshot(
        credentials: GrokCredentials?,
        billing: GrokBillingResponse?,
        webBilling: GrokWebBillingSnapshot? = nil) -> GrokCredentials?
    {
        // If remote usage succeeded, xAI accepted auth and the local
        // identity is still useful even when the persisted expires_at is stale.
        if billing != nil || webBilling != nil {
            return credentials
        }
        return credentials.flatMap { $0.isExpired ? nil : $0 }
    }

    static func shouldSurfaceRemoteAuthError(_ error: Error?) -> Bool {
        guard let error = error as? GrokWebBillingError else { return false }
        switch error {
        case let .requestFailed(status, _):
            return status == 401 || status == 403
        case let .rpcFailed(status, _):
            return status == 16
        case .missingCredentials, .emptyResponse, .invalidResponse, .teamUsageUnsupported, .parseFailed:
            return false
        }
    }
}
