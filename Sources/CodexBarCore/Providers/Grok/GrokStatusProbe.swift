import Foundation

public struct GrokUsageSnapshot: Sendable {
    public let billing: GrokBillingResponse?
    public let credentials: GrokCredentials?
    public let localSummary: GrokLocalSessionSummary?
    public let cliVersion: String?
    public let updatedAt: Date

    public init(
        billing: GrokBillingResponse?,
        credentials: GrokCredentials?,
        localSummary: GrokLocalSessionSummary?,
        cliVersion: String?,
        updatedAt: Date)
    {
        self.billing = billing
        self.credentials = credentials
        self.localSummary = localSummary
        self.cliVersion = cliVersion
        self.updatedAt = updatedAt
    }

    public func toUsageSnapshot() -> UsageSnapshot {
        // Primary window: monthly credit usage from billing config (preferred), otherwise nil.
        var primary: RateWindow?
        if let billing,
           let percent = billing.monthlyUsedPercent
        {
            primary = RateWindow(
                usedPercent: percent,
                windowMinutes: nil,
                resetsAt: billing.billingPeriodEndDate,
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
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [binary, "--version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else { return nil }
            // Output is like "grok 0.1.210 (8b63e9068c)" — strip the leading "grok " so
            // callers can prefix the CLI name themselves without duplicating it.
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            let firstLine = trimmed.split(separator: "\n").first.map(String.init) ?? trimmed
            let withoutPrefix = firstLine.replacingOccurrences(
                of: #"^grok\s+"#,
                with: "",
                options: [.regularExpression])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return withoutPrefix.isEmpty ? nil : withoutPrefix
        } catch {
            return nil
        }
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
        // suppress the auth-required hint. Only swallow the RPC error when we
        // actually have something rendrable for the user — credentials or a
        // billing response.
        if billing == nil, credentials == nil {
            throw rpcError ?? GrokRPCError.notAuthenticated
        }

        return GrokUsageSnapshot(
            billing: billing,
            credentials: credentials,
            localSummary: localSummary,
            cliVersion: cliVersion,
            updatedAt: Date())
    }
}
